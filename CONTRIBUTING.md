# Contributing to Peppap

## Branches

Peppap uses GitHub flow:

- `main` is always releasable. It is protected: changes land only through pull requests with green CI.
- Work on a short-lived branch named after the change type: `feat/gitlab-notifications`, `fix/notch-tabs-overlap`, `chore/release-it`.
- Pull requests are **squash-merged**. The PR title becomes the commit on `main`, and the branch is deleted after the merge.
- To fix an already released version (rare), branch `release/0.5.x` from its tag, fix it there, and release from that branch (see below).

## Pull request titles

PR titles follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope)?: subject`, with a lowercase subject in English. A CI check enforces it. Commits inside a branch can be free-form, because squash merge keeps only the title.

| Type | Use for | In the changelog | Version bump |
|---|---|---|---|
| `feat` | a new user-visible feature | Added | minor |
| `fix` | a bug fix | Fixed | patch |
| `perf`, `refactor`, `revert` | behavior-preserving changes worth mentioning | Changed | patch |
| `docs`, `style`, `test`, `build`, `ci`, `chore` | everything else | hidden | none |

A breaking change (`feat!: …` or a `BREAKING CHANGE:` footer) bumps the major version.

Examples: `feat: add GitLab notifications`, `fix(notch): keep tabs out from under the notch`, `ci: build universal binaries`.

## Building and testing

Only the Command Line Tools are needed:

```sh
./build.sh          # build/Peppap.app
scripts/test.sh     # tests (also run in CI and before every release)
```

## Releasing

The version lives in `package.json` (SemVer, like an npm package). Releases are cut with [release-it](https://github.com/release-it/release-it) through [bun](https://bun.sh); nothing is published to npm.

One-time setup: `bun install`.

From an up-to-date `main` with a clean working tree:

```sh
bun run release                       # suggests a bump from the commits since the last tag
bun run release minor                 # or patch / major
bun run release --preRelease=beta     # 0.6.0-beta.0; repeat with --preRelease for beta.1, …
bun run release --dry-run             # show what would happen
```

release-it runs the tests, bumps `package.json`, writes the new section of `CHANGELOG.md` from the commit titles, commits `chore(release): vX.Y.Z`, tags `vX.Y.Z` and pushes. The push to `main` goes through the admin bypass of the branch protection.

The tag starts the **Release** workflow (`.github/workflows/release.yml`):

1. It checks that the tag matches `package.json`, runs the tests and builds a universal app.
2. It publishes a GitHub Release with the `.dmg`, `.zip`, `SHA256SUMS.txt` and the notes from `CHANGELOG.md`.
3. For a stable version, it updates the cask in [dongaber/homebrew-peppap](https://github.com/dongaber/homebrew-peppap) (deploy key in the `HOMEBREW_TAP_DEPLOY_KEY` secret).

Pre-releases (`-beta.N`, `-rc.N`) are published as GitHub pre-releases. The in-app updater and Homebrew only see stable versions.

The app's build number (`CFBundleVersion`) is the commit count.
