# Changelog

All notable changes to Peppap. Versions follow [SemVer](https://semver.org/); entries are generated from
[Conventional Commits](https://www.conventionalcommits.org) by `bun run release`.

## [0.6.0](https://github.com/dongaber/peppap/compare/v0.5.0...v0.6.0) (2026-10-16)

### Added

* **gitlab:** act on merge requests from the notch ([#5](https://github.com/dongaber/peppap/issues/5)) ([2de09db](https://github.com/dongaber/peppap/commit/2de09db4fff20c1d654fd21617eeff7bb87d72ff)), closes [#4](https://github.com/dongaber/peppap/issues/4)

### Fixed

* **updater:** order pre-release versions per SemVer ([#3](https://github.com/dongaber/peppap/issues/3)) ([d5d3485](https://github.com/dongaber/peppap/commit/d5d348569077e9dd3438a866ccb4badd9e656011)), references [#1](https://github.com/dongaber/peppap/issues/1)

## [0.5.1-beta.0](https://github.com/dongaber/peppap/compare/v0.5.0...v0.5.1-beta.0) (2026-10-16)

### Fixed

* **updater:** order pre-release versions per SemVer ([#3](https://github.com/dongaber/peppap/issues/3)) ([d5d3485](https://github.com/dongaber/peppap/commit/d5d348569077e9dd3438a866ccb4badd9e656011)), references [#1](https://github.com/dongaber/peppap/issues/1)

## [0.5.0] — 2026-10-16

### Added
- GitLab notifications: a new review request, a failed pipeline in your MR, or your MR becoming ready to merge plays a sound and briefly expands the notch (each can be turned off in Settings → GitLab).
- While Claude is idle, the collapsed notch shows a merge icon with the number of unseen GitLab events; opening the notch goes straight to them.
- Optional “Connect GitLab” step in the welcome window.

### Changed
- The expanded notch is organized by source: Claude · GitLab next to the notch, the source's tabs (Sessions / Today / Week, Mine / Review) below it. ←→ switch the source, Tab switches tabs.
- Settings and the ✦ menu are grouped by source; Claude Code hooks moved to their own section.
- Draft merge requests show their title without the “Draft:” prefix.

### Fixed
- Tabs no longer slide under the hardware notch.

## [0.4.1] — 2026-10-16

### Added
- GitLab merge requests tab: your open MRs and review requests with pipeline status, approvals, comments and merge blockers. Host, token (kept in the Keychain) and refresh interval are set in Settings → GitLab.

## [0.4.0] — 2026-10-15

### Added
- English interface alongside Russian, with a language switch in Settings (System / English / Русский) that applies instantly.
- Welcome window on first launch: language, one-click hook setup, permissions and tips (✦ menu → Welcome…).
- Update check against GitHub Releases (at launch and every 12 hours) with in-app install and relaunch; can be turned off in Settings.
- Homebrew cask (`brew tap dongaber/peppap https://github.com/dongaber/peppap && brew install --cask peppap`), bumped automatically on each release.
- Test suite (`scripts/test.sh`) covering hook parsing, status line, diffs, usage, transcripts, session flows and settings install; runs in CI.

### Changed
- “Play demo” now runs the same scenario as the demo recording.
- README demo video and screenshots are now in English.

### Fixed
- Change preview now lists removed lines before added ones.

## [0.3.0] — 2026-10-15

First public release.

### Notch status
- Claude Code session status: working, needs permission, done; task timer and plan progress ring.
- Expands on hover, via hotkey (⌃⌥C) and automatically on events, with a Dynamic Island-style animation.
- Sessions, Today and Week tabs.

### Working with Claude from the notch
- Answer permission requests: Allow, Always allow, Deny, or hand back to the terminal; change preview for Edit and Write.
- Answer Claude's questions (AskUserQuestion).
- Quick replies to a session (Terminal, iTerm2).
- Jump to a session: Terminal or iTerm2 tab, project window in VS Code, Cursor, Windsurf or Zed.

### Stats
- Exact subscription limits (5-hour and weekly) and context usage from the Claude Code status line.
- Tokens and API-price cost for the task, session, day and week; changed files and lines.
- Task history, weekly chart, Markdown report export.

### Convenience
- Pin, rename and hide sessions.
- Sound and trackpad haptics; do-not-disturb during calls and in full screen.
- Session restore after restart; closed terminals and Esc interrupts are detected automatically.
- Settings window, launch at login.
- Demo video recording for the README (made-up data, neutral background).

[0.5.0]: https://github.com/dongaber/peppap/releases/tag/v0.5.0
[0.4.1]: https://github.com/dongaber/peppap/releases/tag/v0.4.1
[0.4.0]: https://github.com/dongaber/peppap/releases/tag/v0.4.0
[0.3.0]: https://github.com/dongaber/peppap/releases/tag/v0.3.0
