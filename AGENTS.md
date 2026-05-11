# TokenMeter Agent Guide

This project follows a compact, evidence-first coding style adapted from Andrej Karpathy's public coding-agent guidance.

## Working Rules

- Start from the current product behavior, not from a large imagined rewrite.
- Before editing, identify the smallest file set that can satisfy the request.
- Prefer deleting stale flexibility over adding new switches or broad abstractions.
- Keep changes readable in one pass. If a helper does not make the caller simpler, do not add it.
- Do not preserve dead states just because they once existed in the UI.
- Treat names shown to users as product surface. Keep app name, bundle name, release asset name, and docs aligned.
- Keep settings visible near the thing they affect. For example, chart display options belong next to chart controls, not hidden in filters.

## Verification Rules

- For core parsing, aggregation, update, packaging, or range behavior, run `./scripts/verify.sh`.
- For narrow Swift UI or formatter changes, run `swift build` at minimum; prefer `./scripts/verify.sh` before handing off.
- When changing app identity or packaging, inspect `dist/`, `Info.plist`, and `/Applications` install state.
- Do not call a task done because a build passed. Check that the build covers the user-facing promise.

## Project Constraints

- App display name is `TokenMeter`.
- Swift package target names use `TokenMeter`; do not reintroduce the old project name.
- Release ZIPs must contain `TokenMeter.app` for in-app installation.
- The app is a normal macOS app, not a menu-bar-only app.
- Token data stays local. GitHub network calls are only for update checks and update downloads.

## Review Checklist

- Is the requested behavior directly visible in the UI or documented where the user would look?
- Is any old option, enum case, branch, artifact, or label contradicting the current product?
- Can a simpler branch, smaller data type, or deleted helper make the behavior easier to trust?
- Did verification exercise the changed behavior, not just unrelated code?
