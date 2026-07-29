# Hily Agent Guide

Read `README.md` first. `CLAUDE.md` and `.claude/rules/` contain the detailed architecture and feature rules.

## Working Tree

- The repository is frequently used by parallel development sessions. Preserve unrelated changes and do not revert or reformat them.
- `project.yml` is the source of truth for the generated Xcode project. Do not edit `Hily.xcodeproj` directly.
- New source files or `project.yml`/Pod changes require the user-approved `./bin/regen.sh`; it closes Xcode before regenerating the workspace.

## Configuration And Secrets

- `Config/Config-*.xcconfig` is local-only. Start from the matching `.xcconfig.example` file and obtain values through the approved credential channel.
- Never add keys, tokens, passwords, private URLs, or credential values to source, tests, plans, issues, logs, or documentation.
- `AppConfig` intentionally fails when an app build lacks injected configuration. Do not restore development fallback values.

## Verification

- Run `./bin/check-repository.sh` after repository-automation or configuration-template changes.
- For pure Swift edits, use `xcrun swiftc -parse` when practical. For app changes, use a build or real-device verification only when the current worktree is stable.
- RTC, IM, camera, and live-room changes require real-device validation; a successful compile is insufficient evidence.
