# Waydroid on WSL2 — Automated Installer

Runs Android (Waydroid) under WSL2 Ubuntu on Windows, launchable from a
desktop shortcut. This package rebuilds and applies every fix discovered
while getting this working reliably — see "What this actually does" below.

## Requirements

- Windows 11 (or Windows 10 with WSLg backported) with a working GPU driver
- WSL2 installed, with an Ubuntu (or other apt-based) distro already
  installed and its first-run user setup completed
  (`wsl --install -d Ubuntu`, then log in once)
- Internet access (clones the WSL2 kernel source, ~1-2GB; downloads Android
  system/vendor images via `waydroid init`, ~1GB)
- ~15GB free disk space, a few dozen GB more headroom is safer
- Regular PowerShell (no Administrator needed — everything either writes to
  your user profile or elevates via `wsl -u root`, not Windows-side)

## Install

```powershell
cd Waydroid-WSL-Installer
.\Install-Waydroid.ps1
```

Optional parameters:

```powershell
.\Install-Waydroid.ps1 -DistroName Ubuntu-22.04 -InstallRoot D:\Apps\Waydroid
```

Takes **10-25 minutes**, dominated by the kernel compile. At the end it runs
a smoke test (starts Waydroid, waits for it to report `RUNNING`, stops it
again) and prints PASS/FAIL. Two desktop shortcuts are created:
**Start Waydroid** and **Stop Waydroid**.

First launch after install will take longer than subsequent ones — Android's
first boot does dexopt/setup work that later boots skip.

## Re-running / updating

