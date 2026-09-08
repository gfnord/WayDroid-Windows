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

## Display size

The window defaults to a portrait, phone-shaped 720x1280. Both values live at
the top of `templates/waydroid-start-user.sh`:

```bash
WIDTH=720
HEIGHT=1280
```

Android picks phone vs tablet layouts from the display width in dp
(`px / density * 160`), so `waydroid-post-boot.sh` derives a density that keeps
the width near a phone's 360dp — change the geometry and the layout follows
without hand-tuning a density. Weston keeps a few rows for its own panel, so
the reported size is slightly shorter than `HEIGHT`.

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

## Issues found while getting this working

Everything below was hit on a real end-to-end install and is fixed in the
current scripts. Recorded because most of them fail *silently* or with an
error that points somewhere unhelpful.

### Installer bugs

**Kernel config step aborted immediately.**
`bash: -c: line 2: syntax error: unexpected end of file`, naming
`./scripts/config --set-val CONFIG_ANDROID_BINDER_IPC y` as the shell. The
command was concatenated from string fragments *inside* a PowerShell `@(...)`
array literal. A newline inside an array literal separates elements, so a
trailing `+` does not continue the expression — the array parsed to 12
elements instead of 6, and `bash -c` got only the first fragment, a script
ending in a dangling `&&`. The rest arrived as `$0`, `$1`, …, which is why the
error quoted a `scripts/config` invocation as the shell name. *Fix:* build the
command in a variable using backtick continuations, then pass it as one
argument.

**CRLF broke every shell payload sent into WSL.**
`Install-Waydroid.ps1` is CRLF, so its multi-line string literals carry CR,
and bash treats CR as part of a token. Two failures: a heredoc opened with
`<< "PYEOF"` looked for a terminator line equal to `PYEOF<CR>` and never found
one; and the launcher `.sh` files were copied in verbatim, so `#!/bin/bash<CR>`
made the kernel look for an interpreter literally named `/bin/bash<CR>` —
exit 127, `cannot execute: required file not found`. *Fix:* `Invoke-Wsl`
normalizes CRLF to LF on every argument, launchers are installed through
`tr -d '\r'`, and `.gitattributes` pins `*.sh`/`*.py` to LF.

**Weston was never installed.**
The launcher runs Android inside a nested Weston compositor, but nothing ever
installed it. Because the launcher backgrounds everything with `setsid nohup`
and redirects to logs, the missing binary produced no visible error and the
script still exited 0: the shortcut reported success and no window appeared.
*Fix:* install `weston` as its own idempotent step (deliberately not folded
into the Waydroid install block, which is skipped when Waydroid is already
present), and have the launcher check for it up front and fail loudly.

**The Start Menu mitigation did nothing.**
It ran right after `waydroid init`, but Waydroid generates the per-app
`.desktop` files when a session *first starts* — so the glob matched nothing,
`2>/dev/null; true` swallowed it, and the step reported success while every
Android app stayed in the Start Menu. *Fix:* moved to the end, after the smoke
test; it now reports how many files it moved so a future no-op is visible.

**Clicking Start twice broke a running session.**
The launcher unconditionally `pkill`ed Weston, killing the compositor out from
under a live session. The session survives but its Wayland connection is gone,
and `waydroid session start` then refuses with `Session is already running`, so
nothing reattaches — you get an empty Weston window with no way out but a full
stop. *Fix:* the launcher now re-shows the UI if everything is healthy, and
tears the session down first if its compositor died.

### Waydroid / WSL behavior

**Android gets an IP but no gateway.**
`netd`'s BPF and `xt_quota` setup fails against the WSL kernel — logcat shows
`Unable to swap active stats map: Address family not supported by protocol` and
a missing `/proc/net/xt_quota/globalAlert` — so `EthernetService` blocks in
`awaitIpClientStart()` and never finishes bringing the link up. DHCP still
hands out a lease, so Android looks connected while nothing reaches the
internet. *Fix:* `waydroid-post-boot.sh` adds the route through `ndc`. It must
go through netd: Android resolves app traffic in netd's per-network table, not
`main`, and netd reverts routes in `main` that it does not own — so a plain
`ip route add` targets the wrong table *and* disappears within a minute.
netd also rejects the gateway route until the connected subnet route exists in
that table first.

