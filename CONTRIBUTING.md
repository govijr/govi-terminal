# Contributing to Govi

Thanks for helping make Govi better. This guide covers how to set up the
project, what CI checks, and how pull requests get reviewed and merged.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Report a bug** with the [bug report form](https://github.com/govijr/govi-terminal/issues/new?template=bug_report.yml).
  Include your macOS version, the Govi commit you built, and steps to
  reproduce it.
- **Suggest a feature** with the [feature request form](https://github.com/govijr/govi-terminal/issues/new?template=feature_request.yml).
  Describe the problem first; a proposed solution is optional.
- **Fix something.** Issues labelled
  [`good first issue`](https://github.com/govijr/govi-terminal/labels/good%20first%20issue)
  are a good place to start. For a large change, open an issue first so we can
  agree on the approach before you spend time on it.
- **Security problems** go through [SECURITY.md](SECURITY.md), never a public
  issue.

## Project layout

| Path | What it is |
| --- | --- |
| `app/src/` | The terminal engine, in Zig, from Ghostty. |
| `app/macos/Sources/` | The Swift macOS app. Govi's own code is in `Features/Terminal/Govi*.swift` and `Features/AI/`. |
| `app/govi/` | Govi's build, run, format and test scripts, the `govi` CLI and bundled resources. |
| `web/` | The project website (Next.js). |

Prefer putting new features in Govi's own files over editing Ghostty's. That
keeps future engine updates from Ghostty easy to merge.

## Setting up

You need a Mac with Xcode 26 or later. Everything else is downloaded by the
scripts, and Zig is pinned to 0.14.1.

```sh
git clone https://github.com/govijr/govi-terminal.git
cd govi-terminal/app
./govi/build.sh      # builds dist/Govi.app (the first build takes a while)
./govi/run.sh        # opens it
```

Build the app only through `./govi/build.sh` or `zig build`, never with
`xcodebuild` directly; see [`app/AGENTS.md`](app/AGENTS.md).

For the website you need Node.js 22 or later:

```sh
cd web
npm ci
npm run dev
```

## Before you open a pull request

Run the same checks CI runs. If these pass locally, CI should pass too.

**App** (from `app/`):

```sh
./govi/test.sh             # unit tests
./govi/format.sh --check   # Swift formatting (./govi/format.sh fixes it)
./govi/build.sh            # the app still builds
```

**Website** (from `web/`):

```sh
npm run lint
npx tsc --noEmit
npm run build
```

### Tests

The unit tests compile Govi's production Swift sources together with a small
test file and run them without launching the app. They need no network access
and no accounts, and must never read real credentials.

| Test | Covers |
| --- | --- |
| `test-workflows.sh` | workspace models, status transitions, links |
| `test-layout.sh` | the split tree |
| `test-remote.sh` | remote host models |
| `test-integrations.sh` | GitHub and Linear integration models |
| `test-cli.sh` | the `govi` CLI and MCP server, against a fake socket |
| `test-hooks.py` | the agent status hook helper |
| `test-agent-usage.py` | agent quota parsing |

Run one with `./govi/test.sh layout`. When you fix a bug, add a check that
fails without your fix. When you add a test file, add it to `govi/test.sh` so
CI runs it.

Two checks are not part of CI: `test-recovery.py` needs `hc` installed, and
`test-palette.py` needs a built app (CI runs it after the build). Manual checks
against the running app are recorded in [`app/govi/VALIDATION.md`](app/govi/VALIDATION.md).

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each pull request to one change. Small pull requests are reviewed
   faster.
3. Write a clear title, such as "Fix pane drag when the sidebar is hidden".
4. Fill in the pull request template: what changed, why, and how you tested
   it. Add a screenshot or recording for anything visible.
5. Make sure every CI check is green.

### What CI checks

Every pull request runs these jobs. All of them must pass before it can be
merged, and `main` can only change through a pull request.

| Check | What it does |
| --- | --- |
| **App / Unit tests** | Runs `./govi/test.sh`. |
| **App / Swift format** | Runs `./govi/format.sh --check`. |
| **App / Build** | Builds `Govi.app` from scratch with `./govi/build.sh`, checks the bundle and runs the palette test against it. |
| **Website** | Lints, type-checks and builds `web/`. |
| **Workflow lint** | Checks the GitHub Actions files for mistakes. |

Jobs for the app only run when `app/` changes, and the website job only when
`web/` changes, so a docs-only change finishes in seconds. A check that is
skipped counts as passed.

If CI fails, open the failing job's log from the **Checks** tab of your pull
request. The last lines usually say what went wrong. Pushing a new commit to
your branch reruns CI. For a first-time contributor, a maintainer approves the
first CI run before it starts.

### Review and merging

A maintainer reviews every pull request. A pull request is merged once:

- every CI check passes,
- review comments are resolved, and
- the change fits the project's direction.

Pull requests are squash-merged, so the title becomes the commit message on
`main`. You don't need to tidy up your branch's history.

## Style

- **Swift:** follow `app/.swift-format`; `./govi/format.sh` applies it.
- **Zig:** `zig fmt`.
- **TypeScript:** ESLint's rules in `web/eslint.config.mjs`.
- Write comments that explain why, not what.
- User-facing text should be short and plain.

## License

Govi is licensed under the [Apache License 2.0](LICENSE). By submitting a
pull request you agree that your contribution is licensed under it, as
described in section 5 of the license. You keep the copyright to your work.

If you copy code from another project, say so in the pull request and keep
its license notice. Only code under a license compatible with Apache 2.0 can
be accepted.
