<#
.SYNOPSIS
  Fully automated installer: Waydroid (Android) running under WSL2 Ubuntu,
  launchable from Windows desktop shortcuts.

.DESCRIPTION
  Builds a custom WSL2 kernel with Android binder/binderfs support (required
  -- stock WSL2 kernels don't have it), installs Waydroid, and applies every
  fix needed for headless/scripted launch to work reliably:
    - modprobe called per-module (multi-arg form silently breaks networking)
    - /mnt/shared_memory pre-mounted at boot (fixes WSLg "[WARN:COPY MODE]"
      black-window bug)
    - vmIdleTimeout=-1 (WSL tears down the whole VM ~60s after the last
      wsl.exe connection closes otherwise, killing the session mid-boot)
    - Waydroid's auto-suspend-on-blur patched off (it freezes the container
      the instant its window loses focus, including mid-boot)
    - per-app Waydroid .desktop shortcuts moved aside (Windows Start Menu
      icon indexing races WSLg startup against the shared_memory fix)
    - launcher scripts wait for Android's actual "ready" signal before
      showing the UI, instead of a fixed guess

  NOTE ON REDEPLOYABILITY: the kernel is NOT a portable binary. It must be
  built against the exact WSL2 kernel version running on THIS machine, so
  this script rebuilds it fresh each time (dominates install time: ~10-20
  min). There is no way around this short of Microsoft shipping binder
  support upstream.

.PARAMETER DistroName
  WSL distro to target. Must already be installed and be Ubuntu or Debian-
  based (apt). Default: Ubuntu.

.PARAMETER InstallRoot
  Windows-side folder for the built kernel and launcher .bat files.
  Default: C:\Waydroid

.PARAMETER SkipKernelBuild
  Skip the kernel build/config/.wslconfig steps. Use on a re-run where the
  kernel was already built and the WSL kernel version hasn't changed.

.PARAMETER SkipSmokeTest
  Skip the final start/verify/stop smoke test.

.EXAMPLE
  .\Install-Waydroid.ps1
  .\Install-Waydroid.ps1 -DistroName Ubuntu-22.04 -InstallRoot D:\Apps\Waydroid
#>
[CmdletBinding()]
param(
    [string]$DistroName = "Ubuntu",
    [string]$InstallRoot = "C:\Waydroid",
    [switch]$SkipKernelBuild,
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatesDir = Join-Path $ScriptDir "templates"

# wsl.exe emits UTF-16; without this some PowerShell console configs render
# it mangled (space-separated characters), which breaks string matching
# against its output below.
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

function Invoke-Wsl {
    param([string[]]$WslArgs, [switch]$AllowFail)
    Write-Info "wsl $($WslArgs -join ' ')"
    $out = & wsl @WslArgs 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "    $_" }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "Command failed (exit $code): wsl $($WslArgs -join ' ')"
    }
    return $out
}

function ConvertTo-WslPath([string]$WinPath) {
    $full = [System.IO.Path]::GetFullPath($WinPath)
    $drive = $full.Substring(0,1).ToLower()
    $rest = $full.Substring(2) -replace '\\','/'
    return "/mnt/$drive$rest"
}

# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

$wslVersionOutput = & wsl --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "WSL does not appear to be installed. Install it first: wsl --install (requires a reboot), then re-run this script."
}
Write-Info "WSL present."

$distros = (& wsl -l -q) -replace "`0",""
if ($distros -notcontains $DistroName) {
    Write-Warn2 "Distro '$DistroName' not found. Installed distros: $($distros -join ', ')"
    Write-Host "Install it with:  wsl --install -d $DistroName"
    Write-Host "Complete the first-run username/password setup, then re-run this installer."
    exit 1
}
Write-Info "Distro '$DistroName' found."

# Wake it and confirm it's Debian/Ubuntu-based (needs apt)
Invoke-Wsl @("-d", $DistroName, "-e", "true")
$aptCheck = & wsl -d $DistroName -e bash -c "command -v apt-get >/dev/null && echo OK"
if ($aptCheck -notmatch "OK") {
    throw "Distro '$DistroName' does not have apt-get. This installer only supports Debian/Ubuntu-based distros."
}

$WslUser = (& wsl -d $DistroName -e whoami).Trim()
Write-Info "WSL user: $WslUser"

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallRoot\kernel" | Out-Null

