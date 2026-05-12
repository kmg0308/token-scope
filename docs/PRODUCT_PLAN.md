# Product Plan

## Goal

Build a local macOS app that helps a developer understand Codex and Claude Code token usage over time.

## Core Information Architecture

The app uses three dashboard sections:

- All: combined Codex and Claude Code usage.
- Codex: Codex-only usage with Codex token fields.
- Claude Code: Claude-only usage with Claude token fields.

All sections share the same time range, bucket size, model filter, and project filter.

The default screen intentionally hides secondary tables. The first view should answer only three questions:

- How many tokens were used?
- How did usage change over time?
- Which tool or token type made up the total?

Project, model, and session tables live behind Details.

## Required Views

### App Window

The primary experience is a normal macOS app window. It appears in the Dock and app switcher.

### Dashboard

The dashboard shows:

- Time controls.
- Summary metrics.
- Main time-series graph.
- Breakdown graph.
- Session, model, and project tables.
- Data status.
- Update controls.

## Data Sources

TokenMeter reads local JSONL records:

- Codex: `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Claude Code: `~/.claude/projects`.

The app parses token fields only. Prompt and response text are ignored.

## Design Direction

The visual design is intentionally plain:

- Grayscale by default.
- Color only where distinction is necessary.
- Native macOS controls.
- Small typography.
- Dense but readable tables.
- No decorative gradients, hero panels, or marketing layout.

## Update Strategy

TokenMeter supports a practical no-paid-account update path:

- Check the fixed `kmg0308/token-scope` GitHub repository's latest Release.
- Download the latest Release ZIP when available.
- Install and relaunch when the downloaded ZIP contains `TokenMeter.app`.
- A GitHub Actions workflow publishes a new Release from each main push.
- Installed apps check the latest Release on launch.

Sparkle is documented as a future option for fully automatic app replacement.
