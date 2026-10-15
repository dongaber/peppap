# Changelog

All notable changes to Peppap. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Added
- English interface alongside Russian, with a language switch in Settings (System / English / Русский) that applies instantly.
- Welcome window on first launch: language, one-click hook setup, permissions and tips (✦ menu → Welcome…).
- Update check against GitHub Releases (at launch and every 12 hours) with in-app install and relaunch; can be turned off in Settings.
- Test suite (`scripts/test.sh`) covering hook parsing, status line, diffs, usage, transcripts, session flows and settings install; runs in CI.

### Changed
- “Play demo” now runs the same scenario as the demo recording.

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

[Unreleased]: https://github.com/dongaber/peppap/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/dongaber/peppap/releases/tag/v0.3.0
