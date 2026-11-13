# Changelog

Notable changes to Govi are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions will
follow [Semantic Versioning](https://semver.org/) once releases begin.

## [Unreleased]

### Changed

- Govi is now licensed under MIT. Third-party licenses and copyright notices
  are retained.

### Added

- Mods: folders with a `mod.json` that add web or terminal panes, command
  palette commands, shortcuts, event hooks, link handlers and a background
  service. Managed in Settings › Mods and with `govi mod`; see
  `app/govi/MODS.md`. Includes an Android emulator example mod.
- Apache 2.0 license, contribution guide, code of conduct and security policy.
- Continuous integration for the app and the website on every pull request.
- `app/govi/test.sh` to run all unit tests, and `app/govi/format.sh` to
  format and check Govi's Swift sources.
