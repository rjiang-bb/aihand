# Agent notes

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

Holding **⌘** shows shortcut badges and a hints footer (`⌘1–9` / `⌘↑↓` / `⌘W`).

- Grow the hints **out of the bottom** of the list card. Keep the session rows’ screen position fixed (panel top edge stays put; height extends downward).
- Do **not** overlay hints on top of the last rows, and do **not** reflow/jump the list upward when hints appear.
- List-only: include the hints footer in `SessionsListMetrics` and relayout with the top edge anchored. Paginated lists reuse the existing footer slot.

## ⌘/ model cycling

**⌘/** cycles favorite models (wraps) in the open chat and in the annotate comment box while drawing.

- Own the shortcut in `SessionsSidePanel`’s key monitor when the panel is key, in `AnnotatePromptPanel` while commenting, and keep the app menu item “Cycle Agent Model” (`AppDelegate`) as the fallback — menu key equivalents are more reliable than local monitors with ⌘ held.
- Capture screen ↔ window while drawing is **⌘B** (not ⌘/) so model cycling stays free in the comment box.
- Do **not** also consume ⌘/ in `SessionChatView` (double-cycle skips favorites).
- Do **not** call `closeChat()` from `windowDidResignKey`. Menu key equivalents and the favorite picker resign key briefly; collapsing clears `selectedID` and makes ⌘/ a no-op. Use Esc / the chat close control to dismiss chat.

## ⌘, settings

**⌘,** opens AiHand Settings whenever the app has focus (sessions panel, annotate prompt, etc.).

- Put “Settings…” with key equivalent `,` on the **main** app menu (`editingMenu` in `AppDelegate`), not only the status-item menu — status-item key equivalents do not fire unless that menu is open.

## Focus newly shown text fields

When an action **reveals** a text field (inline path box, composer, rename field, etc.), put the caret in it immediately — do not leave focus on the button/menu that opened it.

- Same rule for any new UI that is primarily for typing.
- After an **NSMenu** (or sheet) opens the field, SwiftUI `FocusState` is unreliable — use AppKit `window.makeFirstResponder(field)` (see `AutofocusPlainField` / annotate prompt), deferred until the menu tears down.
- If the menu item was chosen with **↩**, swallow that leftover Return (and ignore the field’s submit action briefly) so focusing the field does not immediately confirm.

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
