# TokenMeter

[![Download for macOS](https://img.shields.io/badge/Download%20for%20macOS-PKG-0A84FF?style=for-the-badge&logo=apple)](https://github.com/kmg0308/token-scope/releases/latest/download/TokenMeter.pkg)

[Latest Release](https://github.com/kmg0308/token-scope/releases/latest) · [Download ZIP](https://github.com/kmg0308/token-scope/releases/latest/download/TokenMeter.zip)

TokenMeter is a local-only macOS app for viewing Codex and Claude Code token usage from local log files.

It does not send prompts, code, messages, or token records to any server. GitHub network calls are used only for update checks and update downloads.

## Features

- Main macOS dashboard app with Dock and Cmd+Tab support.
- Dashboard sections: All, Codex, Claude Code.
- Time ranges: today, last 12 hours, last 24 hours, 7 days, 30 days, 3/6/12 months.
- Bucket sizes: auto, 1 minute, 5 minutes, 15 minutes, 1 hour, 1 day, 1 week, 1 month.
- Breakdowns by app, token kind, model, project, and session.
- Local parsing for:
  - `~/.codex/sessions/**/*.jsonl`
  - `~/.codex/archived_sessions/*.jsonl`
  - `~/.claude/projects/**/*.jsonl`
- GitHub Release update check, one-click update install, and relaunch.
- Simple dark macOS UI with colored usage charts.

## Build

```bash
swift test
./scripts/package.sh
```

The packaged app, ZIP, and PKG installer are written to `dist/`.

## Run Locally

```bash
open dist/TokenMeter.app
```

The package script applies free ad-hoc signing, but it does not use a paid Apple Developer certificate. If macOS warns because the app is unsigned, review the source or build it locally before allowing the app to open.

## Install On This Mac

For the normal install flow, download the latest PKG:

```text
https://github.com/kmg0308/token-scope/releases/latest/download/TokenMeter.pkg
```

Open the installer, then launch `TokenMeter` from `/Applications`.

To install from a local build instead:

```bash
cp -R dist/TokenMeter.app /Applications/
open /Applications/TokenMeter.app
```

## Distribute To Another Mac

1. Open the README on the target Mac.
2. Press `Download for macOS`.
3. Open the downloaded PKG. It installs `TokenMeter.app` into `/Applications`.
4. Launch `TokenMeter`.
5. Future updates appear inside the app when a newer GitHub Release exists.

The ZIP is still useful for GitHub Release updates inside TokenMeter.

## Updates

TokenMeter has an update sheet inside the app and a compact update banner on the dashboard.

- Release builds embed the GitHub repository automatically. Local builds can also set it in the update sheet, for example `https://github.com/kmg0308/token-scope`.
- TokenMeter checks the latest GitHub Release when the app opens and then every 6 hours while it is running.
- If the latest Release version is newer than the installed app, the dashboard shows an update banner.
- Press `Update Now` to download the Release ZIP, replace the current app, and relaunch.
- The app updater uses the Release asset named `TokenMeter.zip`. Source ZIP files cannot be installed inside the app.

## Automatic Release From Main

The workflow at `.github/workflows/release.yml` builds and publishes release assets whenever `main` receives a push.

```text
push to main
-> GitHub Actions builds TokenMeter.app
-> creates TokenMeter.zip, TokenMeter.pkg, and versioned copies
-> publishes a GitHub Release
-> installed apps detect the new Release
```

The workflow uses GitHub's `GITHUB_TOKEN` and does not require a paid Apple Developer account. On private repositories, GitHub Actions may count against your GitHub plan quota.

For fully automatic app replacement, Sparkle is the standard macOS updater, but it requires release signing setup. This project avoids paid accounts and external services by default.

## Privacy

TokenMeter reads token fields and metadata such as model, project path, session id, and timestamps. It does not store or display prompt or response text.

## Requirements

- macOS 13 or later.
- Swift 6 toolchain for building from source.
