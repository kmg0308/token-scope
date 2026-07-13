# TokenMeter

[![Download for macOS](https://img.shields.io/badge/Download%20for%20macOS-PKG-0A84FF?style=for-the-badge&logo=apple)](https://github.com/kmg0308/token-scope/releases/latest/download/TokenMeter.pkg)

[Latest Release](https://github.com/kmg0308/token-scope/releases/latest) · [Download ZIP](https://github.com/kmg0308/token-scope/releases/latest/download/TokenMeter.zip)

TokenMeter is a local-first macOS app for viewing Codex, Hermes Agent, and Claude Code token usage from local data stores.

TokenMeter does not send prompts, code, messages, or token records to any server. It asks the locally installed Codex app server for account limit status, and Codex performs that authenticated OpenAI request without exposing credentials to TokenMeter. GitHub network calls are used only for update checks and update downloads. If Sync Folder is enabled, TokenMeter writes sanitized usage records to the folder the user chooses.

## Features

- Main macOS dashboard app with Dock and Cmd+Tab support.
- Dashboard sections: All, Codex, Claude Code.
- Always-visible Codex account limits with 5-hour and 7-day used/remaining percentages, reset times, and per-credit expiration times for available reset credits.
- Time ranges: 30 minutes, 1/3/6/8/12/24 hours, today, yesterday, 7 days, 30 days, 3/6/12 months, and all history.
- Token views: 1/5/10/20/30 minutes, hourly, daily, weekly, and monthly.
- Breakdowns by app, token kind, model, project, and session.
- Local parsing for:
  - `~/.codex/sessions/**/*.jsonl`
  - `~/.codex/archived_sessions/*.jsonl`
  - `~/.hermes/state.db` for sessions billed through `openai-codex`
  - `~/.claude/projects/**/*.jsonl`
- Optional Sync Folder support for combining multiple Macs through iCloud Drive, Dropbox, Syncthing, or any folder that syncs between devices.
- GitHub Release update check, one-click update install, and relaunch.
- Simple dark macOS UI with colored usage charts.

## Multi-Mac Usage

TokenMeter can combine usage from multiple Macs without copying the original Codex or Claude Code logs.

1. Open TokenMeter on each Mac.
2. In `Sync Folder`, choose the same synced folder. `Use iCloud Drive` creates `iCloud Drive/TokenMeter` when iCloud Drive is available.
3. Each Mac writes one sanitized file under `devices/`.
4. Every Mac reads all device files and shows the same `All Devices` total after the folder finishes syncing.

The sync file contains token counts, timestamps, source, model, device id, and hashed project/session keys. It does not contain prompts, responses, code, raw project paths, or raw log file paths.

The dashboard includes a device filter:

- `All Devices`: merged usage from every device file in the Sync Folder.
- `This Mac`: only the current Mac.
- Other device names: one synced Mac at a time.

The first time a Sync Folder is selected, TokenMeter runs a full local scan to seed that Mac's ledger. Later refreshes merge newly scanned events into the existing device file.

## Build

```bash
swift run TokenMeterSelfTest
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

- Updates use the fixed `kmg0308/token-scope` GitHub Releases source.
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

Hermes stores cumulative session counters rather than a timestamped token record for every API call. TokenMeter opens `~/.hermes/state.db` read-only, imports only sessions billed by `openai-codex`, and follows [Hermes' canonical usage contract](https://github.com/NousResearch/hermes-agent/blob/main/agent/usage_pricing.py): uncached input, cache reads, cache writes, and output are separate buckets; reasoning is an output subset and is not added to the total again. The first observed total is placed at `ended_at` (then the latest message timestamp, then `started_at`), and only later counter deltas are recorded. A delta uses the latest persisted activity timestamp when available, or the time TokenMeter observed the change when Hermes stored no usable activity timestamp. This prevents refresh duplication but cannot reconstruct a more precise historical distribution that Hermes did not persist.

Codex account limit status is fetched through the official local `codex app-server` protocol. TokenMeter never reads or stores the ChatGPT access token and never consumes a reset credit.

When Sync Folder is enabled, TokenMeter writes only sanitized usage records to the chosen folder. Raw project paths and session ids are hashed before export. The original `~/.codex` and `~/.claude` JSONL files and `~/.hermes/state.db` stay local.

## Requirements

- macOS 13 or later.
- Swift 6 toolchain for building from source.
