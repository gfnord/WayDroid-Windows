<#
.SYNOPSIS
  Reverses Install-Waydroid.ps1: removes desktop shortcuts, launcher files,
  and (optionally) the custom kernel / .wslconfig entries and Waydroid
  itself.

.PARAMETER DistroName
  WSL distro that was targeted by the installer. Default: Ubuntu.

.PARAMETER InstallRoot
  Windows-side folder used by the installer. Default: C:\Waydroid

.PARAMETER RemoveWaydroid
  Also apt-get remove waydroid and delete /var/lib/waydroid (Android images
  etc.). Off by default since that's a large re-download to undo.

.PARAMETER RemoveKernel
  Also revert .wslconfig to not reference the custom kernel (restores the
  most recent .wslconfig.bak-* if present, otherwise just removes the
  kernel=/vmIdleTimeout= lines we added) and delete the built kernel image.
  Requires wsl --shutdown to take effect.
#>
[CmdletBinding()]
param(
    [string]$DistroName = "Ubuntu",
    [string]$InstallRoot = "C:\Waydroid",
    [switch]$RemoveWaydroid,
    [switch]$RemoveKernel
)

$ErrorActionPreference = "Continue"
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

Write-Step "Removing desktop shortcuts"
$desktop = [Environment]::GetFolderPath("Desktop")
Remove-Item "$desktop\Start Waydroid.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item "$desktop\Stop Waydroid.lnk" -Force -ErrorAction SilentlyContinue

Write-Step "Stopping any running Waydroid session"
& wsl -d $DistroName -e bash -c "/opt/waydroid-launcher/waydroid-stop-user.sh" 2>&1 | Out-Null
& wsl -d $DistroName -u root -e bash -c "/opt/waydroid-launcher/waydroid-stop-root.sh" 2>&1 | Out-Null

Write-Step "Removing launcher scripts from WSL"
& wsl -d $DistroName -u root -e bash -c "rm -rf /opt/waydroid-launcher"

if ($RemoveWaydroid) {
    Write-Step "Removing Waydroid and its Android images (this cannot be undone without a full re-init)"
    & wsl -d $DistroName -u root -e bash -c "waydroid container stop 2>/dev/null; apt-get remove -y waydroid; rm -rf /var/lib/waydroid"
}

if ($RemoveKernel) {
    Write-Step "Reverting .wslconfig"
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $backup = Get-ChildItem "$wslConfigPath.bak-*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($backup) {
        Copy-Item $backup.FullName $wslConfigPath -Force
        Write-Host "    Restored $($backup.Name)"
    } elseif (Test-Path $wslConfigPath) {
        $lines = Get-Content $wslConfigPath | Where-Object { $_ -notmatch '^\s*kernel\s*=' -and $_ -notmatch '^\s*vmIdleTimeout\s*=' }
        Set-Content -Path $wslConfigPath -Value $lines -Encoding ascii
        Write-Host "    Stripped kernel=/vmIdleTimeout= lines from $wslConfigPath"
    }
    Write-Host "    Run 'wsl --shutdown' to return to the stock kernel."
    Remove-Item "$InstallRoot\kernel" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step "Removing $InstallRoot\Start-Waydroid.bat / Stop-Waydroid.bat"
Remove-Item "$InstallRoot\Start-Waydroid.bat" -Force -ErrorAction SilentlyContinue
Remove-Item "$InstallRoot\Stop-Waydroid.bat" -Force -ErrorAction SilentlyContinue

Write-Host "`nDone. $InstallRoot left in place in case build source (~/src/wsl-kernel in WSL) is still wanted; delete manually if not." -ForegroundColor Green
