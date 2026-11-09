# Govi build record

## November 9, 2026 — bounded subprocesses, file-event git refresh, cleanup

All subprocesses now go through `GoviLocalProcess` (deadline, output cap,
stderr modes, cancellation); git calls time out (15s local, 120s for push and
worktree creation). The `/usr/bin/security` read of Claude Code's sign-in was
removed; usage comes from `claude /usage` or a user-approved Keychain read.
Git state refreshes on FSEvents for the repository and its git directories;
the Changes panel/dock timers are 15s/30s fallbacks and hidden or minimized
windows skip refreshes. `GoviTasksView` and `GoviWorkbench` were split into
model, component, sidebar, dock and splash files, and Govi sources were
formatted with `swift-format` (`app/.swift-format`).

Verified: `./govi/build.sh`; `test-workflows.sh` (new runner and git checks),
`test-integrations.sh`, `test-remote.sh`, `test-layout.sh`, and the
agent-usage, recovery, hooks and palette Python suites. The usage and recovery
suites were missing `GoviRemoteModels.swift` and had been failing to compile.

**Not live-verified:** the rebuilt app was not launched. File-event refresh,
visibility pausing and the Keychain "Click to connect" path for Claude usage
need a hands-on check.

## November 7, 2026 — GitHub and Linear integration

Added the inline Tasks pane and Settings → Connections, GitHub CLI account
checking/sign-in guidance, and verified-before-save Linear personal keys in
Keychain. Tasks load issues and recent comments, preview editable agent briefs,
remember local checkout mappings, optionally create worktrees, and launch Claude
Code, Codex, Cursor or Pi. Issue links survive workspace restoration without
replaying prompts. GitHub PRs show checks/review decisions and can supply general
and inline feedback as a new task. Native actions create draft/regular PRs, post
comments and update Linear workflow status. No remote actions follow agent
completion automatically. See `INTEGRATIONS.md` for setup and current limits.

Verified:

- `./govi/build.sh`: native ReleaseFast app through `zig build`; assembled bundle
  at `app/dist/Govi.app` after the project moved into the app directory.
- `./govi/test-integrations.sh`: isolated GitHub CLI / Linear HTTP fixtures,
  URL and argument validation, old recovery compatibility, partial GraphQL and
  mutation failures, issue and PR data, inline feedback, private draft cleanup,
  literal shell quoting and local branch/upstream guards. No live accounts or
  remote writes used.
- `./govi/test-workflows.sh` and `./govi/test-remote.sh`: existing recovery,
  template, hook, shortcut and remote-host regressions passed after rebuilding
  relocated module caches.
- Project metadata validation and `codesign --verify --deep --strict` passed
  with access to the normal macOS compiler/credential caches.

The separate `dev.govi.terminal.integration-review` copy launched. Native
accessibility inspection repeatedly timed out, so layout, keyboard/mouse behavior
and interactive account setup are **not live-verified**. A short process sample
showed the main thread waiting normally in AppKit's event loop. The disposable
review process was stopped after checking. Real GitHub/Linear authentication,
permissions, issue loading and mutation acceptance still need account-based
verification. This is a local signed build, not a published release.

The project move left absolute paths in generated Zig and Swift caches. Old
caches were set aside and regenerated; integration sources and existing app
changes were retained under `app/`.

## November 7, 2026 — menus, Settings window and quadrant snapping

Notifications now use the same floating glass menu treatment as the **+** launcher,
with compact attention rows, acknowledgement and Open Next. Escape, an outside
click or losing window focus dismisses it. Settings uses one independent,
resizable native window with a saved frame and retained selected section; it
supports native close controls and `Cmd+W`. The permanent center search bar was
removed; terminal search remains available through its shortcut.

Pane titles and sidebar terminals can be dragged toward workspace halves or
corners. One workspace-wide drop target previews the resulting bounds with a
subtle tint/border; a center drop swaps terminals. Corners require three or more
terminals; two-terminal layouts use halves. Existing terminal views and processes
are retained, including transfers between workspaces.

Verification passed:

