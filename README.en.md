# Codex Top

[简体中文](README.md) · **English**

A native macOS monitor for Codex tasks. Follow selected tasks near the notch, in a floating list, or through a small 44pt desktop orb without repeatedly switching back to Codex.

This is a **Beta preview**. Beta.5 adds faster updates after replies, recovery of missing start times, in-app scale shortcuts, a single pinned floating list, and clearer running indicators. Final validation is in progress. Check the [release page](https://github.com/BuTangTang/Codex-Top/releases/tag/v0.1.0-beta.5) for publication status, checksums, and validation scope.

## Install

Requires **macOS 14+**. The DMG is **universal for Apple Silicon and Intel**. Real tasks require a local Codex installation and task records saved to disk; account usage requires the official Codex CLI to be signed in. No API key needs to be entered in this app.

1. Download the DMG from the [v0.1.0-beta.5 release page](https://github.com/BuTangTang/Codex-Top/releases/tag/v0.1.0-beta.5).
2. Open the DMG and drag `Codex Top.app` to Applications.
3. Launch the app. Left-click its menu bar item to view tasks; right-click for task selection, display modes, and settings.

Preview builds are ad-hoc signed, without Developer ID signing or Apple notarization. If macOS blocks the app, verify the download source and follow [Apple's instructions](https://support.apple.com/en-us/102445). Do not disable system-wide protection.

## Screenshots

These are **actual application windows** from an isolated test copy with synthetic tasks, not design mockups. This keeps private tasks and account information out of the images. Demo mode does not read real account usage; download builds use real data by default. Screenshots show static appearance, not frame rate or complete validation.

**Notch mode: beta.3, built-in notched display, 75% app scale.**

| Light glass | Dark |
|---|---|
| ![beta.3 light notch panel](docs/images/notch-light.jpg) | ![beta.3 dark notch panel](docs/images/notch-dark.jpg) |

**Expanded orb panel: beta.2, 80% app scale.**

| Light glass | Dark |
|---|---|
| ![beta.2 light task panel](docs/images/panel-light.jpg) | ![beta.2 dark task panel](docs/images/panel-dark.jpg) |

**Desktop orb and floating list: beta.2; the orb stays at 44pt and the list uses 80% scale.**

| Orb needing attention | Compact floating list |
|---|---|
| ![beta.2 light attention orb, 44pt](docs/images/orb-light.jpg) | ![beta.2 light floating list](docs/images/floating-light.jpg) |

## Features

Four display modes share one set of monitored tasks:

| Mode | Interaction |
|---|---|
| Notch | Attention status on the left, remaining allowance on the right; hover to expand and leave to collapse. Uses the top edge on displays without a notch. |
| Floating list | A compact, always-on-top list that hides the notch panel. Drag its title or header whitespace, excluding buttons. |
| Orb | Left-click to expand in place. Moving the pointer away keeps it open; click outside, use the collapse button, or press Escape to close. Right-click for the menu. |
| Menu bar only | Status counts on a transparent background. Left-click to show/hide tasks; right-click for the menu. |

- **Task selection:** Search, select multiple tasks, or select all current results. Newly created tasks join automatically when they start; manual exclusions take priority. Child tasks are grouped under their parent, attention comes first, and finished tasks can be collapsed. Creating tasks, answering questions, and granting approvals still happen in Codex.
- **Status cues:** Blue running arcs share a rotation phase; newly shown or resumed arcs join the same rhythm. The orb's center shows the running count. The running label uses the theme's primary text color, while the arc stays blue. Attention adds a subtle tint and `!`: orange in the light theme, amber in dark, red for failures, and green for completion. Attention gently pulses; Reduce Motion keeps static cues.
- **Fixed elapsed time:** The `mm:ss` next to a waiting label measures from the current turn's start to the start of the current wait. It stays fixed while awaiting an answer and is omitted when reliable timestamps are missing. It is not CPU time and does not subtract earlier waits in the same turn.
- **Running timer:** Without a reliable record of the current turn's start, the timer shows `--:--` with an explanation on hover. A bounded search for explicit start records runs only for monitored tasks and their children, filling time fields after compatibility checks. Missing or uncertain evidence keeps the placeholder; app launch time, file modification time, and the latest output timestamp are not used to invent a duration.
- **Appearance and placement:** Switch between black and light glass with a reveal spreading from the click location. Beta.3 matches the snapshot's corner edges, curves, and scale to the live panel. Adjust app scale from 60% to 120% in 5% steps, or reset to 100%; the orb stays at 44pt. External displays and floating lists use compact type. At 60%–75%, the task-selection button becomes a plus icon.
- **Free dragging:** Drag any non-button area of the header in the floating list or expanded orb panel. Dropping at the screen's top edge does not dock or change modes; choose modes from the menu. After moving an expanded orb panel, it collapses to its new orb position.
- **Pinning:** Pinning shows only the floating list; unpinning returns to notch mode. The system menu bar item stays available for recovering windows and changing modes.
- **Task and usage links:** Click a task to attempt to open its Codex conversation, or click usage to open the [official usage page](https://chatgpt.com/codex/settings/usage). Account usage refreshes about every 60 seconds, with a 5-second minimum between manual requests and a 15-second timeout. Hover for source, update, and reset details.

While the app is active, `⌘,` opens Settings and `⌘T` shows tasks. When the app or a monitor window has keyboard focus, `⌘+` / `⌘=` increases scale and `⌘-` decreases it in 5-percentage-point steps within 60%–120%. These shortcuts do not globally intercept keys in other apps. Settings opens on the display containing the pointer; if already visible within that display, it keeps its position. See the [usage guide](docs/usage.md) for detailed instructions.

## Data and limitations

- Uses `CODEX_HOME` or `~/.codex` by default, with a custom directory available in Settings. Task metadata and incremental logs are read-only: the app does not modify Codex data or upload task content. The official CLI manages authentication; this app does not directly read or copy authentication files.
- Status comes from records saved to disk, not another process's live memory. Running records become unknown after 15 minutes without activity. Remote/cloud tasks not synced locally are outside the current scope. The initial bounded tail read may miss older waiting events; a backlog is shown as activity still being synced.
- Start-time recovery fills only time fields compatible with the current activity. It does not enlarge the initial tail read for every task or replace current task state with historical replay state. Missing or unconfirmed records are not estimated, and this does not guarantee recovery of all historical waits.
- Waiting activities in the monitored list, including waiting child tasks grouped under a parent, use file-change notifications for up to 64 local rollout files. Changes are coalesced for about 200ms before an incremental refresh; 2-second polling remains as a fallback. Reading a saved user reply clears the waiting state without awaiting a later completion event. This does not guarantee a fixed delay from pressing Send. Pausing task refresh stops these watches; account usage retains its independent 60-second refresh cycle.
- The main usage display uses only the current account interface. Log-based usage is shown separately as historical. Failed reads do not fall back to another account or old logs, and missing usage windows are not invented. Pausing task refresh does not pause usage refresh. Account changes appear on the next actual read, not necessarily immediately.
- Codex's internal formats may change. Conversation destinations, real account switching, physical display disconnects/lid closure, complete mouse dragging, and animation frame rates still have unverified scenarios. See [current status](docs/STATUS.md) and the [validation matrix](docs/validation/acceptance-matrix.md).
- **Only the macOS app is implemented.** The [Windows implementation prompts](docs/handoff/windows-implementation-prompts.md) are handoff material for future work, not a Windows release.

## Build locally

Requires macOS 14+ and a Swift 6 toolchain (Xcode). Built with SwiftUI, AppKit, and system SQLite, without third-party Swift runtime dependencies.

```sh
swift test
bash scripts/build-app.sh
```

Open `dist/Codex Top.app` to use real tasks. To try the UI with sample data only:

```sh
bash scripts/build-app.sh --demo
```

`dist/Codex Top Demo.app` uses separate settings and synthetic tasks. It does not read local tasks or account usage. Quit Demo before switching back to the real app.

Build scripts default to the host architecture and ad-hoc signing. See the [development guide](docs/development.md) for universal builds, ZIP/DMG packaging, and read-only diagnostics. Automated tests do not replace packaged-app or physical-device validation.

## Documentation and contributing

The detailed documentation and implementation prompts are currently in Chinese.

- [Usage guide](docs/usage.md) · [Development and packaging](docs/development.md)
- [Documentation and prompt index](docs/README.md) · [Windows implementation prompts](docs/handoff/windows-implementation-prompts.md)
- [Current status](docs/STATUS.md) · [Application validation records](docs/validation/notch-orb-refinement.md)

Feedback through [Issues](https://github.com/BuTangTang/Codex-Top/issues) and pull requests is welcome. Include macOS/Codex versions and reproduction steps. Do not upload raw `.codex` data, authentication files, or screenshots of private tasks.

Copyright © 2026 BuTangTang. Licensed under [GNU GPL v3](LICENSE). An independent community project, not officially affiliated with OpenAI.
