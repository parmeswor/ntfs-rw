# NTFS RW

*Developed by **Pamdai***

Read **and write** Windows (NTFS) drives on macOS — one all-in-one installer. No Homebrew, no Terminal, no extra downloads.

**[⬇ Download the latest release](https://github.com/parmeswor/ntfs-rw/releases/latest)** — macOS 13 or later, Apple Silicon and Intel.

macOS can only read NTFS. NTFS RW bundles the free **macFUSE** and **ntfs-3g** drivers and adds:

| Component | Installed to | What it does |
|---|---|---|
| **NTFS RW.app** | `/Applications` | Lists NTFS drives, makes them writable, settings, uninstall |
| **Auto-mount service** | `/Library/LaunchDaemons/com.ntfsrw.automount.plist` | When macOS mounts an NTFS drive read-only, remounts it read/write |
| **`ntfsctl`** | `/usr/local/bin/ntfsctl` | Command-line control of everything |
| **ntfs-3g**, `ntfsfix` | `/Library/Application Support/NTFSRW/bin` | NTFS driver, compiled from upstream source |
| **macFUSE** core | `/Library/Filesystems/macfuse.fs` | Official, unmodified — installed only if missing or older |
| Config | `/Library/Application Support/NTFSRW/ntfsrw.conf` | Plain `KEY="value"` file |

## Install & first-time setup

1. Download **NTFS-RW-<version>.zip** from [Releases](https://github.com/parmeswor/ntfs-rw/releases/latest), open it, and double-click the `.pkg`. The installer isn't signed by Apple, so macOS asks once: **System Settings → Privacy & Security → Open Anyway**.
2. Open **NTFS RW** and switch on **Full Disk Access** when the orange banner asks (macOS refuses raw access to external disks — even for root — without it).
3. Allow the **macFUSE system extension** once — the app's **Show Me How** button walks through it:
   - **Apple Silicon:** Shut down → hold power → **Options** → **Startup Security Utility** → **Reduced Security** + *Allow user management of kernel extensions from identified developers* → restart → **Privacy & Security → Allow** → restart.
   - **Intel:** **Privacy & Security → Allow**, then restart.
4. Plug in your NTFS drive — it becomes writable automatically.

Updates keep both permissions (builds are signed with a stable identity).

## Build

One-time setup on the build Mac (needs the Xcode Command Line Tools and macFUSE installed, for its headers):

```bash
brew install autoconf automake libtool
```

```bash
tools/make-signing-identity.sh
```

```bash
tools/fetch-vendor.sh
```

```bash
tools/build-ntfs-3g.sh vendor/ntfs-3g/ntfs-3g-2026.9.28.tar.gz vendor/ntfs-3g/dist
```

Then build the installer:

```bash
./build.sh
```

Output in `dist/`: `NTFS-RW-<version>.pkg`, `NTFS-RW-<version>.zip` (pkg + *How to Install.txt*) and the ntfs-3g source tarball — attach all three to the GitHub release.

- **Signing:** `tools/make-signing-identity.sh` creates a free self-signed identity in `~/.ntfsrw-signing` (outside the repo — back it up). Every build signed with it keeps the same identity, so users' Full Disk Access survives updates. It does not remove Gatekeeper's "Open Anyway" step; that needs an Apple Developer ID: `SIGN_APP="Developer ID Application: …" SIGN_PKG="Developer ID Installer: …" ./build.sh`, then notarize with `xcrun notarytool`.
- **Versions:** macFUSE and ntfs-3g are pinned (URL + SHA-256) in `tools/fetch-vendor.sh` and `build.sh`.

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
| `NTFS3G_BIN` | *(auto)* | Override the `ntfs-3g` binary (default: the bundled one) |

Tip: `auto_xattr` stores macOS metadata in `._*` files on the drive. Remove it from `MOUNT_OPTIONS` if you don't want those files visible in Windows.

## How it works

The LaunchDaemon runs `NTFS RW.app` in a headless `--helper` mode, which spawns `ntfsctl automount` as its child — so the Full Disk Access granted to *NTFS RW* applies. It uses `StartOnMount`, so launchd runs it every time *any* filesystem is mounted, and `QueueDirectories`, so `sudo ntfsctl mount/repair` and the app hand their work to it instead of hitting the raw device themselves. That command finds NTFS partitions that macOS mounted read-only, unmounts them, and remounts them with `ntfs-3g` as the logged-in user (uid/gid) so Finder can write. Drives you ejected are never re-mounted behind your back, and a drive that fails is not retried until reboot or a manual `mount` (prevents loops with the read-only fallback).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Genuinely hibernated / Fast Startup ("Windows is hibernated, refused to mount") | Shut Windows down fully, or without Windows: `sudo ntfsctl repair diskXsY` (clears the Windows journal with `ntfsfix`; changes Windows hadn't saved are lost) |
| "Operation not permitted" / "The NTFS partition is in an unsafe state" on a Mac without Windows | Usually Full Disk Access is missing (step 4) — ntfs-3g reports *any* permission error with the "unsafe state" text. `ntfsctl doctor` shows the FDA status |
| ntfs-3g fails to load FUSE / "System Extension Blocked" | Allow the macFUSE system extension (step 3 above, or **Show Me How** in the app), then restart |
| Drive stays read-only | `ntfsctl doctor`, then `ntfsctl log` |
| "Resource busy" when making writable | Close apps/Finder windows using the drive and try again |

**Always eject before unplugging** — NTFS written by ntfs-3g has no journal replay on macOS.

## Uninstall

NTFS RW → Settings → **Uninstall NTFS RW…**, or:

```bash
sudo ntfsctl uninstall
```

This removes NTFS RW and its bundled ntfs-3g. macFUSE stays, because other apps may use it; remove it with `/Library/Filesystems/macfuse.fs/Contents/Resources/uninstall_macfuse.app`.

## Project layout

```
build.sh                       builds the all-in-one dist/NTFS-RW-<version>.pkg
tools/fetch-vendor.sh          downloads + verifies macFUSE and ntfs-3g (pinned)
tools/build-ntfs-3g.sh         compiles universal ntfs-3g/ntfsfix from source
tools/make-signing-identity.sh free self-signed code-signing identity
src/ntfsctl                    CLI + auto-mount logic (bash 3.2)
src/com.ntfsrw.automount.plist LaunchDaemon
src/newsyslog-ntfsrw.conf      log rotation for /var/log/ntfsrw.log
src/app/                       SwiftUI app, Info.plist, icon renderer
pkg/scripts/                   preinstall / postinstall
pkg/distribution.xml, pkg/resources/   installer UI (installs macFUSE only when needed)
pkg/NOTICE.txt                 third-party notices (installer License page)
```

## Third-party software

- **macFUSE** — © Benjamin Fleischer, BSD-style license with additional conditions (shown in the installer and installed to `/Library/Application Support/NTFSRW/licenses/`). Its license forbids bundling it with *commercial* software without permission; NTFS RW is free.
- **ntfs-3g** — © Tuxera Inc. and contributors, GPL v2. The exact source used is installed alongside the binaries and attached to every release.