- `./govi/build.sh`: ReleaseFast, native Apple Silicon, through `zig build`.
- `./govi/test-layout.sh`: all 406 checks, including every source terminal in an
  eight-pane nested layout snapping to each half/quadrant, exact preview geometry,
  identity retention, cross-tree insertion and two-pane corner fallback.
- Swift syntax, project metadata, `git diff --check`, and
  `codesign --verify --deep --strict dist/Govi.app`.

Native UI checks used a separate **Govi UI Review** bundle identity, preferences
and recovery checkpoint with disposable nonpersistent shells. Verified the empty
and populated notifications menu, Escape dismissal, a background bell reaching
the menu, selecting its row focusing the correct terminal and clearing the badge,
and the missing center search bar. Verified Settings as a standard independent
window, returning to a terminal while Settings remained open, reopening the same
window, retaining its selected section, and `Cmd+W` closing Settings without
closing terminals. The first check exposed the missing close shortcut; the fix
was rebuilt and verified live. The disposable review app was quit after checking.

Remaining acceptance: the interface tool did not successfully complete pointer
drags from either pane headers or sidebar rows (coordinate clicks were also
ineffective). Actual drag initiation, hover highlighting, drop delivery and
cross-window dragging therefore still need a hands-on check. The layout and
preview geometry checks do not establish native drag-and-drop behavior.

## November 6, 2026 — recovery, templates, attention queue and usability

Implemented atomic metadata-only workspace checkpoints alongside native macOS
restoration, confirmed persistent-session connections, guided helper discovery,
explicit keep/end controls, and manual Claude/Codex session pickers after recovery.
Recovery never replays startup commands. Templates preserve split ratios, terminal
names, folders, commands, tools, agent choices and task labels, and always create
fresh terminal IDs. The attention queue prioritizes input requests, errors and
completion, includes project/branch and available elapsed time, and supports
opening the next item or marking it seen. Optional per-session Claude hooks add
explicit status signals without changing permission decisions or startup files.

The smaller changes standardize workspace/terminal/project labels, add shortcut
recording with conflict checks and live menu/hint updates, disable the launch
animation by default, expose a quiet Graphite preset, and provide installation,
executable-location and recheck actions for missing agents.

Build: `./govi/build.sh` passes through `zig build`, ReleaseFast, native Apple
Silicon. The local bundle is `dist/Govi.app`; this is not a notarized release.

Automated verification passed:

- `./govi/test-workflows.sh`: workspace/template serialization, fresh IDs,
  malformed/duplicate layout rejection, shell quoting, bounded helper timeouts
  (including continuous output), explicit status transitions, duplicate-hook
  acknowledgement, event validation and shortcut conflicts.
- `python3 govi/test-recovery.py`: production reconnect script, abrupt attach
  process-group loss, program survival, reattach/output replay, missing-session
  recovery, helper failure, and literal paths. Only disposable test sessions are
  created and removed; the helper server and existing sessions are not stopped.
- `python3 govi/test-hooks.py`: all five local statuses, JSON escaping, ignored
  hook stdin, invalid events, missing socket and silent failure. No agent or
  inference task is started.
- The built terminal engine accepts generated shortcut settings, including
  supported punctuation/special keys, through `+validate-config`.
- `./govi/test-layout.sh`: all 323 pane movement/identity checks.
- `python3 govi/test-palette.py`: all 43,008 contrast checks.
- `python3 govi/test-agent-usage.py`: existing provider/parser/backoff fixtures.
- Project metadata, hook/launcher shell syntax, `git diff --check`, and the final
  app bundle signature (`codesign --verify --deep --strict`).

Native app checks used a separately signed **Govi Review** copy, its own bundle
identity/preferences and separate recovery checkpoint. The user's running Govi
was not restarted. Verified creating/saving/opening a two-pane template with
terminal names intact; recording a shortcut and using the replacement while the
old shortcut no longer opens workspaces; missing-agent guidance; quiet preset;
synthetic hook events reaching the queue with elapsed time; and Open Next focusing
the selected pane after sheet dismissal. A five-terminal layout restored after a
real quit/relaunch without duplicates. A new persistent terminal reconnected
with earlier output intact after quit/relaunch, even with persistence for new
terminals switched off. Closing its workspace detached it successfully.

