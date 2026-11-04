#!/bin/bash
#
# Builds the all-in-one installer dist/NTFS-RW-<version>.pkg (+ a shareable zip).
# It contains NTFS RW, ntfs-3g and the official macFUSE core component, so users
# need nothing else (no Homebrew).
#
# One-time setup on the build Mac:
#   brew install autoconf automake libtool        # to compile ntfs-3g
#   tools/make-signing-identity.sh                # free self-signed signing identity
#   tools/fetch-vendor.sh                         # download + verify macFUSE and ntfs-3g
#   tools/build-ntfs-3g.sh vendor/ntfs-3g/ntfs-3g-<ver>.tar.gz vendor/ntfs-3g/dist
#
# Then:
#   ./build.sh                     # or: VERSION=1.3.0 ./build.sh
#
# Signing, in order of preference:
#   1. SIGN_APP / SIGN_PKG (Apple Developer ID)   no Gatekeeper warning once notarized
#   2. ~/.ntfsrw-signing (make-signing-identity)  free; Full Disk Access survives updates
#   3. ad-hoc                                     users must re-enable Full Disk Access after updates
#
set -euo pipefail

VERSION="${VERSION:-1.2.0}"
MACFUSE_VERSION="5.4.0"
NTFS3G_VERSION="2026.9.28"
MACFUSE_TEAM="Developer ID Installer: Benjamin Fleischer (3T5GSNBU6W)"

PKG_ID="com.ntfsrw.pkg"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT_DIR/src"
BUILD="$ROOT_DIR/build"
DIST="$ROOT_DIR/dist"
VENDOR="$ROOT_DIR/vendor"
SIGNING_DIR="${SIGNING_DIR:-$HOME/.ntfsrw-signing}"
PAYLOAD="$BUILD/payload"
APP="$PAYLOAD/Applications/NTFS RW.app"
SUPPORT="$PAYLOAD/Library/Application Support/NTFSRW"
COMPONENT="ntfsrw-component.pkg"
OUT="$DIST/NTFS-RW-$VERSION.pkg"

step() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

MACFUSE_DMG="$VENDOR/macfuse/macfuse-$MACFUSE_VERSION.dmg"
NTFS3G_TARBALL="$VENDOR/ntfs-3g/ntfs-3g-$NTFS3G_VERSION.tar.gz"
NTFS3G_DIST="$VENDOR/ntfs-3g/dist"
[ -f "$MACFUSE_DMG" ] && [ -f "$NTFS3G_TARBALL" ] || die "third-party files missing. Run: tools/fetch-vendor.sh"
[ -x "$NTFS3G_DIST/ntfs-3g" ] && [ -x "$NTFS3G_DIST/ntfsfix" ] \
    || die "ntfs-3g not built. Run: tools/build-ntfs-3g.sh \"$NTFS3G_TARBALL\" \"$NTFS3G_DIST\""

# ------------------------------------------------------------- signing ----
SIGN_MODE="ad-hoc"
if [ -n "${SIGN_APP:-}" ]; then
    SIGN_MODE="developer-id"
elif [ -f "$SIGNING_DIR/signing.keychain-db" ]; then
    SIGN_MODE="self-signed"
    KC="$SIGNING_DIR/signing.keychain-db"
    security unlock-keychain -p "$(cat "$SIGNING_DIR/password")" "$KC"
    SIGN_SHA1="$(/usr/bin/openssl x509 -in "$SIGNING_DIR/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
fi

sign() { # path [identifier]
    local id=()
    [ -n "${2:-}" ] && id=(--identifier "$2")
    case "$SIGN_MODE" in
        developer-id) codesign --force --options runtime --timestamp ${id[@]+"${id[@]}"} --sign "$SIGN_APP" "$1" ;;
        self-signed)  codesign --force ${id[@]+"${id[@]}"} --keychain "$KC" --sign "$SIGN_SHA1" "$1" ;;
        *)            codesign --force ${id[@]+"${id[@]}"} --sign - "$1" ;;
    esac
    codesign --verify --strict "$1"
}

rm -rf "$BUILD"
mkdir -p "$PAYLOAD" "$DIST"

# ----------------------------------------------------- ntfsctl + daemon ----
step "Staging ntfsctl, daemon and config"
install -d -m 755 "$PAYLOAD/usr/local/bin" "$PAYLOAD/Library/LaunchDaemons" \
    "$SUPPORT" "$SUPPORT/bin" "$SUPPORT/licenses" "$PAYLOAD/private/etc/newsyslog.d"
install -d -m 700 "$SUPPORT/queue"
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
install -m 644 "$CFG_TMP/ntfsrw.conf" "$SUPPORT/ntfsrw.conf.default"

# ------------------------------------------------------------- ntfs-3g ----
step "Staging ntfs-3g $NTFS3G_VERSION (GPL-2.0, source included)"
for tool in ntfs-3g ntfsfix; do
    install -m 755 "$NTFS3G_DIST/$tool" "$SUPPORT/bin/$tool"
    sign "$SUPPORT/bin/$tool" "com.ntfsrw.$tool"
