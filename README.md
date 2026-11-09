<p align="center">
  <img src="./.github/logo.png" width="72" alt="AiHand" />
</p>

# AiHand

[![Latest release](https://img.shields.io/github/v/release/rjiang-bb/aihand?display_name=tag&sort=semver&cacheSeconds=3600)](https://github.com/rjiang-bb/aihand/releases/latest)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://github.com/rjiang-bb/aihand)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A tiny hand for demos — and a draw-to-agent loop for Cursor, Claude Code, and Codex.

Forked from [nilbuild/tinyhand](https://github.com/nilbuild/tinyhand).

<p align="center">
  <a href="https://github.com/rjiang-bb/aihand/releases/latest/download/AiHand.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" /></a>
  <a href="https://github.com/rjiang-bb/aihand"><img src="https://img.shields.io/badge/GitHub-000000?style=for-the-badge&logo=github&logoColor=white" alt="GitHub" /></a>
</p>

## What it does

- **Point & tap** — a toy hand follows the cursor; clicks stay visual, not real
- **Draw** — freehand, rectangle, arrow, and text; thickness and ink color; lines can fade
- **Screenshot annotate** — draw on screen or a window, comment, and send to Cursor Agent, Claude Code, or Codex
- **Video annotate** — right-drag a region, record it, then comment or send the clip to an agent (preview plays at the capture spot)
- **AI sessions** — chat, follow-ups, skills (`/`), favorite models, and per-folder working directories

<p align="center"><strong>Draw → ask the agent</strong></p>

<img src="./.github/readme-annotate.jpg" alt="Drawing with the hand pointer and the Ask the agent prompt" />

<p align="center"><strong>AI sessions</strong></p>

<img src="./.github/readme-sessions-v3.jpg" alt="AI sessions list with working folder picker and chat open" />

<img src="./.github/readme-hands.png" alt="A selection of AiHand pointers" />

## Shortcuts

### Global

| | |
|---|---|
| **⌘⇧H** | Pointer on / off |
| **⌘⇧G** | AI sessions panel |
| **⌘,** | Settings |

### Drawing mode

| | |
|---|---|
| Click / drag | Tap / draw |
| **F** / **R** / **A** / **T** | Freehand / rectangle / arrow / text |
| **1–5** | Stroke thickness |
| **⌘Z** | Undo |
| **⌘⇧X** | Clear drawing |
| **⌘⇧S** | Save annotated screenshot |
| **⌘⇧C** | Copy annotated screenshot |
| **⌘B** | Capture screen ↔ window |
| **⌘/** | Cycle agent model (chat / annotate comment) |
| **Enter** | Comment, then send to agent |
| **⌘↩** | Send annotated screenshot to agent |
| **Right-drag** | Enter video mode (select region) |
| **Esc** | Exit pointer |

### Video mode

| | |
|---|---|
| Release right button | Start recording the selected region |
| **Stop** | Finish recording (keep clip) |
| **⌘S** | Save video, preview + comment, then send |
| **⌘⇧S** | Save video (drag preview into other apps) |
| **⌘↩** | Save and send video to agent |
| **Esc** | Cancel selection / discard recording / delete video while commenting |

## Install

macOS 13+, Apple silicon and Intel. Open the DMG, drag to Applications, allow **Accessibility** (and Screen Recording for captures). Updates itself.

## License

MIT. See [LICENSE](LICENSE).
