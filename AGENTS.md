# Agent notes

## Restart after every turn

After finishing each agent turn that changed the app (or when in doubt), **automatically `/restart`** — rebuild and relaunch via the `restart` skill (`./scripts/run-debug.sh` from the repo root, unrestricted shell). Do not wait for the user to ask.

- Run it at the end of the turn, after tests/probes for that change have passed (or failed and you’ve fixed them).
- Skip only for pure read-only answers with no file edits, or when the user explicitly says not to relaunch.
- Confirm briefly that AiHand relaunched; do not dump the full build log unless it failed.

## Sessions panel placement

When the chat pane closes, the sessions list must slide so its **right edge lines up with where the chat window’s right edge was**.

- Capture the expanded panel frame before collapsing.
- Lay out list-only with origin `x = expanded.maxX - listWidth` (and matching top via `expanded.maxY - listHeight`).
- Persist that list-only origin afterward.
- Do **not** restore a pre-expand saved origin on close — that leaves the list pinned left and looks like a regression.

Opening chat still grows to the **right** with the list’s leading edge fixed.

## Sessions list height

The sessions **list card hugs its content** — only as tall as the workspace picker + visible session rows (+ pagination footer when needed).

- Do **not** stretch the list column or list card to match the open chat’s height. That leaves a large empty gap under the last session.
- Keep the list top-aligned beside chat; empty space below the list (inside the panel) is fine.
- Measured height lives in `SessionsListMetrics` / `listContentHeight`; the column frame uses that fixed height even when chat is open.

## ⌘-hold shortcut hints

Holding **⌘** shows per-row `⌘1`…`⌘9` labels and a hints footer (`⌘1–9` / `⌘↑↓` / `⌘W`).

- Per-row numbers sit on the **right** of each session card as plain text (no badge fill/outline), vertically centered, covering the timestamp + preview while held. Status icons stay on the left.
- Grow the footer hints **out of the bottom** of the list card. Keep the session rows’ screen position fixed (panel top edge stays put; height extends downward).
- Do **not** overlay the footer on top of the last rows, and do **not** reflow/jump the list upward when hints appear.
- List-only: include the hints footer in `SessionsListMetrics` and relayout with the top edge anchored. Paginated lists reuse the existing footer slot.

## ⌘/ model cycling

