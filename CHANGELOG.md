# Changelog

All notable changes to Agent Continuity are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are published from GitHub Actions (`Release` workflow, manual dispatch
with a `vX.Y.Z` tag input); the full test suite is the release gate.

## [Unreleased]

### Added
- Profile edit dialog in the UI (allowedGlobs / excludedGlobs / trackedOnly /
  maxDiffSizeBytes) backed by fail-closed validation in core
  (`Test-AcProfileValue` / `Save-AcProfile`); invalid input never touches the
  existing profile file.
- `schemaVersion` is now enforced on every cross-machine record read
  (config, lease, transaction, backup manifest). Unknown or newer versions
  abort instead of being misinterpreted; session-snapshot restore degrades
  with status `unsupported-schema` while the Git handoff continues.
- User secret-scan rules: optional `<home>/config/secret-rules.json`
  (see `schemas/secret-rules.schema.json`). Rules are additive only —
  built-in rules can never be removed or overridden, and an invalid rules
  file aborts the scan entirely (fail-closed).
- i18n (ko/en): every user-facing string across launchers, core modules,
  bootstrap scripts, the installer and the WPF UI now renders from
  `i18n/ko.psd1` / `i18n/en.psd1`. Korean remains the default; select
  English with `AC_LANG=en` or `"language": "en"` in config.json.
- `Update-AgentContinuity.ps1`: updates an existing installation in place.
  Refuses to run while any session is in progress on this machine
  (session state or live lease keeper), refuses to overwrite a folder that
  is not an installation, and never touches config/state.
- `CHANGELOG.md` and `SECURITY.md`.
- `AC_CODEX_BIN` / `AC_CLAUDE_BIN` environment overrides for custom agent
  CLI locations.
- Setup and Start now print the worktree path (and Setup the default
  allowedGlobs), so it is always clear where to work and what gets handed
  off; Show-Status adds a one-line verdict (up to date / behind) and shows
  a released lease as idle.

### Changed
- The automatic handoff record in `CURRENT.md` is now a marker-managed
  section keeping only the last 3 records (legacy unbounded records are
  cleaned up on the next Finish); a retried Finish replaces its own record
  instead of duplicating it.

### Fixed
- An aborted Finish (secret detected, size limit) no longer writes the
  handoff record into `CURRENT.md` — a failed handoff leaves no trace in
  the worktree.
- A failed agent CLI launch (not installed, wrong path) no longer ends
  Start with a raw exception: the session stays open and Start explains
  how to continue manually.
- Setup now refuses to silently create an empty orphan work branch when
  the remote has commits but no determinable default branch.
- Unknown project names now list the registered projects instead of a bare
  exception.

## [0.5.1]

### Added
- Install location picker in the one-click setup executable.

## [0.5.0]

### Added
- One-click setup/launcher executable (`AgentContinuity-Setup.exe`, Go,
  embedded payload, winget-driven dependency install).
- In-app project registration and worktree relocation (distribution plan D2).
- MIT license.

## Earlier development (pre-release milestones)

- **D1 packaging** — module manifest, install script, CI (ubuntu + windows)
  and the release pipeline.
- **Worktree adoption** — custom worktree paths, promotion of existing
  clones (including dirty clones), UI autostart, app icon.
- **Phase 3 (experimental)** — encrypted CLI session snapshots with version
  allowlist, integrity checks and no-merge conflict rules.
- **WPF UI** — thin convenience shell over the launchers; CP949 log
  garbling and ANSI escape fixes for Korean Windows.
- **Phase 2** — age multi-recipient encryption, DPAPI-protected keys,
  offline recovery key, rescue bundles, verified restore with automatic
  rollback, stale-lease takeover.
- **Phase 1 MVP** — Git handoff with complete transactions, remote
  single-writer lease (CAS via plain pushes), secret scan, launchers,
  self-built test framework.
