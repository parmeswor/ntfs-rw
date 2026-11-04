# NTFS RW

*Developed by **Pamdai***

Read **and write** Windows (NTFS) drives on macOS, packaged as a single `.pkg`.

macOS can only read NTFS. NTFS RW uses the free **macFUSE** and **ntfs-3g** drivers and adds:

| Component | Installed to | What it does |
|---|---|---|
| **NTFS RW.app** | `/Applications` | Lists NTFS drives, makes them writable, settings, uninstall |
| **Auto-mount service** | `/Library/LaunchDaemons/com.ntfsrw.automount.plist` | When macOS mounts an NTFS drive read-only, remounts it read/write |
| **`ntfsctl`** | `/usr/local/bin/ntfsctl` | Command-line control of everything |
| Config | `/Library/Application Support/NTFSRW/ntfsrw.conf` | Plain `KEY="value"` file |

## Build

```bash
./build.sh
```

Output: `dist/NTFS-RW-1.0.0.pkg` (universal: Apple Silicon + Intel, macOS 13+). Needs only the Xcode Command Line Tools.

To distribute to other Macs without Gatekeeper warnings, sign and notarize:

```bash
SIGN_APP="Developer ID Application: Your Name (TEAMID)" SIGN_PKG="Developer ID Installer: Your Name (TEAMID)" ./build.sh
```

```bash
xcrun notarytool submit dist/NTFS-RW-1.0.0.pkg --keychain-profile <profile> --wait && xcrun stapler staple dist/NTFS-RW-1.0.0.pkg
```

## Install & first-time setup

1. Open `NTFS-RW-1.0.0.pkg` and follow the installer.
2. Open **NTFS RW** from Applications. If macFUSE / ntfs-3g are missing, click **Install…** — Terminal opens and runs `ntfsctl install-deps` (via [Homebrew](https://brew.sh): `macfuse` cask + `gromgit/fuse/ntfs-3g-mac`).
3. **Apple Silicon only, once:** macFUSE's kernel extension must be allowed:
   1. Shut down → hold the power button → **Options** → **Startup Security Utility**
   2. Select **Reduced Security** and tick **Allow user management of kernel extensions from identified developers**
   3. Restart → **System Settings → Privacy & Security** → **Allow** the macFUSE developer → restart
4. **Full Disk Access (required, once):** System Settings → **Privacy & Security → Full Disk Access** → turn on **NTFS RW** (click **+** and choose it from Applications if it isn't listed). macOS refuses raw access to external disks — even for root — without it. The app shows an **Open Settings** banner until this is done. With an unsigned (ad-hoc) build, re-toggle it after each update.
5. Plug in your NTFS drive. It becomes writable automatically (a notification confirms it).

## Everyday use

**App:** the main switch turns auto-mount on/off; each drive has **Make Writable / Mount**, **Eject**, **Open**, and an **Auto** checkbox to exclude that drive. *Settings…* holds the remaining options.

**Terminal:**

```bash
ntfsctl status
```

```bash
sudo ntfsctl mount disk4s1
```

```bash
sudo ntfsctl unmount disk4s1
```

```bash
sudo ntfsctl auto off
```

```bash
sudo ntfsctl exclude add disk4s1
```

```bash
sudo ntfsctl config set NOTIFY=no OPEN_IN_FINDER=yes
```

```bash
ntfsctl log -f
```

Run `ntfsctl help` for everything.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `AUTO_MOUNT` | `yes` | Remount NTFS drives read/write when they are connected |
| `AUTO_MOUNT_INTERNAL` | `no` | Also auto-mount NTFS on internal disks (Boot Camp) |
| `FALLBACK_READONLY` | `yes` | If read/write fails, remount read-only so the drive is still usable |
| `NOTIFY` | `yes` | macOS notification on success/failure |
| `OPEN_IN_FINDER` | `no` | Open the drive in Finder after mounting |
| `MOUNT_ROOT` | `/Volumes` | Where mount points are created |
| `MOUNT_OPTIONS` | `local,allow_other,auto_xattr,auto_cache,windows_names` | Options passed to `ntfs-3g -o` |
| `EXCLUDE` | *(empty)* | Comma-separated volume IDs never auto-mounted (IDs shown by `ntfsctl list`) |
| `NTFS3G_BIN` | *(auto)* | Path to `ntfs-3g` if not in a standard Homebrew/MacPorts location |

Tip: `auto_xattr` stores macOS metadata in `._*` files on the drive. Remove it from `MOUNT_OPTIONS` if you don't want those files visible in Windows.

## How it works

The LaunchDaemon runs `NTFS RW.app` in a headless `--helper` mode, which spawns `ntfsctl automount` as its child — so the Full Disk Access granted to *NTFS RW* applies. It uses `StartOnMount`, so launchd runs it every time *any* filesystem is mounted, and `QueueDirectories`, so `sudo ntfsctl mount/repair` and the app hand their work to it instead of hitting the raw device themselves. That command finds NTFS partitions that macOS mounted read-only, unmounts them, and remounts them with `ntfs-3g` as the logged-in user (uid/gid) so Finder can write. Drives you ejected are never re-mounted behind your back, and a drive that fails is not retried until reboot or a manual `mount` (prevents loops with the read-only fallback).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Genuinely hibernated / Fast Startup ("Windows is hibernated, refused to mount") | Shut Windows down fully, or without Windows: `sudo ntfsctl repair diskXsY` (clears the Windows journal with `ntfsfix`; changes Windows hadn't saved are lost) |
| "Operation not permitted" / "The NTFS partition is in an unsafe state" on a Mac without Windows | Usually Full Disk Access is missing (step 4) — ntfs-3g reports *any* permission error with the "unsafe state" text. `ntfsctl doctor` shows the FDA status |
| ntfs-3g fails to load FUSE / "System Extension Blocked" | Complete the Apple Silicon kernel-extension steps above, then reboot |
| Drive stays read-only | `ntfsctl doctor`, then `ntfsctl log` |
| "Resource busy" when making writable | Close apps/Finder windows using the drive and try again |

**Always eject before unplugging** — NTFS written by ntfs-3g has no journal replay on macOS.

## Uninstall

NTFS RW → Settings → **Uninstall NTFS RW…**, or:

```bash
sudo ntfsctl uninstall
```

macFUSE and ntfs-3g are left installed (`brew uninstall ntfs-3g-mac && brew uninstall --cask macfuse` removes them).

## Project layout

```
build.sh                       builds dist/NTFS-RW-<version>.pkg
src/ntfsctl                    CLI + auto-mount logic (bash 3.2)
src/com.ntfsrw.automount.plist LaunchDaemon
src/newsyslog-ntfsrw.conf      log rotation for /var/log/ntfsrw.log
src/app/                       SwiftUI app, Info.plist, icon renderer
pkg/scripts/                   preinstall / postinstall
pkg/distribution.xml, pkg/resources/   installer UI
```

ntfs-3g is GPL-licensed and macFUSE has its own license; neither is bundled — they are installed from their official sources by `ntfsctl install-deps`.