**Any app crash killed the whole framework.**
ActivityManager tries to show its "app has stopped" dialog, adding that window
fails in this compositor setup, and the exception lands on system_server's
`android.ui` thread:

```
FATAL EXCEPTION IN SYSTEM PROCESS: android.ui
java.lang.RuntimeException: Adding window failed
  at android.app.Dialog.show(Dialog.java:352)
  at com.android.server.am.ErrorDialogController...
```

system_server dies, the framework restarts and the network goes with it. The
symptom is not "Android keeps restarting" but *intermittent internet* — things
work for a minute, then stop. Browsers last longest because they hold open
sockets; Google Play re-queries ConnectivityManager and reports no connection.
*Fix:* `settings put global hide_error_dialogs 1`, applied after boot.

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

**An app says "This app won't work for your device":**
The images are `x86_64` with no ARM translation layer
(`ro.dalvik.vm.native.bridge` is `0`, no `libhoudini.so` / `libndk_translation.so`),
so any app shipping only `arm64-v8a`/`armeabi-v7a` native libraries is genuinely
incompatible. This is unrelated to Play certification and registering the device
will not change it. Installing an ARM translation layer (e.g. via
[waydroid_script](https://github.com/casualsnek/waydroid_script)) is the only fix.

**Google Play still says the device is uncertified after registering:**
GMS caches the verdict in `gservices.db` with an expiry roughly 24h out, and
neither clearing Play Store/Play Services nor broadcasting
`android.server.checkin.CHECKIN` forces a re-fetch — the stored
`uncertified_status` and its "remaining time" stay byte-identical. Either wait
for the expiry or accept it; do **not** clear `com.google.android.gsf` to force
it, because that regenerates the Android ID and invalidates the registration you
just did.

**Resizing the Weston window restarts Android:**
Waydroid restarts the session when its compositor output changes size. Set the
size once via `WIDTH`/`HEIGHT` at the top of `waydroid-start-user.sh` instead of
dragging the window.

**Do not set `persist.waydroid.width` / `persist.waydroid.height`:**
On this image they crash-loop the hwcomposer inside `hwc_wayland_thread`
(hundreds of `F DEBUG` tombstones, taking SurfaceFlinger with it), whether set
in `waydroid_base.prop` or on a live session. Size the nested Weston window
instead, which is what `WIDTH`/`HEIGHT` do.

**`waydroid init` or the kernel clone hangs / fails:** network/proxy issue —
both need outbound HTTPS to github.com and sourceforge.net.

## Known limitations

- **One API level.** The image is Android 13 / API 33. There is no way to
  target another API level, so this is not a substitute for an AVD when
  testing across Android versions.
- **`x86_64` only.** No ARM translation layer, so ARM-only apps cannot be
  installed at all (see Troubleshooting).
- **Software rendering.** ANGLE falls back to software (`ZINK: failed to
  choose pdev`, `failed to create dri2 screen`), so graphics-heavy apps will
  perform worse here than on real hardware and GPU-dependent behavior is not
  representative.
- **Fixed window size.** Resizing restarts the session; change `WIDTH`/`HEIGHT`
  in `waydroid-start-user.sh` instead.
- **`wsl -t <distro>` is not enough** when WSLg itself misbehaves. It restarts
  only that distro and leaves the WSLg system distro running with the same
  state. Use `wsl --shutdown`.

## Package contents

```
Install-Waydroid.ps1         Main installer (run this)
Uninstall-Waydroid.ps1       Reverses it
.gitattributes               Forces LF on *.sh/*.py (CRLF breaks them in WSL)
templates/
  waydroid-start-root.sh     Loads kernel modules, starts container (root)
  waydroid-start-user.sh     Nested Weston + session start + show-full-ui;
                             WIDTH/HEIGHT live here
  waydroid-post-boot.sh      Runs as root once Android is up: suppresses the
                             error dialogs that kill system_server, adds the
                             default route via ndc, sets display density
  waydroid-stop-root.sh      Stops container (root)
  waydroid-stop-user.sh      Stops session + nested Weston
  Start-Waydroid.bat.tmpl    Windows shortcut target (__DISTRO__ substituted)
  Stop-Waydroid.bat.tmpl
  patch_hardware_manager.py  Disables Waydroid's auto-suspend-on-blur
```
