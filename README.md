# Peppap

Your dev status in the MacBook notch: Claude Code sessions, GitLab merge requests and more.

![Peppap: Claude Code sessions in the notch](docs/demo.gif)

<sub>Full video: [docs/demo.mp4](docs/demo.mp4). The demo uses made-up projects and data.</sub>

<table>
  <tr>
    <td><img src="docs/screenshot-permission.png" alt="Permission request with a change preview"></td>
    <td><img src="docs/screenshot-today.png" alt="Today tab: usage limits and task timeline"></td>
  </tr>
</table>

## Features

The expanded notch has a source switch next to the notch (Claude · GitLab) and the source's tabs below it.

### Claude Code

- **Status in the notch.** While Claude works, a ✻ spinner turns next to the notch, a ring shows progress through Claude's plan, and a timer counts the current task.
- **Answer permission requests from the notch:** Allow, Always allow, Deny, or hand the request back to the terminal. If the session's terminal is already in front, the request goes straight there. If you don't answer, it returns to the terminal after a configurable timeout.
- **Change preview** (Edit / MultiEdit / Write) right in the permission card.
- **Claude's questions** (AskUserQuestion) with answer options in the notch.
- **Per-session details:** Claude's plan (`TodoWrite`, `TaskCreate`) with progress, context usage, running subagents, Claude's last reply, tokens and cost for the task and the session, changed files and lines.
- **Exact subscription limits** (5-hour and weekly) and exact context usage, taken from the Claude Code status line. If you already had a status line, it keeps showing: Peppap only reads the data.
- **Today tab:** daily totals, usage limits and a timeline of finished tasks.
- **Week tab:** a 7-day chart by cost, time or number of tasks, plus a Markdown export of the weekly report.
- **Quick replies:** "Continue", "Run the tests" or your own message. Works with Terminal and iTerm2.
- **Jump to a session:** the right Terminal or iTerm2 tab (matched by tty), the project window in VS Code, Cursor, Windsurf or Zed, or just the terminal app.
- **Resilience:** closed terminals disappear from the list, Esc interrupts are detected from the transcript, and live sessions are restored after Peppap restarts.
- **Right-click a session** to pin it, rename it, or hide it until its next activity.

### GitLab

- **Mine and Review tabs:** your open merge requests and the ones waiting for your review, with pipeline status, approvals, comments and what blocks the merge.
- **Notifications** when someone requests your review, a pipeline fails in your MR, or your MR becomes ready to merge. While Claude is idle, the collapsed notch shows a merge icon with the number of new events.
- Works with self-hosted GitLab (CE or EE, GraphQL API) and a `read_api` token kept in the Keychain.

### Everywhere

- **Hotkey** (⌃⌥C by default) opens the notch with keyboard control: ←→ switch source, Tab switch tabs, ↑↓ select, ⏎ open, A/S/D/T answer a permission request, R refresh merge requests, Esc close.
- **Notifications:** sound, trackpad haptics and auto-expanding notch. Sound can be limited to long tasks. Peppap stays quiet during calls (microphone in use) and in full-screen apps.
- **English and Russian interface**, following the system language or switched in Settings without a restart.
- **Settings window** (✦ menu → Settings…).

## Installation

