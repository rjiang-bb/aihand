#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Penguin Labs, LLC (7CPM8AVL66)}"
PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
SKIP_NOTARIZE=false
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

OUT="dist/release"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

notarize() {
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" --wait --timeout 30m
    else
        xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m
    fi
    xcrun stapler staple "$2"
    xcrun stapler validate "$2"
}

# SwiftPM ≥6 puts multi-arch products under .build/out; older toolchains used .build/apple.
resolve_release_binary() {
    local candidates=(
        ".build/out/Products/Release/$APP_NAME"
        ".build/apple/Products/Release/$APP_NAME"
        ".build/release/$APP_NAME"
    )
    local path
    for path in "${candidates[@]}"; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    echo "error: release binary not found (looked in ${candidates[*]})" >&2
    return 1
}

echo "==> Building $APP_NAME $VERSION (universal)"
swift build -c release --arch arm64 --arch x86_64
rm -rf "$OUT"
mkdir -p "$OUT"
BINARY="$(resolve_release_binary)"
make_bundle "$BINARY" "$APP" "$BUILD_NUMBER" --with-updates
lipo -info "$APP/Contents/MacOS/$APP_NAME"

echo "==> Signing with $IDENTITY"
sign_app "$APP" "$IDENTITY" --timestamp

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
    notarize "$OUT/$APP_NAME.zip" "$APP"
    rm "$OUT/$APP_NAME.zip"
fi

echo "==> Building the DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"
if ! create-dmg \
    --volname "$APP_NAME" \
    --volicon "assets/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 560 360 \
    --icon-size 112 \
    --icon "$APP_NAME.app" 150 170 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 410 170 \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null 2>&1; then
    echo "create-dmg unavailable; falling back to hdiutil"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> Notarizing the DMG"
    notarize "$DMG" "$DMG"
    echo "==> Gatekeeper check"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> Signing the update and writing appcast.xml"
TOOLS="$(sparkle_tools)"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" --ed-key-file - "$DMG")"
elif ENCLOSURE="$("$TOOLS/sign_update" --account tinyhand "$DMG" 2>/dev/null)"; then
    :
elif ENCLOSURE="$("$TOOLS/sign_update" "$DMG" 2>/dev/null)"; then
    :
else
    echo "warning: Sparkle sign_update unavailable; writing appcast without signature fields"
    ENCLOSURE="length=\"$(stat -f%z "$DMG")\""
fi
NOTES_HTML="$(printf '%s' "${RELEASE_NOTES:-AiHand $VERSION}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | sed -e 's/$/<br>/')"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
                 type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
cp "$DMG" "$OUT/$APP_NAME.dmg"
echo
echo "Done: $DMG"
cat "$DMG.sha256"
