#!/bin/bash
#
# Downloads the third-party components bundled into the NTFS RW package and
# verifies their SHA-256 checksums. Files go to vendor/ (not committed).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT_DIR/vendor"

MACFUSE_VERSION="5.4.0"
MACFUSE_URL="https://github.com/macfuse/macfuse/releases/download/macfuse-$MACFUSE_VERSION/macfuse-$MACFUSE_VERSION.dmg"
MACFUSE_SHA256="861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5"

NTFS3G_VERSION="2026.9.28"
NTFS3G_URL="https://github.com/tuxera/ntfs-3g/archive/refs/tags/$NTFS3G_VERSION.tar.gz"
NTFS3G_SHA256="8a75293f07bf40df5701d296de32a4cb0e46d6ae135abb4f41b438df9868a390"

fetch() { # url sha256 dest
    local url="$1" sum="$2" dest="$3"
    if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sum" ]; then
        echo "==> $(basename "$dest") already downloaded"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    echo "==> Downloading $url"
    curl -fL --retry 3 -o "$dest.part" "$url"
    if [ "$(shasum -a 256 "$dest.part" | cut -d' ' -f1)" != "$sum" ]; then
        rm -f "$dest.part"
        echo "Checksum mismatch for $(basename "$dest") — refusing to use it." >&2
        exit 1
    fi
    mv "$dest.part" "$dest"
}

fetch "$MACFUSE_URL" "$MACFUSE_SHA256" "$VENDOR/macfuse/macfuse-$MACFUSE_VERSION.dmg"
fetch "$NTFS3G_URL" "$NTFS3G_SHA256" "$VENDOR/ntfs-3g/ntfs-3g-$NTFS3G_VERSION.tar.gz"
echo "==> Verified. Next: tools/build-ntfs-3g.sh vendor/ntfs-3g/ntfs-3g-$NTFS3G_VERSION.tar.gz vendor/ntfs-3g/dist"
