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

**⌘/** cycles the open chat’s favorite models for that session’s CLI (wraps).

- Own the shortcut in `SessionsSidePanel`’s key monitor when the panel is key, and keep the app menu item “Cycle Agent Model” (`AppDelegate`) as the fallback — menu key equivalents are more reliable than local monitors with ⌘ held.
- Do **not** also consume ⌘/ in `SessionChatView` (double-cycle skips favorites).
- Do **not** call `closeChat()` from `windowDidResignKey`. Menu key equivalents and the favorite picker resign key briefly; collapsing clears `selectedID` and makes ⌘/ a no-op. Use Esc / the chat close control to dismiss chat.

## ⌘, settings

**⌘,** opens AiHand Settings whenever the app has focus (sessions panel, annotate prompt, etc.).

- Put “Settings…” with key equivalent `,` on the **main** app menu (`editingMenu` in `AppDelegate`), not only the status-item menu — status-item key equivalents do not fire unless that menu is open.