done
otool -L "$SUPPORT/bin/ntfs-3g" | grep -E '^[[:space:]]' | grep -vE '^[[:space:]]+(/usr/lib/|/System/|/usr/local/lib/libfuse\.2\.dylib)' \
    && die "ntfs-3g links against a library that won't exist on users' Macs" || true
install -m 644 "$NTFS3G_TARBALL" "$SUPPORT/licenses/"
tar -xzOf "$NTFS3G_TARBALL" "ntfs-3g-$NTFS3G_VERSION/COPYING" > "$SUPPORT/licenses/ntfs-3g-COPYING.txt"
[ -s "$SUPPORT/licenses/ntfs-3g-COPYING.txt" ] || die "could not extract ntfs-3g COPYING"

# ------------------------------------------------------------- macFUSE ----
step "Extracting official macFUSE $MACFUSE_VERSION core component"
MNT="$BUILD/macfuse-dmg"; mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$MACFUSE_DMG"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
pkgutil --check-signature "$MNT/Install macFUSE.pkg" | grep -qF "$MACFUSE_TEAM" \
    || die "macFUSE installer is not signed by its developer"
spctl -a -t install "$MNT/Install macFUSE.pkg" 2>/dev/null || die "macFUSE installer is not notarized"
pkgutil --expand "$MNT/Install macFUSE.pkg" "$BUILD/macfuse-expanded"
grep -q "version=\"$MACFUSE_VERSION\"" "$BUILD/macfuse-expanded/Core.pkg/PackageInfo" || die "unexpected macFUSE version"
pkgutil --flatten "$BUILD/macfuse-expanded/Core.pkg" "$BUILD/macfuse-core.pkg"
install -m 644 "$MNT/License.rtf" "$SUPPORT/licenses/macFUSE-License.rtf"
hdiutil detach -quiet "$MNT"; trap - EXIT

# Third-party notice: shown on the installer's License page and installed with the app.
sed -e "s/@VERSION@/$VERSION/g" -e "s/@MACFUSE_VERSION@/$MACFUSE_VERSION/g" -e "s/@NTFS3G_VERSION@/$NTFS3G_VERSION/g" \
    "$ROOT_DIR/pkg/NOTICE.txt" > "$SUPPORT/licenses/NOTICE.txt"
RES="$BUILD/resources"; cp -R "$ROOT_DIR/pkg/resources" "$RES"
{
    cat "$SUPPORT/licenses/NOTICE.txt"
    printf '\n\n======================== macFUSE license ========================\n\n'
    textutil -convert txt -stdout "$SUPPORT/licenses/macFUSE-License.rtf"
} > "$RES/License.txt"

# ----------------------------------------------------------------- app ----
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

step "Code signing app ($SIGN_MODE)"
sign "$APP"
[ "$SIGN_MODE" = ad-hoc ] && echo "   WARNING: ad-hoc signature. Run tools/make-signing-identity.sh so Full Disk Access survives updates."
codesign -d -r- "$APP" 2>&1 | tail -1 | sed 's/^/   /'

# ------------------------------------------------------------- package ----
step "Building component package"
# Strip removable extended attributes (quarantine, Finder info). The kernel-protected
# com.apple.provenance attribute stays and is archived as ._* entries, which
# Installer merges back into xattrs — no ._ files are created on disk.
xattr -cr "$PAYLOAD" 2>/dev/null || true
pkgbuild --analyze --root "$PAYLOAD" "$BUILD/component.plist" >/dev/null
# Always install the app to /Applications, never "relocate" to another copy.
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$BUILD/component.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$BUILD/component.plist"
pkgbuild --quiet --root "$PAYLOAD" \
    --component-plist "$BUILD/component.plist" \
    --scripts "$ROOT_DIR/pkg/scripts" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location / \
    "$BUILD/$COMPONENT"

step "Building product archive (NTFS RW + macFUSE)"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@PKG_ID@/$PKG_ID/g" -e "s/@COMPONENT@/$COMPONENT/g" \
    -e "s/@MACFUSE_VERSION@/$MACFUSE_VERSION/g" \
    "$ROOT_DIR/pkg/distribution.xml" > "$BUILD/distribution.xml"
rm -f "$OUT"
productbuild --quiet --distribution "$BUILD/distribution.xml" \
    --resources "$RES" \
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
cp "$NTFS3G_TARBALL" "$DIST/"   # GPL: publish the source next to the release

step "Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "   Share: $DIST/NTFS-RW-$VERSION.zip"
echo "   Attach to the release too: $DIST/$(basename "$NTFS3G_TARBALL") (ntfs-3g source, GPL)"
[ -n "${SIGN_PKG:-}" ] || echo "   Installer itself is unsigned: users click 'Open Anyway' once (see How to Install.txt)."
