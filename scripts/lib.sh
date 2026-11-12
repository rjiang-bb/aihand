#!/bin/bash

APP_NAME="AiHand"
DISPLAY_NAME="AiHand"
BUNDLE_ID="net.penguinlabs.aihand"
REPO="rjiang-bb/aihand"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="W7Uw9EdEKx6sVyntlf5UrtE8ZRbZwPlc6Aiya3loFW4="
SPARKLE_VERSION="2.10.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${AIHAND_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"

quit_running_app() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "Quitting the running $APP_NAME first..."
        osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
        sleep 1
        pkill -x "$APP_NAME" || true
        sleep 0.5
    fi
}

make_bundle() {
    local binary="$1" app="$2" build="$3" updates="${4:-}"
    local update_keys=""
    if [[ "$updates" == "--with-updates" ]]; then
        update_keys="    <key>SUFeedURL</key>
    <string>$FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>"
    fi

    # Stage first, then swap Contents in place so the outer .app path stays stable for TCC.
    local stage
    stage="$(mktemp -d)/$APP_NAME.app"
    mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$stage/Contents/Frameworks"
    cp "$binary" "$stage/Contents/MacOS/$APP_NAME"
    cp "$ROOT"/assets/hand_*.png "$stage/Contents/Resources/"
    cp "$ROOT"/assets/sounds/tap_*.wav "$ROOT/assets/AppIcon.icns" "$ROOT/assets/Assets.car" "$stage/Contents/Resources/"
    cp "$ROOT"/assets/menubar_*.png "$stage/Contents/Resources/"
    # Vendored CommonMark/GFM parser for chat transcript rendering.
    cp "$ROOT/assets/marked.min.js" "$stage/Contents/Resources/"
    # Monaco (VS Code editor core) for in-chat file diffs; served via aihand-asset://.
    ditto "$ROOT/assets/monaco" "$stage/Contents/Resources/monaco"
    ditto "$ROOT/assets/codeview" "$stage/Contents/Resources/codeview"

    local fw
    fw="$(find "$ROOT/.build/artifacts" -path "*macos-arm64_x86_64/Sparkle.framework" -maxdepth 6 | head -1)"
    ditto "$fw" "$stage/Contents/Frameworks/Sparkle.framework"

    cat > "$stage/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$build</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>© $(date +%Y) Penguin Labs. MIT License.</string>
$update_keys
</dict>
</plist>
PLIST

    mkdir -p "$(dirname "$app")"
    if [[ -d "$app/Contents" ]]; then
        rm -rf "$app/Contents"
        mv "$stage/Contents" "$app/Contents"
        rm -rf "$(dirname "$stage")"
    else
        rm -rf "$app"
        mv "$stage" "$app"
        rmdir "$(dirname "$stage")" 2>/dev/null || rm -rf "$(dirname "$stage")"
    fi
}

sign_app() {
    local app="$1" identity="$2" ts="${3:-}" hardened="${4:-runtime}"
    local fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    local sign=(codesign --force --sign "$identity")
    if [[ "$hardened" == "runtime" ]]; then
        sign+=(--options runtime)
    fi
    [[ -n "$ts" ]] && sign+=(--timestamp)
    "${sign[@]}" "$fw/XPCServices/Installer.xpc"
    "${sign[@]}" --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
    "${sign[@]}" "$fw/Autoupdate"
    "${sign[@]}" "$fw/Updater.app"
    "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
    "${sign[@]}" "$app"
    codesign --verify --deep --strict "$app"
}

# Prefer a stable Apple Development identity so TCC (Accessibility / Screen Recording)
# survives rebuilds. Ad-hoc ("-") gets a new CDHash every build and macOS re-prompts.
# Pin the chosen identity in .debug-codesign-identity so we never flip between certs.
debug_codesign_identity() {
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        echo "$CODESIGN_IDENTITY"
        return
    fi
    local pin="$ROOT/.debug-codesign-identity"
    if [[ -f "$pin" ]]; then
        local pinned
        # Trim leading/trailing whitespace only — identity names contain spaces.
        pinned="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$pin" | head -1)"
        if [[ -n "$pinned" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -F -q "$pinned"; then
            echo "$pinned"
            return
        fi
    fi
    local id
    id="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -1)"
    if [[ -n "$id" ]]; then
        printf '%s\n' "$id" > "$pin"
        echo "$id"
        return
    fi
    echo "-"
}

debug_install_app() {
    echo "$HOME/Applications/$APP_NAME.app"
}

sparkle_tools() {
    local dir="$ROOT/.build/sparkle-tools-$SPARKLE_VERSION"
    if [[ ! -x "$dir/bin/sign_update" ]]; then
        mkdir -p "$dir"
        curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
            | tar -xJ -C "$dir"
    fi
    echo "$dir/bin"
}

# Build a styled drag-to-install DMG: background art with an arrow from the app to Applications,
# fixed icon positions, hidden toolbar. Self-contained (hdiutil + Finder AppleScript) — the
# `create-dmg` formula varies per machine and was silently falling back to a plain image.
# Layout points must match scripts/make-dmg-background.swift (app 150,170 / Applications 410,170).
# Usage: build_dmg <App.app> <out.dmg>
build_dmg() {
    local app="$1" dmg="$2"
    local bg="$ROOT/assets/dmg-background.png"
    local stage rw mnt
    stage="$(mktemp -d)"
    rw="$(mktemp -u "${TMPDIR:-/tmp}/aihand-rw.XXXXXX").dmg"
    mnt="/Volumes/$APP_NAME"

    cp -R "$app" "$stage/"
    ln -sf /Applications "$stage/Applications"
    if [[ -f "$bg" ]]; then
        mkdir "$stage/.background"
        cp "$bg" "$stage/.background/background.png"
    fi

    # A stale mount with the same name would make Finder address "AiHand 1".
    [[ -d "$mnt" ]] && hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
    rm -f "$dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$rw" >/dev/null
    hdiutil attach "$rw" -readwrite -noverify -noautoopen -mountpoint "$mnt" >/dev/null

    # Volume icon.
    if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
        cp "$ROOT/assets/AppIcon.icns" "$mnt/.VolumeIcon.icns"
        SetFile -c icnC "$mnt/.VolumeIcon.icns" 2>/dev/null || true
        SetFile -a C "$mnt" 2>/dev/null || true
    fi

    # Window: 560x360 content (+28pt title bar), icons at the arrow's ends.
    if ! osascript >/dev/null 2>&1 <<OSA
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 508}
        set vo to the icon view options of container window
        set arrangement of vo to not arranged
        set icon size of vo to 112
        set text size of vo to 13
        if exists file ".background:background.png" then
            set background picture of vo to file ".background:background.png"
        end if
        set position of item "$APP_NAME.app" of container window to {150, 170}
        set position of item "Applications" of container window to {410, 170}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
    then
        echo "warning: Finder styling failed (no GUI session / Automation permission?) — DMG will use default layout" >&2
    fi

    sync
    sleep 1
    hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach "$mnt" -force >/dev/null
    hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -ov -o "$dmg" >/dev/null
    rm -rf "$stage" "$rw"
}