The attention-sheet check found and corrected focus being restored to the old
pane; the correction was verified live. The idle persistent-prompt check found
that shell integration reports `process_alive=false` while its persistent shell
is still live; terminal-close routing now checks the confirmed persistent process
and offers the keep/end choice. The Mac locked during the final confirmation
check, so that last dialog interaction remains pending. The disposable GUI recovery
session was identified by its review-profile UUID and unique output marker,
then ended and removed without stopping existing sessions. The separate review
app remains open until the Mac is unlocked.

Remaining acceptance: a real macOS restart, hard application crash/sleep-wake,
provider-generated Claude hook events, and broad shell-plugin compatibility.
Recovery uses the installed herdr-core rather than bundling it. Resume pickers
currently cover Claude Code and Codex. The explicit hook helper uses a private
same-user local socket; other agents continue using terminal signals.

References for per-session Claude hooks and settings merge behavior:
https://code.claude.com/docs/en/hooks and
https://code.claude.com/docs/en/settings .

## November 5, 2026 — herdr-core persistent sessions (prototype)

`./govi/build.sh` completed successfully. `GoviPersistence.swift` wraps new panes
in `hc` terminals (`hc` 0.1.18, user-installed) when the setting is on; it's off by default.
Checked outside the app with the same wrapper script in a pseudo-terminal:

- the program kept running after the attach client was killed;
- reattaching replayed the earlier output;
- Ghostty's zsh integration loaded inside the `hc` shell;
- `hc attach` passes OSC 0/7/9/9;4/777 and the bell through unchanged.

Not checked: the app itself, restoration after a real quit, inline suggestions
over the stable socket link, splits/moves, and pane-close cleanup.

## November 5, 2026 — agent status and agent worktrees

`./govi/build.sh` completed successfully (ReleaseFast, native Apple Silicon).
This revision adds `GoviActivity.swift` (session status tracking, Dock badge,
notifications, Settings → Agents) and the worktree option in the agent launcher.
The app wasn't launched, and no interactive checks were run. Status detection
heuristics, notifications and worktree creation are untested at runtime.

## November 4, 2026 — GUI appearance and workspace revision

`./govi/build.sh` completed successfully through `zig build` with ReleaseFast
optimization and the native Apple Silicon target. The local app is at
`dist/Govi.app`, with an ad-hoc signature applied by the build wrapper.

The app bundles all 890 themes from the iTerm2 Color Schemes release
`release-20261102-150615-3d8a6a1`, in addition to eight Govi presets.

No automated tests or interactive UI checks were run for this revision, at the
user's request. The app was not launched or restarted, and existing sessions
were left running. Build success does not establish runtime behavior for the
traffic lights, workspace switching, settings, or pane interactions.

## November 4, 2026 — macOS-only cleanup

`./govi/build.sh` completed successfully with ReleaseFast optimization and the
native Apple Silicon target after removing the unused product features and
platform app targets. `dist/Govi.app` is approximately 21 MB, compared with
35 MB before this cleanup. No Sparkle framework is present in the bundle.
The Ghostty MIT notice, font licenses, theme license and all 890 themes remain.

Source and resources went from 1,353 files / 58.6 MB to approximately
1,069 files / 40.7 MB (including local non-ignored files, using decimal bytes).
The source snapshot path is recorded in `SCOPE.md`.

`./govi/clean.sh --deep` removed regenerated build products, dependencies and
the compiler after the successful build. The checkout is now approximately
93 MB including Git history and the finished app, compared with roughly
2.6 GB at the start. Build tooling can restore its pinned compiler and
packages on demand. The compiler bootstrap's shell syntax was checked and its
download checksums were taken from ziglang.org's official download index;
the fresh-download bootstrap path was not exercised in this revision.

Project metadata and menu XML parse, and `git diff --check` is clean. No
terminal, engine, automated UI or interactive app tests were run for this
revision, at the user's request. No running sessions were closed or restarted.

## November 4, 2026 — first AI pass