The script is idempotent: if Waydroid is already installed it skips
`waydroid init` (won't re-download images), and `-SkipKernelBuild` skips the
kernel stage entirely (use this if you're just fixing the launcher scripts
after a Waydroid update and the WSL kernel version hasn't changed).

## Uninstall

```powershell
.\Uninstall-Waydroid.ps1                                # shortcuts + launcher scripts only
.\Uninstall-Waydroid.ps1 -RemoveWaydroid                 # + apt remove waydroid, delete Android images
.\Uninstall-Waydroid.ps1 -RemoveWaydroid -RemoveKernel   # + revert to stock WSL2 kernel
```

## What this actually does (and why)

WSL's stock kernel doesn't have Android binder/binderfs support, so a custom
kernel is required. Getting Waydroid to actually *render* reliably through
WSLg surfaced several unrelated bugs; this installer works around all of
them:

| Problem | Fix |
|---|---|
| Stock WSL2 kernel has no `CONFIG_ANDROID_BINDER_IPC` | Clone the exact matching `microsoft/WSL2-Linux-Kernel` tag for your running kernel version, enable binder/binderfs, rebuild |
| `modprobe bridge iptable_nat ...` only loads the first module — the rest are silently treated as *parameters* of the first, not separate modules | Load each module in its own `modprobe` call |
| WSLg windows render solid black with `[WARN:COPY MODE]` in the title if a tmpfs is mounted at `/mnt/shared_memory` — it shadows the shared-memory transport WSLg uses to hand buffers to the Windows RDP client | Do **not** mount anything there; the installer removes the hook earlier versions added |
| Windows' Start Menu auto-generates + indexes a shortcut per installed Android app, cluttering it with a dozen entries | Per-app `.desktop` files moved out of the scanned folder |
| Waydroid's compositor bridge renders a stuck 1×1 buffer when talking directly to WSLg's RDP-backed compositor | Run Android inside a nested Weston window (software-rendered) instead of connecting directly |
| Waydroid auto-freezes its Android container the instant its window loses OS focus (including mid-boot, before you've even switched away) | Patch `hardware_manager.py`'s `suspend()` to support a real "never suspend" mode, set `suspend_action = none` |
| Any app crash kills `system_server`: adding the crash-dialog window fails here, and the exception lands on the `android.ui` thread (`FATAL EXCEPTION IN SYSTEM PROCESS: android.ui / Adding window failed`). Every restart tears down the network, so it presents as flaky internet | `settings put global hide_error_dialogs 1` after boot |
| Android never installs a default route -- `netd`'s BPF/xt_quota setup fails on the WSL kernel, so `EthernetService` blocks in `awaitIpClientStart()`. DHCP still leases an address, so it looks connected | Add the route through `ndc` (netd owns it; `ip route add` targets the wrong table and gets reverted) |
| WSL tears down the entire VM ~60s after the last `wsl.exe` connection closes, killing everything the shortcut started, even backgrounded/detached processes | `vmIdleTimeout=-1` in `.wslconfig` |
| `waydroid session start`'s log output is buffered when redirected to a file — a fixed "wait 8 seconds" guess before calling `show-full-ui` is unreliable | Poll the session log for the actual "is ready" line (up to 90s) with `PYTHONUNBUFFERED=1` |
| `wsl -d X -e bash /path/script.sh` (direct exec) was less reliable at letting a `setsid`-detached background process survive than `wsl -d X -e bash -c "/path/script.sh"` | Launcher `.bat` files use the `-c` form |

## Troubleshooting

**Switching image type (VANILLA <-> GAPPS) breaks networking / Play Store:**
`waydroid init -s GAPPS -f` replaces the *system* image but keeps `/data`.
Package UIDs differ between image types, so the old data files are owned by
the wrong UID and PackageManager logs `was user id 0 but is now user
... I am not changing its files so it will probably fail!`. In practice
`com.android.networkstack` breaks, `IpClient` never starts, `EthernetService`
blocks forever and `dumpsys connectivity` reports `Active default network:
none` -- browsers still work (raw sockets) but Google Play refuses, since it
asks ConnectivityManager first. Move `~/.local/share/waydroid/data` aside and
start again so Android rebuilds it against the new image.

**Window opens but stays black / title says `[WARN:COPY MODE]`:**
Something has mounted a tmpfs at `/mnt/shared_memory`, which breaks WSLg's
buffer sharing and makes *every* WSLg window render black — not just Waydroid.
Confirm with a plain GUI app (`wsl -d <distro> -e weston-terminal`); if that is
black too, the problem is WSLg, not Waydroid. Remove the mount and any
`command=` line in `/etc/wsl.conf` that creates it, then `wsl --shutdown` and
start again. A full shutdown is required — `wsl -t <distro>` restarts only that
distro and leaves the WSLg system distro running with the broken state.

**Window opens, stays blank/gray, Android never appears:**
Android is probably still booting (can take 60-90s, longer on first launch).
Check `wsl -d <distro> -e waydroid status` — if `Container: FROZEN`, the
suspend patch didn't take; re-run the installer or manually
`wsl -d <distro> -u root -e lxc-unfreeze -P /var/lib/waydroid/lxc -n waydroid`.

**Nothing happens / window never opens at all:**
Check `wsl -l -v` — if the distro shows `Stopped` right after running the
shortcut, `vmIdleTimeout=-1` didn't take effect (needs `wsl --shutdown` after
editing `.wslconfig`, which the installer does — if you edited `.wslconfig`
by hand afterward, redo that).

**`waydroid init` or the kernel clone hangs / fails:** network/proxy issue —
both need outbound HTTPS to github.com and sourceforge.net.

## Package contents

```
Install-Waydroid.ps1        Main installer (run this)
Uninstall-Waydroid.ps1       Reverses it
templates/
  waydroid-start-root.sh     Loads kernel modules, starts container (root)
  waydroid-start-user.sh     Nested Weston + session start + show-full-ui
  waydroid-stop-root.sh      Stops container (root)
  waydroid-stop-user.sh      Stops session + nested Weston
  Start-Waydroid.bat.tmpl    Windows shortcut target (__DISTRO__ substituted)
  Stop-Waydroid.bat.tmpl
  patch_hardware_manager.py  Disables Waydroid's auto-suspend-on-blur
```
