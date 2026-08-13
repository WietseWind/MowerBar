#!/usr/bin/env bash
# Builds MowerBar.app — a menu bar (LSUIElement) bundle.
#
#   ./build.sh                                   universal, ad-hoc signed, local use
#   ./build.sh --native                          host architecture only, faster
#   ./build.sh --sign "Developer ID Application: Acme (TEAMID)"
#   ./build.sh --sign "…" --notarize notarytool --dest ~/Desktop
#
# Distribution needs all three: a Developer ID identity, the hardened runtime
# (added automatically when --sign is given), and notarization. Without
# notarization macOS shows "Apple could not verify…" on the recipient's Mac.
set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION=release
IDENTITY="-"
NOTARY_PROFILE=""
DEST=""
# Release builds are universal so one download covers Apple Silicon and Intel.
# --native drops to the host architecture only, which is faster to iterate on.
ARCHS=(--arch arm64 --arch x86_64)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)      IDENTITY="$2"; shift 2 ;;
    --notarize)  NOTARY_PROFILE="$2"; shift 2 ;;
    --dest)      DEST="$2"; shift 2 ;;
    --debug)     CONFIGURATION=debug; shift ;;
    --native)    ARCHS=(); shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

APP="build/MowerBar.app"

# macOS ships bash 3.2, where expanding an empty array under `set -u` is an
# "unbound variable" error — so --native needs the ${arr[@]+"${arr[@]}"} form.
echo "==> swift build -c $CONFIGURATION ${ARCHS[*]:-(host architecture)}"
swift build -c "$CONFIGURATION" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIGURATION" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/MowerBar"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MowerBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> architectures"
lipo -info "$APP/Contents/MacOS/MowerBar" | sed 's/^/    /'

echo "==> rendering icons"
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --render-icons "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ "$IDENTITY" == "-" ]]; then
  echo "==> ad-hoc signing (not distributable)"
  codesign --force --sign - --timestamp=none "$APP"
else
  echo "==> signing as: $IDENTITY"
  # --options runtime is what makes the bundle eligible for notarization.
  codesign --force --deep --options runtime --timestamp \
           --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  ZIP="build/MowerBar-notarize.zip"
  echo "==> submitting for notarization (profile: $NOTARY_PROFILE)"
  rm -f "$ZIP"
  # ditto --keepParent preserves the .app wrapper; plain zip loses symlinks.
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> stapling"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
fi

echo "==> gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 || \
  echo "    (rejected — expected unless signed with a Developer ID and notarized)"

if [[ -n "$DEST" ]]; then
  echo "==> delivering to $DEST"
  rm -rf "${DEST%/}/MowerBar.app"
  ditto "$APP" "${DEST%/}/MowerBar.app"
  ZIP="${DEST%/}/MowerBar.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "    ${DEST%/}/MowerBar.app"
  echo "    $ZIP  (send this — zipping preserves the signature)"
fi

echo
echo "Built $APP"