`./govi/build.sh` completed successfully through `zig build`, using ReleaseFast
and the native Apple Silicon target. `dist/Govi.app` is approximately 22 MiB,
ad-hoc signed by the wrapper. The fresh compiler bootstrap downloaded Zig 0.14.1
from ziglang.org and passed its pinned SHA-256 verification during this build.

This build adds the pane-specific Ask Govi panel, Codex app-server, signed-in
Claude Code print mode, Cursor ACP, local command-composer suggestions and
optional user-key Jev ranking. It bundles no model or agent runtime. The small
new C API reads shell-integration prompt state before explicit insertion.

The installed Codex CLI generated its version-specific JSON schemas without
starting an inference session; the request fields were checked against those
schemas. Installed agent help confirmed the used CLI options, including Cursor's
hidden ACP command. Provider and TypeSafe protocol/authentication documentation
was consulted. Swift syntax and project metadata parse, and `git diff --check`
is clean. No automated tests, interactive UI checks, sign-in attempts, provider
model requests, Jev requests or key verification calls were made, at the user's
request. Streaming, cancellation, native history continuation, prompt insertion
and optional hosted ranking still require the user's live testing. No running
Govi sessions were closed or restarted.

After compilation, `./govi/clean.sh --deep` reclaimed approximately 1.76 GiB
of generated compiler, dependency and build files. The checkout is approximately
95 MiB including Git history and the finished app. All AI sources remain; the
next build restores its pinned toolchain and dependencies on demand.

## November 5, 2026 — terminal inline suggestions

Replaced the rejected chat panel and separate command composer with zsh inline
suggestions. Chat views, agent child-process adapters, sparkle buttons, Explain
menus and the Ask Govi shortcut were removed from source and the build. The
temporary prompt-state C API was removed; the terminal engine needs no new API.

The bundled zsh integration uses the real ZLE BUFFER/CURSOR and display-only
POSTDISPLAY. A private user-scoped local socket supplies bounded candidates.
Input generations and exact prefix/suffix checks reject stale replies. Tab
accepts the visible suffix without Return; otherwise the original completion
widget runs. Suggestions hide during mid-line edits, selections, history search
and continuation prompts. Editor connections close before programs execute.
Settings controls local suggestions and optional user-key Jev ranking.

`./govi/build.sh` completed through `zig build` with ReleaseFast optimization
and the native Apple Silicon target. The ad-hoc signed app is `dist/Govi.app`
(approximately 21 MiB). Swift and zsh syntax checks and project metadata parsing
passed. The app's bundled suggestion script matches the source.

No automated tests, interactive terminal/UI tests, agent/model calls or Jev
requests were run, per the user's instruction to leave testing to them. Build
and syntax checks do not prove live ZLE hook ordering, ghost-text rendering,
Tab behavior, plugin compatibility, private-socket interaction or hosted ranking.
Quit/reopen the rebuilt app and create a new zsh terminal to load the integration.
Existing running Govi sessions were not closed or restarted by this work.

## November 5, 2026 — floating sidebar follow-up

Built successfully with `./govi/build.sh` (ReleaseFast, native target), including
availability-gated macOS 26 regular Liquid Glass. Older macOS versions use native
sidebar translucency; Reduce Transparency / Increased Contrast use an opaque
system background. Sidebar text uses semantic system colors across terminal themes.

Removed terminal pane headers. Session rows now expose close, split, zoom/restore,
rename and Finder actions. The sidebar toggle has a dedicated native first-click
hit target outside the window drag region and explicitly exits focus mode to show
navigation. Existing close confirmation is retained through `close_surface`.

The prior build's toggle reopened during inspection, so the reported intermittent
failure was not conclusively reproduced. The rebuilt artifact compiled; isolated
preview UI inspection timed out, so final glass rendering and repeated toggle
interaction still need live verification. The user's running app was not restarted.

## November 5, 2026 — theme-adaptive chrome

Added a shared environment palette derived from the terminal theme's background
and foreground, with linear-sRGB contrast measurement and UI-only correction.
Follow Terminal Theme / Light / Dark affects chrome only. Bundled Ghostty files
continue loading directly, including their cursor, selection and ANSI colors.
Theme/appearance/accessibility changes propagate through the view environment
without changing terminal surface identities. Sidebar height follows its content;
terminal sheets use their original background without a rounded card contour.

