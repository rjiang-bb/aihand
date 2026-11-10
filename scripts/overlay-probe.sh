#!/bin/bash
# Overlay / drawing end-to-end harness (Sources/AiHand/OverlayProbe.swift): activates the real
# overlay and drives it with real HID mouse events. Needs Accessibility permission for the
# built binary and a GUI session. It MOVES THE REAL CURSOR for a few seconds — hands off.
# If the event tap can't install it prints SKIPPED and exits 0.
#
#   ./scripts/overlay-probe.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

swift build
BIN="$(swift build --show-bin-path)/$APP_NAME"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"

DYLD_FRAMEWORK_PATH="$SPARKLE_FW" timeout 120 "$BIN" --overlay-probe "$@"
