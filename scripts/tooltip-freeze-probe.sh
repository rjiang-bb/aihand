#!/bin/bash
# Tooltip freeze harness (Sources/AiHand/TooltipFreezeProbe.swift): hover tip + drawing mode.
# Needs Accessibility. Moves the real cursor briefly — hands off.
#
#   ./scripts/tooltip-freeze-probe.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

swift build
BIN="$(swift build --show-bin-path)/$APP_NAME"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"

DYLD_FRAMEWORK_PATH="$SPARKLE_FW" timeout 90 "$BIN" --tooltip-freeze-probe "$@"