# ---------------------------------------------------------------------------
if (-not $SkipKernelBuild) {
    Write-Step "Detecting WSL2 kernel version"
    $kernelRelease = (& wsl -d $DistroName -e uname -r).Trim()
    $kernelVer = $kernelRelease -replace '-microsoft-standard-WSL2\+?$', ''
    Write-Info "Running kernel: $kernelRelease  (version: $kernelVer)"

    if ($kernelRelease -match '\+$') {
        Write-Warn2 "Kernel already has a '+' suffix -- looks like a custom kernel is already active."
        Write-Warn2 "If this is a leftover from a previous install attempt, that's fine; we'll rebuild against the same tag."
    }

    Write-Step "Finding matching microsoft/WSL2-Linux-Kernel tag"
    $tagList = & wsl -d $DistroName -e bash -c "git ls-remote --tags https://github.com/microsoft/WSL2-Linux-Kernel.git 2>/dev/null | grep 'linux-msft-wsl-' | sed -E 's#.*refs/tags/##; s/\^\{\}$//' | sort -u"
    $tags = $tagList -split "`n" | Where-Object { $_ -match '^linux-msft-wsl-' }

    $exactTag = $tags | Where-Object { $_ -eq "linux-msft-wsl-$kernelVer" } | Select-Object -First 1
    if (-not $exactTag) {
        $prefix = ($kernelVer -split '\.')[0..1] -join '.'
        $exactTag = $tags | Where-Object { $_ -match "^linux-msft-wsl-$([regex]::Escape($prefix))\." } | Sort-Object | Select-Object -Last 1
        if ($exactTag) {
            Write-Warn2 "No exact tag for $kernelVer. Using closest same-minor-version tag: $exactTag"
            Write-Warn2 "This should still work (WSL patch-level bumps rarely touch driver config), but verify binder after install."
        }
    }
    if (-not $exactTag) {
        throw "Could not find any microsoft/WSL2-Linux-Kernel tag matching kernel $kernelVer. Cannot build a compatible kernel. Check https://github.com/microsoft/WSL2-Linux-Kernel/tags manually."
    }
    Write-Info "Using tag: $exactTag"

    Write-Step "Installing kernel build dependencies (as root)"
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
        "apt-get update -y && apt-get install -y --no-install-recommends build-essential flex bison libssl-dev libelf-dev bc git kmod cpio dwarves rsync python3")

    Write-Step "Cloning kernel source ($exactTag) -- this may take a minute"
    Invoke-Wsl @("-d", $DistroName, "-e", "bash", "-c",
        "mkdir -p ~/src && cd ~/src && rm -rf wsl-kernel && git clone --depth 1 --branch $exactTag https://github.com/microsoft/WSL2-Linux-Kernel.git wsl-kernel")

    Write-Step "Configuring kernel (enabling CONFIG_ANDROID_BINDER_IPC / CONFIG_ANDROID_BINDERFS)"
    # NOTE: build the command string in a variable first. Inside an @(...)
    # array literal a newline separates elements, so a trailing "+" does NOT
    # continue the expression -- each fragment becomes its own argv entry and
    # bash -c only receives the first one.
    $configCmd = "cd ~/src/wsl-kernel && zcat /proc/config.gz > .config && " `
        + "./scripts/config --set-val CONFIG_ANDROID_BINDER_IPC y " `
        + "--set-val CONFIG_ANDROID_BINDERFS y " `
        + "--set-str CONFIG_ANDROID_BINDER_DEVICES 'binder,hwbinder,vndbinder' " `
        + "--set-val CONFIG_ANDROID_BINDER_IPC_RUST n " `
        + "--set-val CONFIG_ANDROID_BINDER_ALLOC_KUNIT_TEST n && " `
        + "yes '' | make olddefconfig"
    Invoke-Wsl @("-d", $DistroName, "-e", "bash", "-c", $configCmd)

    Write-Step "Building kernel + modules (10-20 min depending on CPU)"
    Invoke-Wsl @("-d", $DistroName, "-e", "bash", "-c",
        'cd ~/src/wsl-kernel && make -j$(nproc) bzImage modules')

    Write-Step "Installing kernel modules (as root)"
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
        'cd ~/src/wsl-kernel && make -j$(nproc) modules_install')

    Write-Step "Copying kernel image to Windows"
    $winKernelPath = Join-Path $InstallRoot "kernel\bzImage"
    $wslKernelPath = ConvertTo-WslPath $winKernelPath
    Invoke-Wsl @("-d", $DistroName, "-e", "bash", "-c",
        "cp ~/src/wsl-kernel/arch/x86/boot/bzImage '$wslKernelPath'")
    if (-not (Test-Path $winKernelPath)) { throw "Kernel copy failed -- $winKernelPath not found." }
    Write-Info "Kernel image: $winKernelPath"

    # ------------------------------------------------------------------
    Write-Step "Configuring .wslconfig (global kernel + disabling VM idle shutdown)"
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $wslConfigForwardSlash = $winKernelPath -replace '\\','/'

    $existingLines = @()
    if (Test-Path $wslConfigPath) {
        Copy-Item $wslConfigPath "$wslConfigPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
        $existingLines = Get-Content $wslConfigPath
        Write-Info "Backed up existing .wslconfig"
    }

    # Preserve any [wsl2] keys we don't manage; drop old kernel=/vmIdleTimeout= lines we own.
    $inWsl2 = $false
    $kept = New-Object System.Collections.Generic.List[string]
    $sawWsl2 = $false
    foreach ($line in $existingLines) {
        if ($line -match '^\s*\[wsl2\]\s*$') { $inWsl2 = $true; $sawWsl2 = $true; $kept.Add($line); continue }
        if ($line -match '^\s*\[.*\]\s*$') { $inWsl2 = $false; $kept.Add($line); continue }
        if ($inWsl2 -and ($line -match '^\s*kernel\s*=' -or $line -match '^\s*vmIdleTimeout\s*=')) { continue }
        $kept.Add($line)
    }
    if (-not $sawWsl2) { $kept.Add("[wsl2]") }

    $final = New-Object System.Collections.Generic.List[string]
    $inWsl2 = $false
    foreach ($line in $kept) {
        $final.Add($line)
        if ($line -match '^\s*\[wsl2\]\s*$') {
            $final.Add("kernel=$wslConfigForwardSlash")
            $final.Add("vmIdleTimeout=-1")
        }
    }
    Set-Content -Path $wslConfigPath -Value $final -Encoding ascii
    Write-Info "Wrote $wslConfigPath"

    # ------------------------------------------------------------------
    Write-Step "Configuring /etc/wsl.conf (systemd + shared_memory boot fix)"
    $wslConfBackupCmd = "test -f /etc/wsl.conf && cp /etc/wsl.conf /etc/wsl.conf.bak-`$(date +%Y%m%d-%H%M%S) || true"
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c", $wslConfBackupCmd)

    $wslConfScript = @'
