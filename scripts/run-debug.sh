#!/bin/bash
# Build and launch AiHand from ~/Applications with a pinned Apple Development
# signature so Accessibility / Screen Recording grants survive rebuilds.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

CONFIG="${1:-debug}"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release
    BINARY=".build/release/$APP_NAME"
else
    swift build
    BINARY=".build/debug/$APP_NAME"
fi

quit_running_app

# Stable path for TCC. Mirror to dist/ after signing.
APP="$(debug_install_app)"
DIST="dist/$APP_NAME.app"
mkdir -p "$HOME/Applications" dist

make_bundle "$BINARY" "$APP" "0"

IDENTITY="$(debug_codesign_identity)"
if [[ "$IDENTITY" == "-" ]]; then
    echo "error: no Apple Development identity found."
    echo "  Create one in Xcode (Settings → Accounts → Manage Certificates), then re-run."
    exit 1
fi

# Debug builds skip hardened runtime — friendlier for local TCC during iteration.
sign_app "$APP" "$IDENTITY" "" "none"

rm -rf "$DIST"
ditto "$APP" "$DIST"

TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
echo "Installed $APP"
echo "Signed with: $IDENTITY (Team $TEAM)"
echo "If Accessibility still prompts: System Settings → Privacy & Security → Accessibility"
echo "  • Remove any old AiHand rows"
echo "  • Enable the AiHand entry (from Applications), then re-run"

open "$APP"
echo "Launched $APP"
