# Govi

A native macOS terminal workspace built on a local fork of [Ghostty](https://github.com/ghostty-org/ghostty), based on tag `v1.2.3` (`6d2dd585`). The terminal renderer, PTYs, keyboard handling, shell integration, and restoration come from Ghostty. Govi adds the workspace interface.

Govi uses Geist for its interface and monospace fonts for terminal content. The compact sidebar header holds native traffic lights and workspace controls; terminal panes extend to the top of the window. Inline command suggestions appear directly in zsh terminals as you type.

## Use

**GitHub and Linear:** the toolbar's **Tasks** pane opens issues, prepares agent
briefs and linked workspaces, shows pull-request reviews and checks, and provides
explicit comment/status actions. Connect accounts in **Settings → Connections**.
See [integration setup and workflows](govi/INTEGRATIONS.md).

Open `dist/Govi.app`, or run:

```sh
./govi/run.sh
```

- **Sidebar:** switch between terminals and workspaces; filter by title or folder; add project shortcuts. The plus button and project shortcuts create workspaces in the current window's tab group, with the sidebar taking the place of a tab bar. Drag the sidebar divider to resize it.
- **Panes:** split right with `Cmd+D`, split below with `Cmd+Shift+D`, and resize by dragging the gaps. Pane headers also provide split, zoom, and close controls.
- **Move and dock:** grab a pane's title/drag handle or drag its sidebar terminal onto another pane. A tinted outline follows the target: its left, right, top or bottom edge previews a split of that pane; its center previews a position swap. Drop to place the terminal, or press Escape to cancel. Docking within existing splits creates columns, rows or quadrants while preserving the other branches. Moves retain existing terminals and processes, including between open workspaces/windows.
- **Layouts:** pane headers provide split, zoom and new-workspace controls. The command palette also provides split equalization. Layout changes within a workspace support Undo.
- **Appearance:** Settings opens in its own resizable window, so terminals remain available while adjusting preferences. It provides the full bundled collection of 890 Ghostty themes, eight Govi presets, search, and light/dark filters. Choose an installed monospace font and a size from 10–28 pt; JetBrains Mono is bundled. Padding, line height, ligatures, text weight, and cursor shape/blinking are also controlled in the GUI. Changes apply to running terminals.
- **Agent status:** sidebar terminals show **Working**, **Needs input**, **Done** or **Error**, from progress reports (OSC 9;4), title spinners, notifications (OSC 9/777) and the bell. Govi doesn't read screen text. Background sessions can notify you, and the Dock icon counts sessions waiting for you. A collapsed workspace shows its count. Opening a session clears its status. Configure in **Settings → Agents**.
- **Agents in worktrees:** in the **+** menu, turn on **In a new worktree** and pick an agent. Govi creates a branch from the current HEAD (default `<agent>/<MMdd-HHmm>`) at `<repo>.worktrees/<branch>` next to the repository, opens a session there, starts the agent and shows the branch under the session name.
- **Session recovery:** workspace layouts, terminal names, folders and agent labels are checkpointed automatically. macOS restoration takes precedence; Govi uses its own checkpoint if no terminal windows were restored. Recovery opens shells without rerunning startup commands. Claude Code and Codex panes can offer their interactive session chooser when the previous program is no longer attached.
- **Keep programs running:** enable **Settings → Agents → Keep new terminals running after Govi quits**. Govi uses your installed [herdr-core](https://github.com/herdrdev/herdr-core) (`hc`); **Set Up Session Recovery**, **Locate Helper**, and **Check Again** guide setup. A pane counts as persistent only after the helper confirms it started or reconnected. Closing a workspace detaches its persistent programs; closing an individual terminal offers **Keep Running**, **End Program**, or **Cancel**. Detached programs appear under **Running in background**. A computer restart ends local programs.
- **Project templates:** **+ → Project templates** (default `Option+Cmd+T`) opens the template manager. Save the current workspace to preserve pane directions, sizes, folders and names. Review or edit each terminal's shell, startup command, agent or optional tool and task label before opening a fresh workspace. Templates never reuse the original terminals or persistent session IDs. Commands stay local; keep secrets in your shell or Keychain.
- **Notifications:** the bell button (default `Cmd+Shift+A`) opens a floating menu like the **+** launcher, listing terminals waiting for input, stopped with errors or finished, with project, branch, task and available elapsed time. Escape or clicking outside dismisses the menu. **Open Next** or `Option+Cmd+J` moves to the next item. Opening it marks it as seen. Claude sessions opened through Govi can use per-session status hooks; other agents retain terminal-signal detection. Hooks report status without reading prompts or changing permission decisions.
- **Keyboard shortcuts:** **Settings → Shortcuts** records new combinations for workspace, split, navigation, search and attention actions. Conflicts and common system/text-editing shortcuts are rejected. Changes apply to open terminals, menus and shortcut hints. Individual shortcuts or all shortcuts can be reset.
- **Quiet appearance:** **Settings → Background → Use Quiet Preset** selects a solid Graphite background with the current font and spacing. Launch animation is off by default and can be enabled in **Settings → Appearance**.
- **Demo recording:** press **⌘⇧⌃G** (Command–Shift–Control–G) to replay the opening wordmark animation in the active workspace, even when launch animation is disabled. Press again to restart it for another take. This hidden debug shortcut also works in local release builds.
- **Other tools:** `Cmd+K` opens the command palette; `Cmd+P` searches terminals without a permanent search bar; `Cmd+F` searches a copied snapshot of the focused terminal's output. Saved commands fill the prompt without sending Return.
- **Inline suggestions:** in a new zsh terminal, start typing to see a dimmed completion at the cursor. Press **Tab** to accept the visible suggestion without running it. Return runs only the command currently entered. Suggestions come from saved commands, recent shell-history files, commands entered in Govi and common commands. When no suggestion is visible, Tab calls the shell's original completion widget. Moving into the middle of a command, selecting text, or using a continuation prompt hides the suggestion.

## Suggestions and privacy

**Settings → Suggestions** controls inline suggestions and optional Jev ranking. Suggestions are enabled and fully local by default. There is no additional input box or chat panel. The integration is bundled with Govi and loads for new zsh terminals; it does not edit `.zshrc` or other shell startup files. After updating the app, open a new terminal to load the new integration.

The shell's line editor owns the real command buffer, cursor position, ghost text, highlighting and Tab acceptance. Govi returns candidate text over a private local socket scoped to this app instance and user. Responses are bounded and tagged with an input generation; the shell rejects late results after edits, prompt changes or cursor movement. Accepting a completion appends only its visible suffix, without sending Return. The editor connection closes before external programs run, so terminal programs keep their own keyboard handling. This integration currently targets zsh.

Optionally save your own Jev key and enable ranking. The key is stored in macOS Keychain. After a typing pause, ranking sends the typed prefix and at most six candidate commands to TypeSafe, without terminal output or the rest of your history. Candidate commands can contain private paths or arguments, so ranking is off by default. [Jev](https://docs.typesafe.ai/concepts/system-one) chooses from these local candidates; it does not generate commands. Missing keys, low confidence, errors or timeouts keep the local ordering. TypeSafe API charges are separate from agent subscriptions. Saving a key does not make a verification request.

Coding agents such as Codex, Claude Code and Cursor continue to run as ordinary terminal programs with their own native accounts. Inline local suggestions need no agent account or AI subscription.

Settings and saved project/command shortcuts are separate from an installed Ghostty app and stored in Govi's app preferences. Govi no longer creates or reads user configuration files or writes `appearance.conf`; previous files are left on disk and ignored. Bundled defaults and theme files are internal resources. macOS launch arguments are not parsed as appearance settings. Without persistent sessions, layout restoration starts fresh shells after quitting and doesn't keep running processes.

## Build

Requires macOS and Xcode. The build wrapper uses Zig **0.14.1** from `GOVI_ZIG`, an installed matching compiler, or an automatic download from ziglang.org verified against its official SHA-256 checksum. The first build also fetches the pinned terminal-engine dependencies.

```sh
./govi/build.sh
```

The build wrapper uses `zig build` and produces a locally signed `dist/Govi.app` for local use. Intermediate macOS files are under `.build/macos/`. It does not publish or install the app. Native app builds must go through Zig, as required by `AGENTS.md`.

Run `./govi/clean.sh` to clear intermediates while keeping downloaded dependencies and the compiler, or `./govi/clean.sh --deep` to clear those too. The source and `dist/Govi.app` are always kept. Artifacts used by a running process are skipped. A later build restores the generated files it needs.

Run `./govi/test.sh` for the unit tests CI runs on every pull request, and `./govi/format.sh` to format Govi's Swift sources (`--check` only reports). See [CONTRIBUTING.md](../CONTRIBUTING.md). Individual regression checks are available through `./govi/test-workflows.sh`, `./govi/test-layout.sh`, `python3 govi/test-recovery.py`, `python3 govi/test-hooks.py`, `python3 govi/test-agent-usage.py`, and `python3 govi/test-palette.py`. The recovery regression needs an installed `hc` and uses disposable sessions only. Verification and remaining limits are recorded in `govi/VALIDATION.md`.

## Source map

- `macos/Sources/Features/Terminal/GoviWorkbench.swift`: sidebar, workspace chrome, saved commands, output search.
- `macos/Sources/Features/Terminal/GoviWorkspaces.swift`: recovery checkpoints, project templates and restoration.
- `macos/Sources/Features/Terminal/GoviWorkspaceModels.swift`: serialized layouts, status transitions, helper launch scripts and shortcut definitions.
- `macos/Sources/Features/Terminal/GoviShortcuts.swift`: shortcut recording, validation and app-local dispatch.
- `macos/Sources/Features/Terminal/GoviActivity.swift`: attention queue, terminal signals and agent status.
- `govi/Govi/Tools/govi-notify`: bounded local status hook helper.
- `macos/Sources/Features/Terminal/GoviPane.swift`: pane headers, drag/drop previews, transfers, grid layout.
- `macos/Sources/Features/Terminal/GoviAppearance.swift`: theme catalog, font discovery, GUI preferences, and native traffic-light controls.
- `macos/Sources/Features/AI/`: local inline-suggestion service, history candidates, optional Jev ranking and suggestion settings.
- `src/shell-integration/zsh/govi-suggestions.zsh`: display-only ghost text, live buffer tracking and Tab acceptance.
- `macos/Sources/Features/Splits/`: native split tree and resizing.
- `govi/Govi/`: bundled fonts, licenses, defaults, and icon.
- `govi/UPSTREAM_README.md`: original Ghostty README.
- `govi/SCOPE.md`: what this macOS-only fork keeps and removes.

## Credits

Ghostty is distributed under the [MIT license](LICENSE). [JetBrains Mono](govi/Govi/Licenses/JetBrainsMono-OFL.txt) and [Geist](govi/Govi/Licenses/Geist-OFL.txt) are distributed under the SIL Open Font License. The theme collection comes from [iTerm2 Color Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes/releases/tag/release-20261102-150615-3d8a6a1), pinned to the November 2, 2026 release, with its [license](govi/Govi/Licenses/iTerm2-Color-Schemes-LICENSE.txt) included. The upstream updater and crash-reporting SDK are not included in Govi builds.