`python3 govi/test-palette.py` passed 43,008 contrast checks across 890 bundled
themes and six edge palettes, in three appearance modes with normal/increased
contrast. Text is checked against canvas, panel, hover and selected surfaces at
4.5:1 normally and 7:1 with Increased Contrast. `./govi/test-layout.sh` passed all
323 pane identity/movement checks. These are algorithmic checks, not visual
WindowServer validation of the optical glass compositor. Running sessions were
not restarted for this revision.

## November 5, 2026 — agent launcher, wordmark, and usage

`./govi/build.sh` passed with all six provider vector assets and the supplied
Govi wordmark. The wordmark renders as a theme-tinted mask at icon height.
The plus popover detects installed CLI executables through the login-shell PATH
and conventional install locations. Launches open a fresh native terminal at the
focused directory; exiting the agent returns to a login shell. Missing executables
are disabled. No agents were installed or invoked during verification.

The Usage popover reads Claude, Codex, Cursor, Grok and OpenCode quotas using
existing local credentials and provider-owned endpoints, following the CodeNotch
reference linked in `Govi/Brand/SOURCES.md`. Pi has no aggregate usage endpoint.
Reads use ephemeral HTTP sessions, reject redirects, do not write credentials,
respect server backoff, and retain clearly marked last-successful readings on
errors. Polling begins after opening Usage. Keychain prompts require Connect;
background reads disallow interaction. Expired sign-ins must be renewed in the CLI.

`python3 govi/test-agent-usage.py` passed production-parser fixtures for all five
providers, absent/malformed data, reset timestamps, division-by-zero guards and
four shell-metacharacter path round trips. `git diff --check` passed. Live account
requests, launcher interaction, and new-build visual inspection were not performed.
Running user sessions were not restarted.

## November 6, 2026 — remaining limits and Claude recovery

Usage rings, hover percentages and accessibility values now show remaining
capacity. The outer ring follows the primary/session window and the inner ring
shows the secondary/weekly window. Additional windows stay in the tooltip and
cannot replace the primary value. Grok uses the server's weekly/monthly period
label. Accounts with refresh errors stay visible with connection guidance;
transient failures retain a clearly marked last reading.

Claude first asks the installed CLI's built-in `/usage` command in print mode.
This recovered a reading when the saved Keychain access token was expired.
Hooks, settings from projects, tools, MCP servers and session persistence are
disabled for that command. The process has a timeout and automatic polling is
limited to once every five minutes. Clicking a ring refreshes immediately while
still respecting a server-imposed backoff. OAuth remains a fallback when the CLI
cannot report quotas; Govi does not refresh or write another app's credentials.

`python3 govi/test-agent-usage.py` passed provider fixtures, the reported Codex
9%-used → 91%-remaining / 100%-secondary case, primary/secondary ordering,
over-limit clamping, Claude CLI output and timezone/year-boundary resets,
unavailable/stale states, backoff and literal shell paths. A fake CLI verifies
that `/usage` reaches the command as a positional argument and that startup
disables tools, hooks, MCP servers and transcript persistence.

Live checks of the production reader returned Codex 91% primary and 90%
secondary, Grok 48% weekly, and Claude 100% session and 61% weekly remaining.
These were verification-time readings; they change as the accounts are used.
Only percentages and reset times were printed, never credentials or raw account
responses. No model request was made by the usage checks.

`./govi/build.sh` passed and produced `dist/Govi.app`. Running terminal sessions
were not restarted. The updated bar has not been manually exercised in the
running app.

The follow-up standardization adds a visible `left` caption to every hovered
percentage. Tooltip headings say `Quota remaining`, and tooltip/accessibility
values share the same `% left` description across all providers. The existing
remaining-capacity calculation and ring fill apply uniformly: 100% is a full
allowance and 0% is exhausted. Production ring views rendered with representative
Claude, Codex and Grok readings were visually inspected at their actual 29-point
size. `python3 govi/test-agent-usage.py` and `./govi/build.sh` passed again.