With [Homebrew](https://brew.sh):

```sh
brew tap dongaber/peppap https://github.com/dongaber/peppap
brew install --cask peppap
```

Peppap updates itself after that (✦ menu → Update…), and `brew upgrade` works too.

Or download `Peppap-<version>.dmg` from [Releases](../../releases) and drag Peppap to Applications.

The app is not notarized by Apple, so macOS blocks a downloaded copy on first launch (Homebrew and in-app updates handle this for you). Remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Peppap.app
```

Or open System Settings → Privacy & Security and click "Open Anyway".

Requires macOS 14 or later, Apple Silicon or Intel.

## Setup

1. Hover over the notch and click **Connect**, or use the ✦ menu in the menu bar.
   Peppap adds its hooks and status line to `~/.claude/settings.json`. A backup is saved as `settings.json.peppap-backup`, and the scripts live in `~/.peppap/`.
2. Restart running `claude` sessions if they don't pick up the change.

The hook sends event JSON to `127.0.0.1:47821`. If Peppap isn't running, `curl` exits silently and Claude Code is unaffected.

The ✦ menu also has: sound toggle, settings, weekly report export, demo, demo recording, and disconnecting the hooks (which restores your previous status line).

### GitLab

1. Create a personal access token with the `read_api` scope (Settings → GitLab → **Create…** opens the right page).
2. Enter your GitLab host (e.g. `https://gitlab.example.com`) and the token in Settings → GitLab. The token is stored in the Keychain.
3. **GitLab** appears next to **Claude** in the expanded notch. The lists refresh every 2 minutes (configurable) and when you open them; press R to refresh, ⏎ or click to open an MR. Choose which events notify you in the same Settings section.

## Building from source

```sh
./build.sh                         # for the current CPU
ARCHS="arm64 x86_64" ./build.sh    # universal build, as in CI
scripts/package.sh                 # dist/Peppap-<version>.zip and .dmg
open build/Peppap.app
```

Only the Command Line Tools are needed (Xcode is optional). Run the tests with `scripts/test.sh`.

Run `scripts/setup-signing.sh` once. It creates a local signing certificate in a separate keychain, so macOS permissions (such as controlling the terminal) survive rebuilds.

Peppap records its own README demo: ✦ menu → Record demo video…. This needs the Screen Recording permission. Then build the GIF and MP4 from the recording:

```sh
swiftc scripts/make-demo-media.swift -o /tmp/make-demo-media
/tmp/make-demo-media ~/Movies/Peppap/peppap-demo.mov docs 3 41 1840 10
```

## Versioning and releases

- The version lives in the `VERSION` file (SemVer). The build number is the commit count.
- Changes go into the `## [Unreleased]` section of `CHANGELOG.md`.
- To cut a release:

  ```sh
  scripts/release.sh 0.4.0              # updates VERSION + CHANGELOG, commits and tags v0.4.0
  git push origin main --follow-tags    # GitHub Actions builds and publishes the release
  ```

- **CI** (`.github/workflows/ci.yml`) builds a universal app on every push to `main` and every pull request; the `.zip` and `.dmg` are attached as build artifacts.
- **Release** (`.github/workflows/release.yml`) runs on `vX.Y.Z` tags. It checks the tag matches `VERSION`, runs the tests, builds the app, publishes a GitHub Release with the `.dmg`, `.zip`, `SHA256SUMS.txt` and notes from the changelog, then bumps `Casks/peppap.rb` on `main`.

## How it works

| File | Purpose |
|---|---|
| `HookInstaller.swift` | hook and status line scripts, `settings.json` changes (updated automatically on launch) |
| `EventServer.swift` | local HTTP server for hook events and status line data |
| `SessionStore.swift` | session state, permissions, daily stats |
| `UsageScanner.swift` | tokens, cost and 5-hour windows from the jsonl transcripts |
| `ProcessWatcher.swift` | running `claude` processes, transcript tail, session restore |
| `NotchController.swift` | the notch panel, hover, auto-expand, keyboard |
| `NotchView.swift` | SwiftUI interface |
| `TerminalFocus.swift` | jumping to a terminal or editor, quick replies |
| `Diff.swift` | change preview, session names and pinning |
| `History.swift` | task history (`~/Library/Application Support/Peppap/history.json`) |
| `Report.swift` | weekly report |
| `DemoRecorder.swift` | demo recording for the README |
| `HotKey.swift` | global hotkey |
| `L10n.swift` | English and Russian strings, language switch |
| `Quiet.swift` | do-not-disturb: calls, full screen |
| `SettingsView.swift`, `Prefs.swift` | settings window and defaults |
| `scripts/make-icon.swift` | app icon generator |

## License

[MIT](LICENSE) © 2026 Alexander Buzmakov
