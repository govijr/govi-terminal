# Govi

[![CI](https://github.com/govijr/govi-terminal/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/govijr/govi-terminal/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Govi is a native macOS terminal workspace for working with coding agents. It
is built on the [Ghostty](https://github.com/ghostty-org/ghostty) terminal
engine and adds a sidebar of workspaces, draggable split panes, agent status
and notifications, worktree-based agent sessions, session recovery, and
GitHub and Linear task context.

## Repository layout

| Path | What it is |
| --- | --- |
| [`app/`](app) | The macOS app: Ghostty's Zig engine (`src/`), the Swift app (`macos/`) and Govi's build scripts and tests (`govi/`). See [`app/README.md`](app/README.md). |
| [`web/`](web) | The project website, a Next.js app. |
| [`.github/`](.github) | CI workflows, issue and pull request templates. |

## Getting started

You need a Mac with Xcode 26 or later. The build downloads the pinned Zig
compiler (0.14.1) on first run.

```sh
cd app
./govi/build.sh      # builds dist/Govi.app
./govi/run.sh        # builds if needed and opens it
./govi/test.sh       # runs the same unit tests as CI
```

For the website:

```sh
cd web
npm ci
npm run dev          # http://localhost:3000
```

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) for
how to set up, test and submit a pull request, and follow our
[Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, see
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

Govi is licensed under the [Apache License 2.0](LICENSE).

Govi is built on Ghostty, which is © Mitchell Hashimoto and Ghostty
contributors and licensed under the [MIT License](app/LICENSE). Code that came
from Ghostty remains available under that license. Bundled fonts, themes and
icons keep their own licenses; see [NOTICE](NOTICE).

Govi is an independent project and is not affiliated with or endorsed by the
Ghostty project.
