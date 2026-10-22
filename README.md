<p align="center">
  <img src="macos/Resources/icon.png" width="128" alt="AI Usage icon">
</p>

# AI Usage

A macOS menu bar app for Claude and Codex usage. It detects signed-in providers automatically: Claude only, Codex only, or both. When both are available, use the provider switcher in the popover.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License](https://img.shields.io/badge/license-BSD--2--Clause-green)

## What it shows

- **Claude:** 5-hour and 7-day usage, reset times, model breakdown, extra usage, and history. Sign in through the app if needed.
- **Codex:** account rate-limit windows and reset times from your local `codex app-server`, plus session token totals from local `~/.codex/sessions/` and `~/.codex/archived_sessions/` logs. Install and sign in to Codex first with `codex login`; the app reads the account status through Codex's documented local protocol and does not read its credentials.
- **Claude Code tokens:** input, output, cache read/write, daily activity, and API-equivalent cost from local `~/.claude/projects/` logs. The cost uses Claude Code's recorded `costUSD` when available and otherwise applies published per-model rates, including cache duration and relevant pricing modifiers. It is an estimate of API value, **not** your subscription bill or an amount owed.

All providers can be used independently. The app refreshes usage in the background and shows it in the menu bar.

## Install

Download `ClaudeUsageBar.zip` from the [latest release](https://github.com/chaoyupeng/ai-usage/releases/latest), unzip it, then drag `ClaudeUsageBar.app` to Applications. The bundle retains its previous filename and identifier so existing installations and settings continue to work; its display name is AI Usage.

The app is not Apple-notarized. On first launch, use **System Settings → Privacy & Security → Open Anyway** after macOS blocks it. You can also build locally:

```sh
git clone https://github.com/chaoyupeng/ai-usage.git
cd ai-usage
make app
make install
```

## Privacy and local data

Claude OAuth credentials and usage history are stored in `~/.config/claude-usage-bar/`. Claude Code and Codex transcripts are read locally and never uploaded by this app. The Codex CLI handles its own authentication and contacts OpenAI to fetch its rate limits when the app invokes its local app-server. The app also contacts Anthropic for Claude usage and model names, and GitHub once a day to check for releases.

## Build and test

Requires macOS 14 or later and Xcode. Run `swift test` from `macos/`; run `make app` from the repository root. The release bundle is built by `macos/scripts/build.sh`.

## License

[BSD 2-Clause](LICENSE)
