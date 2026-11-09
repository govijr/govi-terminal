# Scope of the Govi fork

Govi is a macOS app built on the Ghostty v1.2.3 terminal engine. The original
MIT license and copyright notice are retained in the source and app bundle.
The bundled font and theme licenses are retained as well.

Kept:

- GitHub/Linear task context, linked agent workspaces, GitHub PRs/reviews/checks,
  explicit comments and Linear workflow updates. See `INTEGRATIONS.md`.

- GPU rendering, terminal emulation, Unicode, font shaping and fallback.
- PTYs, shell integration, clipboard handling, keyboard/IME input, and terminfo.
- Govi's sidebar, workspaces, native split tree, pane dragging and snapping.
- GUI themes/fonts/settings, output search, saved commands, session restoration.
- Atomic workspace recovery checkpoints, reusable project templates and editable shortcuts.
- Agent attention queue, optional per-session Claude status hooks and guided helper setup.
- Remote hosts over the system OpenSSH client: saved hosts, `~/.ssh/config` aliases
  and Tailscale tailnet devices with online status and tailnet-published host keys.
  No passwords or keys are stored; panes offer to reconnect when a connection drops.
- Inline suggestions in zsh, with local history/saved-command completions,
  native Tab acceptance and optional user-key Jev ranking.
- Terminal-engine and layout regression sources.

Removed from the product and its build:

- GTK/Linux/FreeBSD application UI and Linux packaging/integration files.
- The iOS application target and UIKit surface.
- Upstream publishing workflows, Nix/Flatpak/Snap packaging and browser examples.
- Sparkle, the upstream updater and feed key, and the Sentry crash-reporting SDK.
- Quick Terminal, global event taps, and upstream Shortcuts/App Intents.
- Alternate title bars, Ghostty icon artwork, icon customization, and inspector UI.
- File-configuration editor/error windows, reload signal, and related menus.
- Bundled Ghostty configuration editor plugins, CLI completions, translations,
  man-page generation, website data, distribution tarballs and benchmark targets.

Internal Ghostty names remain in the C API, terminal protocols, terminfo and
shell integration for compatibility. The shared engine still contains some
platform abstractions; Govi's build rejects application targets outside macOS.
This keeps changes to terminal behavior bounded and future engine updates practical.

Inline suggestions use a native Swift local service and zsh's line editor.
The shell renders dimmed POSTDISPLAY text and only changes BUFFER when the user
accepts it with Tab. Input generations reject stale results. No PTY input is
injected, no startup files are edited, and no model or helper runtime is bundled.
Local suggestions need no account. Optional hosted Jev ranking uses a user key
in Keychain and is off by default. It chooses among local candidates and cannot
supply new command text. The earlier chat panel, composer, agent child-process
adapters, chat menus and related shortcuts have been removed.

Generated outputs are ignored by Git. `./govi/clean.sh --deep` removes the local
compiler, dependency downloads and intermediates while retaining the finished app.
The build wrapper can download its pinned tools again. No running app is closed
or restarted by the cleanup command.

The Ghostty sources removed by this fork remain in Git history. Upstream
Ghostty is tracked as the `upstream` remote so engine releases can be merged.
