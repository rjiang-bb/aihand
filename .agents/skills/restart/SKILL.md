---
name: restart
description: >-
  Rebuild and relaunch the AiHand macOS debug app via ./scripts/run-debug.sh.
  Use when the user types /restart, or asks to restart, relaunch, or rebuild
  and run AiHand locally.
---

# Restart AiHand

From the **repo root** (`aihand`), rebuild the debug binary, re-sign into
`~/Applications/AiHand.app`, quit any running instance, and launch it.

## Steps

1. Run (unrestricted shell — codesign / launch need it):

```bash
./scripts/run-debug.sh
```

2. Wait for completion. Success looks like `Launched .../AiHand.app` with exit code 0.

3. Confirm briefly that AiHand relaunched. Do not dump the full build log unless it failed.

## Notes

- Default is **debug**. Only pass `release` if the user asks for a release rebuild: `./scripts/run-debug.sh release`.
- Do not notarize or cut a GitHub release; that is `./scripts/release.sh`.
- If Accessibility / Screen Recording prompts appear after relaunch, point at System Settings → Privacy & Security and the AiHand entry under `~/Applications`.
