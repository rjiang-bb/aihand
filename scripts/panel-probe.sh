#!/bin/bash
# Sessions-panel GUI harness (Sources/AiHand/SessionsPanelProbe.swift): real panel, real
# key events, placement / height / ⌘-hint / shortcut checks. Needs a logged-in GUI session.
# Prefs and Application Support are sandboxed to a temp dir.
#
#   ./scripts/panel-probe.sh                # all sections
#   ./scripts/panel-probe.sh hints keys     # placement height hints keys paging dismiss
#
# Exits non-zero on failure. Renders land in /tmp/probe-panel-*.png.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

swift build
BIN="$(swift build --show-bin-path)/$APP_NAME"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"

DYLD_FRAMEWORK_PATH="$SPARKLE_FW" timeout 180 "$BIN" --panel-probe "$@"
