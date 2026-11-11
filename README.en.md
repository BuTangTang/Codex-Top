# Codex Top

[简体中文](README.md) · **English**

Keep an eye on your Codex and Claude Code tasks from the desktop: what is running, what is waiting for you, and what just finished — without switching windows.

A native macOS app (SwiftUI + AppKit). The current source and local install are **v1.0.0 build 154**. [Published downloads](https://github.com/BuTangTang/Codex-Top/releases) are versioned separately. A cross-platform Qt version is in development; see [below](#cross-platform-qt-version-in-development).

## Install

- Requires **macOS 14+**; the DMG is universal for Apple silicon and Intel.
- Download the DMG from [releases](https://github.com/BuTangTang/Codex-Top/releases), drag `Codex Top.app` into Applications, and open it.
- Codex tasks need a local Codex installation with task records; Claude Code sessions need a local Claude Code installation; Codex usage limits need the official Codex CLI to be signed in. No API key is entered in this app.
- The app is ad-hoc signed and not notarized. If macOS blocks it, verify the download source and follow [Apple's instructions](https://support.apple.com/en-us/102445); do not turn off system-wide protection.

## What it does

### Four display modes

| Mode | Behavior |
|---|---|
| Orb | An LED dot-matrix orb; click to open the task panel, click outside or press Esc to close; drag it anywhere, including flush against a screen edge |
| Floating panel | The task panel stays on the desktop |
| Notch | Shown near the notch and expands on hover; screens without a notch show it along the top |
| Menu bar only | A count in the menu bar; click to open the panel |

All modes share one watch list. The top-right “＋” picks tasks and “⋯” switches modes and themes.

### The orb

- White number = running tasks; amber = waiting for your answer or approval; red = failed; green = just finished and not yet seen.
- While something runs, a blue comet circles clockwise. When a task finishes, starts waiting, or fails, the comet turns green, amber, or red in place for two laps. With nothing running it slows to a stop.
- When everything is done it shows a green OK with a short charge-up celebration, then a slowly breathing Zz after 5 minutes without new work.
- Dots are aligned to device pixels on both 1x external and 2x built-in displays.

### The task panel

- Sections: needs you → just finished → in progress → finished (collapsible).
- Each row has a vertical status light on the left and a monospaced timer on the right; waiting and failed rows carry a tag. When no reliable start time exists it shows `--:--` instead of guessing.
- With both Codex and Claude Code tasks present, each row is marked CX or CC.
- Clicking a task opens it in the Codex or Claude desktop app.
- Footer: toggle finished tasks on the left; the CX weekly limit and CC tokens used today on the right (a usage day starts at 12:00 noon local time, so late nights count toward the same day). Clicking CX or CC pulls a usage card out below the footer: limits (5-hour only when your plan has one), today's tokens vs. yesterday, input/cache/output breakdown, and a 7-day chart.

### Watch rules

- With auto-watch on, newly started tasks — and older tasks that start running or waiting again — join the watch list; tasks you removed by hand stay out.
- Finished tasks drop off after a set number of days; you can also right-click “Stop watching”.
- Subtasks roll up into their parent task.

### Claude Code

- Reads local Claude Code transcripts and the session registry, so sessions from the desktop app and the terminal both appear.
- Optional switch “Show waiting for approval”: adds one notification hook to Claude Code's settings that records only the session id and time (backed up before editing, removed cleanly when switched off), so permission prompts show as amber. It applies to sessions started after the switch is turned on.

## Data and privacy

- Reads `~/.codex` (or `CODEX_HOME`) and `~/.claude` (or `CLAUDE_CONFIG_DIR`) by default; both can be chosen in Settings.
- Read-only: it does not modify Codex or Claude Code records or settings (the only exception is the hook switch you turn on yourself), uploads nothing, and does not read credential files.
- Status comes from records written to disk, not live process state. A running task with no new activity for 15 minutes shows as unknown. Tasks running on another machine (for example, projects opened over SSH) keep their records there and are not visible.
- Usage counts come from token numbers in local records. When Claude Code runs through a gateway there is no plan limit, so only the amount used is shown.

## Build locally

Requires macOS 14+ and Xcode (Swift 6).

```sh
swift test
bash scripts/build-app.sh
```

`dist/Codex Top.app` reads your real tasks. To look at the sample interface only:

```sh
bash scripts/build-app.sh --demo
```

`dist/Codex Top Demo.app` uses separate settings and synthetic tasks and reads no local data. Universal builds, DMG packaging, and diagnostics are covered in the [development notes](docs/development.md).

## Cross-platform Qt version (in development)

To support both macOS and Windows, the app is being ported to Qt 6 (C++ and QML). The code lives in [`qt/`](qt/); progress is tracked in the [REQ-004 task overview](docs/REQ-004-Qt跨平台迁移/tasks/progress.md) (Chinese).

- Done: the technical spike — the orb is crisp, never steals focus, and idles at zero CPU on both Mac displays and Windows 11 ([record](docs/validation/qt-m0-20261111.md)).
- In progress: porting the data layer, followed by the interface, platform differences, and a side-by-side trial. Once the Qt version reaches parity, the native Mac app stops receiving updates (and the phone connection pauses at that point).
- The C#/WPF version on the `windows` branch is no longer being developed.

## Docs

- [Usage](docs/usage.md) · [Development and packaging](docs/development.md) · [Docs index](docs/README.md) · [Current status](docs/STATUS.md) (Chinese)

Issues and pull requests are welcome on [GitHub](https://github.com/BuTangTang/Codex-Top/issues). Please include your macOS, Codex, or Claude Code version and steps to reproduce, and do not upload raw `.codex` or `.claude` data, credential files, or screenshots with private content.

Copyright © 2026 BuTangTang. Licensed under the [GNU GPL v3](LICENSE). An independent community project, not affiliated with OpenAI or Anthropic.
