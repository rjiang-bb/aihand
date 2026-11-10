#!/bin/bash
# Run the composer keystroke harness (Sources/AiHand/ComposerProbe.swift) against a
# debug build. Needs a logged-in GUI session: it opens a real key window.
#
#   ./scripts/composer-probe.sh              # all sections
#   ./scripts/composer-probe.sh quotes lists # just these
#
# Exits non-zero if any check fails. Renders land in /tmp/probe-*.png.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

swift build
BIN="$(swift build --show-bin-path)/$APP_NAME"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"

DYLD_FRAMEWORK_PATH="$SPARKLE_FW" timeout 180 "$BIN" --composer-probe "$@"
