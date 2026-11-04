#!/bin/bash
#
# Builds universal (arm64 + x86_64) ntfs-3g and ntfsfix from the pinned upstream
# source, statically linked against libntfs-3g. The only non-system dependency
# is macFUSE's /usr/local/lib/libfuse.2.dylib, which the NTFS RW installer provides.
#
#   tools/build-ntfs-3g.sh <source.tar.gz> <output-dir>
#
# Build requirements (developer Mac only): Xcode Command Line Tools, macFUSE
# (for its headers and libfuse), and autoconf/automake/libtool:
#   brew install autoconf automake libtool
#
set -euo pipefail

TARBALL="$1"
OUT="$2"
MIN_MACOS="13.0"
WORK="$(dirname "$OUT")/ntfs-3g-build"

[ -f /usr/local/lib/libfuse.2.dylib ] && [ -d /usr/local/include/fuse ] \
    || { echo "macFUSE must be installed on the build Mac (headers + libfuse)." >&2; exit 1; }
command -v autoreconf >/dev/null && command -v glibtoolize >/dev/null \
    || { echo "Missing autotools. Run: brew install autoconf automake libtool" >&2; exit 1; }

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

for arch in arm64 x86_64; do
    echo "==> ntfs-3g: building $arch"
    src="$WORK/$arch"
    mkdir -p "$src"
    tar -xzf "$TARBALL" -C "$src" --strip-components 1
    (
        cd "$src"
        export LIBTOOLIZE=glibtoolize
        autoreconf -fi >/dev/null 2>&1
        export CC="clang -arch $arch -mmacosx-version-min=$MIN_MACOS"
        export CFLAGS="-O2"
        export FUSE_MODULE_CFLAGS="-I/usr/local/include/fuse -D_FILE_OFFSET_BITS=64 -D_DARWIN_USE_64_BIT_INODE"
        export FUSE_MODULE_LIBS="-L/usr/local/lib -lfuse"
        # Keep Homebrew's libraries (gettext, gcrypt, ...) out of the build.
        export PKG_CONFIG_LIBDIR=/nonexistent
        ./configure --host="$arch-apple-darwin" \
            --prefix="/Library/Application Support/NTFSRW" \
            --with-fuse=external --disable-shared --enable-static \
            --disable-ldconfig --disable-mtab --disable-crypto --disable-nls \
            --disable-dependency-tracking --without-uuid --without-hd \
            > "$WORK/configure-$arch.log" 2>&1 \
            || { tail -30 "$WORK/configure-$arch.log"; exit 1; }
        make -j"$(sysctl -n hw.ncpu)" > "$WORK/make-$arch.log" 2>&1 \
            || { tail -40 "$WORK/make-$arch.log"; exit 1; }
    )
done

for tool in src/ntfs-3g ntfsprogs/ntfsfix; do
    name="$(basename "$tool")"
    for arch in arm64 x86_64; do   # --disable-shared: no libtool wrapper scripts
        file "$WORK/$arch/$tool" | grep -q Mach-O || { echo "$WORK/$arch/$tool is not a binary" >&2; exit 1; }
    done
    lipo -create -output "$OUT/$name" "$WORK/arm64/$tool" "$WORK/x86_64/$tool"
    strip -x "$OUT/$name"
done

cp "$TARBALL" "$OUT/"
echo "==> ntfs-3g: built $(ls "$OUT" | tr '\n' ' ')"
