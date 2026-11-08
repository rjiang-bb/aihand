#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Penguin Labs, LLC (7CPM8AVL66)}"
PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
SKIP_NOTARIZE=false
SKIP_PUBLISH=false
NO_BUMP=false
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --skip-publish) SKIP_PUBLISH=true ;;
        --no-bump) NO_BUMP=true ;;
        -h|--help)
            cat <<'USAGE'
Usage: ./scripts/release.sh [--skip-notarize] [--skip-publish] [--no-bump]

  Bumps VERSION (patch), builds a universal signed DMG, and uploads it to a
  GitHub release (rjiang-bb/aihand). Dist artifacts are local-only — not git.

  --skip-notarize  Skip Apple notarization (still codesigns).
  --skip-publish   Build only; do not create/upload a GitHub release.
  --no-bump        Keep the current VERSION file as-is.

  Env:
    AIHAND_VERSION   If set, use this version and skip bumping (CI/tags).
    SKIP_PUBLISH=1   Same as --skip-publish.
    RELEASE_NOTES    Release body / Sparkle notes (optional; default: changelog since last release).
USAGE
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done
[[ "${SKIP_PUBLISH:-}" == "1" ]] && SKIP_PUBLISH=true

INSTALL_NOTES="Download the DMG, open it and drag AiHand to Applications. Runs on Apple silicon and Intel, macOS 13 or later."

bump_patch_version() {
    local major minor patch
    IFS=. read -r major minor patch < "$ROOT/VERSION"
    if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]]; then
        echo "error: VERSION must be major.minor.patch (got: $(tr -d '[:space:]' < "$ROOT/VERSION"))" >&2
        exit 1
    fi
    patch=$((patch + 1))
    printf '%s.%s.%s\n' "$major" "$minor" "$patch" > "$ROOT/VERSION"
    VERSION="${major}.${minor}.${patch}"
}

# Previous published release tag (local tags, then GitHub), excluding the current version.
previous_release_tag() {
    local tag="v$VERSION"
    local prev
    prev="$(git tag -l 'v*' --sort=-version:refname | grep -vxF "$tag" | head -1 || true)"
    if [[ -z "$prev" ]] && command -v gh >/dev/null 2>&1; then
        prev="$(gh release list --repo "$REPO" --limit 20 --json tagName \
            --jq "[.[].tagName | select(. != \"$tag\")][0] // empty" 2>/dev/null || true)"
    fi
    printf '%s' "$prev"
}

# Bulleted summary of commits/PRs since the previous release (for GitHub + Sparkle).
generate_release_notes() {
    local tag="v$VERSION"
    local prev
    prev="$(previous_release_tag)"

    if [[ -n "$prev" ]] && ! git rev-parse "$prev" >/dev/null 2>&1; then
        git fetch --force origin "refs/tags/$prev:refs/tags/$prev" >/dev/null 2>&1 || true
    fi

    local range="HEAD"
    [[ -n "$prev" ]] && git rev-parse "$prev" >/dev/null 2>&1 && range="${prev}..HEAD"
    local bullets
    bullets="$(git log "$range" --pretty=format:'- %s' --no-merges 2>/dev/null || true)"
    if [[ -n "$bullets" ]]; then
        printf '%s\n' "$bullets"
        return 0
    fi

    if command -v gh >/dev/null 2>&1; then
        local args=(api "repos/$REPO/releases/generate-notes" -f "tag_name=$tag")
        [[ -n "$prev" ]] && args+=(-f "previous_tag_name=$prev")
        local body
        if body="$(gh "${args[@]}" --jq .body 2>/dev/null)" && [[ -n "$body" ]]; then
            printf '%s\n' "$body"
            return 0
        fi
    fi
    return 1
}

if [[ -n "${AIHAND_VERSION:-}" ]]; then
    VERSION="$AIHAND_VERSION"
    printf '%s\n' "$VERSION" > "$ROOT/VERSION"
    echo "==> Using AIHAND_VERSION=$VERSION"
elif [[ "$NO_BUMP" == true ]]; then
    VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
    echo "==> Keeping VERSION=$VERSION"
else
    bump_patch_version
    echo "==> Bumped VERSION → $VERSION"
fi

OUT="dist/release"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
if [[ -n "${RELEASE_NOTES:-}" ]]; then
    NOTES="$RELEASE_NOTES"
else
    NOTES="$(generate_release_notes || true)"
    if [[ -z "$NOTES" ]]; then
        NOTES="$INSTALL_NOTES"
    else
        echo "==> Release notes since previous tag"
    fi
fi

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

publish_github_release() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI required to publish (brew install gh && gh auth login)" >&2
        exit 1
    fi
    local tag="v$VERSION"
    local args=(
        release create "$tag"
        "$DMG" "$DMG.sha256" "$OUT/$APP_NAME.dmg" "$OUT/appcast.xml"
        --repo "$REPO"
        --title "$VERSION"
        --notes "$NOTES"
    )
    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
        echo "==> Release $tag already exists; uploading assets"
        gh release upload "$tag" \
            "$DMG" "$DMG.sha256" "$OUT/$APP_NAME.dmg" "$OUT/appcast.xml" \
            --repo "$REPO" --clobber
        gh release edit "$tag" --repo "$REPO" --title "$VERSION" --notes "$NOTES"
    else
        echo "==> Creating GitHub release $tag"
        gh "${args[@]}"
    fi
    echo "Release: https://github.com/$REPO/releases/tag/$tag"
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
elif ENCLOSURE="$("$TOOLS/sign_update" --account aihand "$DMG" 2>/dev/null)"; then
    :
elif ENCLOSURE="$("$TOOLS/sign_update" "$DMG" 2>/dev/null)"; then
    :
else
    echo "warning: Sparkle sign_update unavailable; writing appcast without signature fields"
    ENCLOSURE="length=\"$(stat -f%z "$DMG")\""
fi
NOTES_HTML="$(printf '%s' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | sed -e 's/$/<br>/')"
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

if [[ "$SKIP_PUBLISH" == false ]]; then
    publish_github_release
else
    echo "==> Skipping GitHub publish"
fi

echo
echo "Done: $DMG  (VERSION $VERSION)"
cat "$DMG.sha256"
echo "Commit and push the VERSION bump when you are ready."