**⌘/** cycles favorite models (wraps) in the open chat and in the annotate comment box while drawing.

- Own the shortcut in `SessionsSidePanel`’s key monitor when the panel is key, in `AnnotatePromptPanel` while commenting, and keep the app menu item “Cycle Agent Model” (`AppDelegate`) as the fallback — menu key equivalents are more reliable than local monitors with ⌘ held.
- Capture screen ↔ window while drawing is **⌘B** (not ⌘/) so model cycling stays free in the comment box.
- While drawing (annotate box closed), **⌘D** toggles drawing ↔ video mode (`OverlayController.toggleDrawVideoMode`). Sessions-panel ⌘D still starts Draw when the overlay is inactive.
- Do **not** also consume ⌘/ in `SessionChatView` (double-cycle skips favorites).
- Do **not** call `closeChat()` from `windowDidResignKey`. Menu key equivalents and the favorite picker resign key briefly; collapsing clears `selectedID` and makes ⌘/ a no-op. Use Esc / the chat close control to dismiss chat.

## Agent favorites vs sessions

The composer model picker always mirrors **Settings → Agent** for that session’s machine (local / SSH): same CLI favorites list and Current selection.

- Do **not** freeze the picker to the CLI/favorite captured when the session was created.
- `AgentSession.syncModelFromSettings()` / `applyFavorite` keep the session aligned; switching Agent CLI clears `chatId` (can’t resume across binaries).
- New sessions take Settings’ Current favorite — they do **not** inherit the previous chat’s model.

## ⌘, settings

**⌘,** opens AiHand Settings whenever the app has focus (sessions panel, annotate prompt, etc.).

- Put “Settings…” with key equivalent `,` on the **main** app menu (`editingMenu` in `AppDelegate`), not only the status-item menu — status-item key equivalents do not fire unless that menu is open.
- Settings window level must stay **above** the sessions/chat panel (`floating + 2`) and chat image previews (`floating + 3`) — use `SettingsWindow.windowLevel` (`floating + 4`). Do not leave Settings at `.normal` or chat will cover it.

## ⌘W focus

**⌘W** always follows the key window (`CommandWRouter`):

1. Chat image preview → close preview (not archive)
2. Settings → close Settings (not archive)
3. Sessions panel → archive the selected session
4. Anything else → `performClose` on the key window

Do **not** let the Archive Session menu key equivalent archive while a preview or Settings is key.

## Esc while editing a queued follow-up

**Esc** in the open chat cancels queue-item edit mode before it closes the chat (`SessionsPanelEscape` / composer key bridge). The composer “Editing” chip matches Cursor’s secondary slate style; its ✕ lightens on hover.

## Open session survives relaunch

The last open chat per workspace is written to `Preferences.openChatByWorkspace` on every select/close (not only on clean quit). On launch, `SessionsSidePanel` restores `selectedID` when that session still exists so force-quit doesn’t leave the list with nothing selected.

## UI icons

All UI chrome uses **monochrome outline** icons — same family as the sessions header (`gearshape`, `xmark`, chevrons).

- Prefer SF Symbols **without** `.fill` (e.g. `plus.circle`, `arrow.up.circle`, `pencil`, `keyboard`). Color via `foregroundStyle` / `currentColor`, not multi-color emoji.
- Transcript / WKWebView rows: inline SVG strokes with `stroke="currentColor"` (see `outlineGlyph` in `ChatTranscriptView`) — never ✏️📄💭 or other emoji glyphs.
- Do **not** introduce new filled circle badges (`*.circle.fill`) or hierarchical multi-tone plates unless matching an existing SoftChrome control that already needs an accent fill for state (and even then prefer outline + `foregroundStyle`).
- Keep weight/size consistent with neighbors (composer actions ~22–26pt, list/header ~12–14pt, transcript glyphs ~12px).

## Hover tooltips

Use `hoverTooltip(_:)` (floating tip window in `HoverTooltip.swift`) for all control tips — including sessions header, composer actions, queue chips, and Settings. Do **not** use SwiftUI `.help` on floating / nonactivating panels; it often never appears.

- **Icon-only buttons** must name the action: `HoverTooltipLabel.icon("Settings", shortcut: "⌘,")` → `Settings (⌘,)`. Include a shortcut when one exists.
- **Labeled controls** (e.g. header **New**) may show the shortcut alone (`⌘N`).

## Queue row drag reorder

Queued follow-up rows: the **handle + label + empty space** (not Steer / Edit / Remove) show the open-hand cursor (`openHandCursor`) and own `.onDrag`. Action buttons keep the pointing hand. Use an empty `onDrag` preview so there is no floating ghost label — the live row moves in place via `dropEntered`.

## Composer attachment previews

Media thumbs in the composer strip use a magnifying-glass cursor on hover (`previewCursor` — not `.pointerPlain`, which steals the hand); click opens `ChatImageActions` preview (videos open in the default app). The remove (✕) control must not also trigger preview.

## Composer file drop zone

In the sessions chat card, SoftChrome + “Drop files” cover the **full composer band** flush with the card edges: square top (under the divider), rounded bottom matching the card (`bottomCornerRadius` 22 when `compact`).

- A **window-wide** drag monitor lights “Drop files” as soon as a file drag enters the window — do not wait until the pointer is over the composer.
- Only a drop **over the SoftChrome band** attaches; transcript / session-list drops are ignored.
- Chrome shape is `ComposerDropChromeShape` (0 top radii, rounded bottom).

## Focus newly shown text fields

When an action **reveals** a text field (inline path box, composer, rename field, etc.), put the caret in it immediately — do not leave focus on the button/menu that opened it.

- Same rule for any new UI that is primarily for typing.
- After an **NSMenu** (or sheet) opens the field, SwiftUI `FocusState` is unreliable — use AppKit `window.makeFirstResponder(field)` (see `AutofocusPlainField` / annotate prompt), deferred until the menu tears down.
- If the menu item was chosen with **↩**, swallow that leftover Return (and ignore the field’s submit action briefly) so focusing the field does not immediately confirm.
- Clicking empty SoftChrome in `AgentComposerView` (not a button, menu, chip, or the text view itself) must focus the prompt via `ComposerFieldEditor.focus()`.

## Keep tests current

Any **new or changed behavior** must land with matching coverage in the same change. Do not ship a fix or feature and leave tests for “later.”

- Prefer a headless `swift test` case when the logic can be exercised without a window (handlers, import/parse, persistence, CLI argv, pasteboard import, paste routing).
- Prefer / extend a GUI harness (`scripts/*-probe.sh`) when the bug is layout, focus, real key events, or drawing.
- Update an existing test when behavior changes; add a new case when covering a new path or regression.
- Before finishing: run the relevant `swift test --filter …` and/or probe script(s) and confirm they pass.

## Composer harness

Composer editing (lists, quotes, fences, inline code, height) has a real-keystroke regression harness in `Sources/AiHand/ComposerProbe.swift` (DEBUG-only).

- Run `./scripts/composer-probe.sh` (or pass sections: `quotes lists ordered fences inline height`). Exits non-zero on failure; renders land in `/tmp/probe-*.png`.
- Run it after any change to `ComposerMarkdownStyler` / `ComposerPromptEditor`, and add checks for new behaviour or reported bugs.

## Skill catalog roots

`/` autocomplete (`SkillCatalog`) scans personal, workspace, and plugin skill folders **for the selected CLI only** (`cli` / session `cliKind`). Keep local (`skillContainerRoots` / `pluginSkillTrees`) and remote SSH roots in sync, and gate each CLI’s dirs behind its `AgentCLIKind` case.

Shared for every CLI: `~/.agents/skills` and workspace `.agents/skills`.

CLI-specific today:

- **Cursor** — `~/.cursor/skills`, `~/.cursor/skills-cursor`, workspace `.cursor/skills`, `~/.cursor/plugins`
- **Claude** — `~/.claude/skills`, workspace `.claude/skills`, `~/.claude/plugins`
- **Codex** — `~/.codex/skills`, `~/.codex/skills/.system`, workspace `.codex/skills`, `~/.codex/plugins` + `~/.codex/.tmp/plugins`

Plugin trees discover containers named `skills`, `skills-*`, or `*-skills`.

When adding another agent CLI (or a CLI changes where it stores skills/plugins):

- Add a new `AgentCLIKind` branch in `skillContainerRoots` / `pluginSkillTrees` (and the matching remote `roots` / `pluginTrees` lists). Do **not** scan that CLI’s dirs unless it is the selected CLI.
- Wire `cliKind` through the composer / autocomplete callers if a new surface can change CLI.
- Extend `SkillCatalogTests` for the new paths + “other CLI does not see them”; run `swift test --filter SkillCatalogTests`.

Earlier roots win on name collisions — personal / shared before that CLI’s plugin caches.

## Test suites

- `swift test` — headless unit/logic tests (`Tests/AiHandTests`): CLI args, transcript markdown, composer handlers, chips/media paste import + paste routing, session persistence, autocomplete / skill roots (Cursor + `~/.codex` / `~/.claude` + installed plugins), and the agent send path (`FakeAgentTests`: a fake CLI via `AgentPathLookup.overrides` records argv/cwd and emits stream-json for cursor/claude/codex). Prefs/Application Support / skill-home are sandboxed (`SandboxedTestCase`).
- `./scripts/composer-probe.sh` — composer real-keystroke harness (see above).
- `./scripts/panel-probe.sh [placement height hints keys paging dismiss]` — sessions-panel harness (DEBUG-only, `SessionsPanelProbe.swift`): list/chat edge placement, list height, ⌘-hold hints, ⌘1–9 / ⌘↑↓ / ⌘W / ⌘/ / Esc, plus the annotate comment box (⌘/ cycling, Return submits, Esc cancels). Needs a GUI session; run it after touching `SessionsSidePanel`.
- `./scripts/overlay-probe.sh` — overlay/drawing end-to-end (`OverlayProbe.swift`): real HID mouse events → freehand/rectangle/arrow/text, undo/clear, toolbar click, click-swallowing, Esc. Needs Accessibility and **moves the real cursor** (hands off); prints SKIPPED if the event tap can't install.
- `./scripts/tooltip-freeze-probe.sh` — drawing keeps another app's hover tooltip (`TooltipFreezeProbe.swift`): spawns a `--tooltip-host` child process with a native `toolTip` button, hovers until the tip window shows, enters drawing, sends HID-style relative moves, and asserts the host saw no moves/exits, its tip is still up, the cursor stayed parked, and exit warps the cursor to the hand. Needs Accessibility; moves the real cursor briefly. Run after touching `DrawingPointerPark` / `InputTap`.
