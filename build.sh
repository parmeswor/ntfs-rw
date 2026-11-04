#!/bin/bash
#
# Builds dist/NTFS-RW-<version>.pkg
#
#   ./build.sh                     # unsigned package
#   VERSION=1.1.0 ./build.sh
#   SIGN_APP="Developer ID Application: Name (TEAMID)" \
#   SIGN_PKG="Developer ID Installer: Name (TEAMID)" ./build.sh
#
set -euo pipefail

VERSION="${VERSION:-1.1.0}"
PKG_ID="com.ntfsrw.pkg"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT_DIR/src"
BUILD="$ROOT_DIR/build"
DIST="$ROOT_DIR/dist"
PAYLOAD="$BUILD/payload"
APP="$PAYLOAD/Applications/NTFS RW.app"
COMPONENT="ntfsrw-component.pkg"
OUT="$DIST/NTFS-RW-$VERSION.pkg"

step() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

rm -rf "$BUILD"
mkdir -p "$PAYLOAD" "$DIST"

step "Staging ntfsctl, daemon and config"
install -d -m 755 "$PAYLOAD/usr/local/bin" "$PAYLOAD/Library/LaunchDaemons" \
    "$PAYLOAD/Library/Application Support/NTFSRW" "$PAYLOAD/private/etc/newsyslog.d"
install -d -m 700 "$PAYLOAD/Library/Application Support/NTFSRW/queue"
sed "s/@VERSION@/$VERSION/" "$SRC/ntfsctl" > "$PAYLOAD/usr/local/bin/ntfsctl"
chmod 755 "$PAYLOAD/usr/local/bin/ntfsctl"
install -m 644 "$SRC/com.ntfsrw.automount.plist" "$PAYLOAD/Library/LaunchDaemons/"
install -m 644 "$SRC/newsyslog-ntfsrw.conf" "$PAYLOAD/private/etc/newsyslog.d/ntfsrw.conf"

# Default config is produced by ntfsctl's own writer so the two never drift.
CFG_TMP="$BUILD/cfg"; mkdir -p "$CFG_TMP"
sed -e "s|^SUPPORT_DIR=.*|SUPPORT_DIR=\"$CFG_TMP\"|" \
    -e 's|^cmd="${1:-help}"|set_defaults; write_config; exit 0|' \
    "$PAYLOAD/usr/local/bin/ntfsctl" > "$CFG_TMP/gen"
bash "$CFG_TMP/gen"
install -m 644 "$CFG_TMP/ntfsrw.conf" "$PAYLOAD/Library/Application Support/NTFSRW/ntfsrw.conf.default"

step "Compiling NTFS RW.app (universal)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos13.0" \
        -o "$BUILD/NTFSRW-$arch" "$SRC/app/NTFSRW.swift"
done
lipo -create -output "$APP/Contents/MacOS/NTFSRW" "$BUILD/NTFSRW-arm64" "$BUILD/NTFSRW-x86_64"
sed "s/@VERSION@/$VERSION/g" "$SRC/app/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

step "Rendering app icon"
if swift "$SRC/app/make_icon.swift" "$BUILD/AppIcon.iconset" 2>/dev/null \
   && iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$BUILD/AppIcon.iconset"; then
    :
else
    echo "   (icon generation failed; continuing without an icon)"
fi

step "Code signing app"
if [ -n "${SIGN_APP:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$APP"
else
    codesign --force --sign - "$APP"   # ad-hoc
fi

step "Building component package"
# Strip removable extended attributes (quarantine, Finder info). The kernel-protected
# com.apple.provenance attribute stays and is archived as ._* entries, which
# Installer merges back into xattrs — no ._ files are created on disk.
xattr -cr "$PAYLOAD" 2>/dev/null || true
pkgbuild --analyze --root "$PAYLOAD" "$BUILD/component.plist" >/dev/null
# Always install the app to /Applications, never "relocate" to another copy.
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$BUILD/component.plist"
pkgbuild --root "$PAYLOAD" \
    --component-plist "$BUILD/component.plist" \
    --scripts "$ROOT_DIR/pkg/scripts" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location / \
    "$BUILD/$COMPONENT"

step "Building product archive"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@PKG_ID@/$PKG_ID/g" -e "s/@COMPONENT@/$COMPONENT/g" \
    "$ROOT_DIR/pkg/distribution.xml" > "$BUILD/distribution.xml"
rm -f "$OUT"
productbuild --distribution "$BUILD/distribution.xml" \
    --resources "$ROOT_DIR/pkg/resources" \
    --package-path "$BUILD" \
    ${SIGN_PKG:+--sign "$SIGN_PKG"} \
    "$OUT"

step "Creating shareable zip (pkg + install guide)"
SHARE="$BUILD/NTFS RW $VERSION"
mkdir -p "$SHARE"
cp "$OUT" "$SHARE/"
sed "s/@VERSION@/$VERSION/g" "$ROOT_DIR/pkg/HOW-TO-INSTALL.txt" > "$SHARE/How to Install.txt"
rm -f "$DIST/NTFS-RW-$VERSION.zip"
ditto -c -k --norsrc --keepParent "$SHARE" "$DIST/NTFS-RW-$VERSION.zip"

step "Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "   Share: $DIST/NTFS-RW-$VERSION.zip"
[ -n "${SIGN_PKG:-}" ] || echo "   Unsigned. To notarize: sign with SIGN_PKG/SIGN_APP, then 'xcrun notarytool submit'."
