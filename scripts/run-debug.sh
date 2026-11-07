#!/bin/bash
# Build, bundle, and launch TinyHand with a stable development signature so
# Accessibility / Screen Recording grants stick across rebuilds.
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

APP="dist/$APP_NAME.app"
make_bundle "$BINARY" "$APP" "0"

IDENTITY="$(debug_codesign_identity)"
sign_app "$APP" "$IDENTITY"
echo "Signed with: $IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
    echo "warning: ad-hoc signature — macOS will re-ask permissions after each rebuild."
    echo "         Set CODESIGN_IDENTITY or install an Apple Development certificate."
fi

open "$APP"
echo "Launched $APP"