python3 - << "PYEOF"
import configparser, os
path = "/etc/wsl.conf"
cp = configparser.ConfigParser()
if os.path.exists(path):
    cp.read(path)
if not cp.has_section("boot"):
    cp.add_section("boot")
cp.set("boot", "systemd", "true")
cp.set("boot", "command", "mkdir -p /mnt/shared_memory && mount -t tmpfs tmpfs /mnt/shared_memory")
with open(path, "w") as f:
    cp.write(f)
print("wrote /etc/wsl.conf")
PYEOF
'@
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c", $wslConfScript)

    Write-Step "Restarting WSL to load the new kernel"
    & wsl --shutdown
    Start-Sleep -Seconds 3
    Invoke-Wsl @("-d", $DistroName, "-e", "uname", "-r")
    $newRelease = (& wsl -d $DistroName -e uname -r).Trim()
    if ($newRelease -notmatch '\+$') {
        Write-Warn2 "Kernel release '$newRelease' doesn't have the expected '+' suffix -- .wslconfig kernel= may not have taken effect. Continuing anyway; verify manually if Waydroid fails to start."
    } else {
        Write-Info "Custom kernel active: $newRelease"
    }

    Write-Step "Verifying binder + binderfs"
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
        "mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs && ls /dev/binderfs && umount /dev/binderfs && rmdir /dev/binderfs && echo BINDER_OK")
} else {
    Write-Step "Skipping kernel build (-SkipKernelBuild)"
}

# ---------------------------------------------------------------------------
Write-Step "Installing Waydroid"
$waydroidInstalled = & wsl -d $DistroName -e bash -c "command -v waydroid >/dev/null && echo OK"
if ($waydroidInstalled -match "OK") {
    Write-Info "Waydroid already installed."
} else {
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
        "curl -s https://repo.waydro.id | bash")
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
        "apt-get update -y && apt-get install -y waydroid")
}

$waydroidInited = & wsl -d $DistroName -e bash -c "test -f /var/lib/waydroid/waydroid.cfg && echo OK"
if ($waydroidInited -match "OK") {
    Write-Info "Waydroid already initialized (/var/lib/waydroid/waydroid.cfg exists)."
} else {
    Write-Step "Running waydroid init (downloads Android system+vendor images, several hundred MB)"
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
        "waydroid --details-to-stdout init")
}

# ---------------------------------------------------------------------------
Write-Step "Patching Waydroid auto-suspend-on-blur behavior"
$wslPatchPath = ConvertTo-WslPath (Join-Path $TemplatesDir "patch_hardware_manager.py")
Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
    "python3 '$wslPatchPath'; rm -rf /usr/lib/waydroid/tools/__pycache__ /usr/lib/waydroid/tools/services/__pycache__") -AllowFail

Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
    "test -f /var/lib/waydroid/waydroid.cfg && sed -i 's/^suspend_action = .*/suspend_action = none/' /var/lib/waydroid/waydroid.cfg || true")

Write-Step "Moving per-app Waydroid .desktop shortcuts aside (avoids a Windows Start Menu icon-indexing race)"
Invoke-Wsl @("-d", $DistroName, "-e", "bash", "-c",
    "mkdir -p ~/.local/share/applications-disabled && mv ~/.local/share/applications/waydroid.*.desktop ~/.local/share/applications-disabled/ 2>/dev/null; true")

# ---------------------------------------------------------------------------
Write-Step "Installing launcher scripts into WSL (/opt/waydroid-launcher)"
# Fixed, user-independent path: Start-Waydroid.bat invokes the root scripts
# via '-u root' (where ~ resolves to /root) and the user scripts via the
# normal user (where ~ resolves to /home/<user>) -- a single ~/-relative
# install location can't be found by both. /opt is readable+executable by
# everyone regardless of which user invokes it.
Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c", "mkdir -p /opt/waydroid-launcher && chmod 755 /opt/waydroid-launcher")
foreach ($f in @("waydroid-start-root.sh","waydroid-start-user.sh","waydroid-stop-root.sh","waydroid-stop-user.sh")) {
    $srcWin = Join-Path $TemplatesDir $f
    $srcWsl = ConvertTo-WslPath $srcWin
    Invoke-Wsl @("-d", $DistroName, "-u", "root", "-e", "bash", "-c",
        "cp '$srcWsl' /opt/waydroid-launcher/$f && chmod 755 /opt/waydroid-launcher/$f")
}
Write-Info "Launcher scripts installed."

# ---------------------------------------------------------------------------
Write-Step "Writing Start-Waydroid.bat / Stop-Waydroid.bat"
foreach ($pair in @(
    @{ Tmpl = "Start-Waydroid.bat.tmpl"; Out = "Start-Waydroid.bat" },
    @{ Tmpl = "Stop-Waydroid.bat.tmpl";  Out = "Stop-Waydroid.bat" }
)) {
    $content = Get-Content (Join-Path $TemplatesDir $pair.Tmpl) -Raw
    $content = $content -replace '__DISTRO__', $DistroName
    $outPath = Join-Path $InstallRoot $pair.Out
    Set-Content -Path $outPath -Value $content -Encoding ascii -NoNewline
    Write-Info "Wrote $outPath"
}

# ---------------------------------------------------------------------------
Write-Step "Creating desktop shortcuts"
$WshShell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath("Desktop")

$s1 = $WshShell.CreateShortcut("$desktop\Start Waydroid.lnk")
$s1.TargetPath = Join-Path $InstallRoot "Start-Waydroid.bat"
$s1.WorkingDirectory = $InstallRoot
$s1.IconLocation = "%SystemRoot%\System32\shell32.dll,137"
$s1.Description = "Start Waydroid (Android on WSL)"
$s1.Save()

$s2 = $WshShell.CreateShortcut("$desktop\Stop Waydroid.lnk")
$s2.TargetPath = Join-Path $InstallRoot "Stop-Waydroid.bat"
$s2.WorkingDirectory = $InstallRoot
$s2.IconLocation = "%SystemRoot%\System32\shell32.dll,131"
$s2.Description = "Stop Waydroid (Android on WSL)"
$s2.Save()
Write-Info "Shortcuts created on Desktop."

# ---------------------------------------------------------------------------
if (-not $SkipSmokeTest) {
    Write-Step "Smoke test: starting Waydroid and waiting for it to come up (up to ~2 min)"
    & wsl --shutdown
    Start-Sleep -Seconds 3
    & (Join-Path $InstallRoot "Start-Waydroid.bat") | Out-Null

    $ok = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        $status = & wsl -d $DistroName -e bash -c "waydroid status 2>/dev/null"
        if (($status -join "`n") -match "Session:\s*RUNNING" -and ($status -join "`n") -match "Container:\s*RUNNING") {
            $ok = $true
            break
        }
    }

    if ($ok) {
        Write-Host "`nSMOKE TEST PASSED -- Waydroid session and container are RUNNING." -ForegroundColor Green
    } else {
        Write-Warn2 "Smoke test did not observe RUNNING state within the timeout. Session may still be booting Android for the first time (image decompression, first-boot dexopt) -- check manually with:"
        Write-Warn2 "  wsl -d $DistroName -e waydroid status"
        Write-Warn2 "A 'Weston Compositor' window should still appear on your desktop; give it a few more minutes on first run."
    }

    Write-Step "Stopping Waydroid (smoke test cleanup)"
    & (Join-Path $InstallRoot "Stop-Waydroid.bat") | Out-Null
} else {
    Write-Step "Skipping smoke test (-SkipSmokeTest)"
}

# ---------------------------------------------------------------------------
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " Waydroid install complete." -ForegroundColor Green
Write-Host " Desktop shortcuts: 'Start Waydroid' / 'Stop Waydroid'"
Write-Host " Install folder:    $InstallRoot"
Write-Host "============================================================" -ForegroundColor Green
