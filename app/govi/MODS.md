# Mods

A mod adds things to Govi: panes, commands in the command palette, keyboard
shortcuts, programs that run when something happens, and handlers for links
clicked in a terminal. A mod is a folder with a `mod.json` file. It can be
written in any language, and a pane's interface is an ordinary web page.

Mods are your own code. Nothing in a mod runs until you turn it on, and after
that its programs run as you, with the same access as anything you start in a
terminal. Govi does not sandbox or review mods. Read a mod before turning it on.

## Quick start

```sh
govi mod new "My Mod"        # writes a small working mod
govi mod enable my-mod       # Govi asks you to confirm
govi mod open my-mod/main    # opens its pane beside this one
```

Or use **Settings › Mods › New Mod…**, which also turns it on.

The new folder is in `~/Library/Application Support/Govi/Mods/my-mod`
(`govi mod dir` prints the Mods folder). Edit the files there: Govi reloads a
mod when its files change. If an edit breaks `mod.json`, Govi keeps using the
last version that worked and shows the problem in Settings › Mods.

To work on a mod that lives in a repository elsewhere, link it instead of
copying it:

```sh
govi mod link path/to/my-mod
```

A complete example is in
[`examples/mods/android-emulator`](examples/mods/android-emulator): an Android
emulator in a pane, with logcat beside it.

## mod.json

```json
{
  "id": "my-mod",
  "name": "My Mod",
  "version": "0.1.0",
  "description": "What it does, in a sentence.",
  "minGoviVersion": "0.1",
  "panes": [
    { "id": "main", "title": "My Mod", "icon": "puzzlepiece.extension", "page": "ui/index.html" },
    { "id": "logs", "title": "Logs", "command": ["tail", "-f", "/tmp/my.log"] }
  ],
  "commands": [
    { "id": "open", "title": "Open My Mod", "shortcut": "cmd+alt+m", "pane": "main" },
    { "id": "sync", "title": "Sync Now", "description": "Fetch the latest data.", "run": ["./sync.sh"] }
  ],
  "events": [{ "on": "agent.state", "run": ["./on-agent.sh"] }],
  "links": [{ "pattern": "^https://linear\\.app/.+/issue/", "command": "open" }],
  "service": { "run": ["node", "server.js"] }
}
```

Only `id` and `name` are required.

| Field | Meaning |
| --- | --- |
| `id` | Lowercase letters, digits, dots, dashes and underscores. Must be unique among your mods. |
| `name`, `version`, `description` | Shown in Settings and the command palette. |
| `minGoviVersion` | Govi refuses to load the mod on an older version. |
| `panes` | Panes the mod can open. Each has exactly one of `page`, `url` or `command`. |
| `commands` | Command palette entries. Each has exactly one of `pane` (open that pane) or `run` (start a program). |
| `events` | Programs to run when something happens. See [Events](#events). |
| `links` | Regular expressions for links Command-clicked in a terminal. The first match runs the named command. |
| `service` | One program kept running while the mod is on. |

Programs are lists of arguments, not shell text. They run with the mod's
folder as the working directory, so `./sync.sh` is a file in the mod. Use
`["sh", "-c", "…"]` when you want a shell.

Ids of panes and commands use lowercase letters, digits, dashes and
underscores. `icon` is an [SF Symbol](https://developer.apple.com/sf-symbols/)
name.

### Shortcuts

Write shortcuts as `cmd+shift+e`. Modifiers are `cmd`, `ctrl`, `alt` and
`shift`; a shortcut needs `cmd` or `ctrl`. Keys are a letter, a digit, or a
name such as `enter`, `space`, `comma` or `arrow_left`. Govi's own shortcuts
win: if a combination is already used by Govi, the mod's shortcut does nothing
and the command stays available in the palette.

## Panes

### Web panes

`"page": "ui/index.html"` shows a page from the mod's folder. The page can
load other files from the folder with relative addresses, and nothing outside
it. `"url": "http://localhost:8080"` shows an address instead, for a mod whose
service runs its own web server; Govi retries for a few seconds while the
server starts.

A web pane stays on its page. Links to other sites open in a browser pane.

The page gets a `govi` object:

| | |
| --- | --- |
| `govi.call(method, params)` | Calls a control method and resolves with its result. These are the methods behind the `govi` command: `panes.list`, `pane.split`, `pane.focus`, `pane.close`, `terminal.send`, `terminal.read`, `browser.open`, `mod.open` and the rest. `govi hello --json` lists them. |
| `govi.exec(argv, options)` | Runs a program on this Mac and resolves with `{ status, output, errors, timedOut }`. Options: `cwd` (default: the mod's folder), `env`, `timeout` in seconds (default 30, at most 300) and `limit` in bytes of output (default 1 MB, at most 16 MB). |
| `govi.on(event, listener)` | Listens for an [event](#events), or `"theme"` and `"focus"`. `"*"` receives every event as `(name, data)`. Returns a function that stops listening. |
| `govi.theme` | `{ dark, background, foreground, muted, border, accent, sidebar }`, colours as `#RRGGBB`. |
| `govi.pane` | `{ id, mod, pane, directory, root, data, context }`. `directory` is the folder of the pane this one was opened beside, `root` the mod's folder, `data` the mod's data folder, and `context` what opened the pane (for a link handler, `{ link }`). |
| `govi.setTitle(text)` | Sets the pane's title. |
| `govi.getState()` / `govi.setState(value)` | A small JSON value (up to 64 KB) saved with the window layout, so the pane comes back as it was after a relaunch. |

```html
<script type="module">
  document.body.style.background = govi.theme.background;
  const result = await govi.exec(["git", "status", "--short"], { cwd: govi.pane.directory });
  await govi.call("terminal.send", { text: "npm test", enter: true });
</script>
```

Only the mod's own page gets `govi`. With `url`, the address must be on this
Mac (`localhost` or `127.0.0.1`) for the page to get it; a page on the
internet is shown without it.

To debug a page, right-click it and choose Inspect Element.

### Terminal panes

`"command": ["htop"]` runs a program in a terminal pane. It starts in the
folder of the pane it was opened beside, through your login shell, and the
pane stays open with a shell when the program ends.

## What programs get

Commands, event hooks, the service and `govi.exec` all get these variables:

| Variable | |
| --- | --- |
| `GOVI_MOD_ID` | The mod's id. |
| `GOVI_MOD_ROOT` | The mod's folder. |
| `GOVI_MOD_DATA` | A folder for the mod's own data. Keep databases, caches and credentials here, not in the mod's folder: files changing there make Govi reload the mod. |
| `GOVI_SESSION_ID` | The focused pane, so `govi` commands act on it by default. |
| `GOVI_CONTROL_SOCKET` | Where the `govi` command connects. |
| `PATH` | Your login shell's `PATH`, with the `govi` command first. |

A command also gets `GOVI_MOD_COMMAND`, and `GOVI_LINK` plus
`GOVI_CONTEXT_JSON` when a link handler started it. An event hook gets
`GOVI_EVENT` and `GOVI_EVENT_JSON`.

A command or hook has 60 seconds to finish; what it prints, and how it ended,
appears under Details in Settings › Mods. For anything longer, open a terminal
pane (`govi split -- long-task`) or use the service.

The service is started when the mod is turned on and stopped when it is turned
off or Govi quits. Its standard input closes if Govi exits unexpectedly, so a
service can watch for that. It is not restarted if it exits; Restart in
Settings › Mods, or `govi mod reload my-mod`, starts it again.

## Events

| Event | When | Data |
| --- | --- | --- |
| `mod.loaded` | The mod is turned on, Govi starts, or its `mod.json` changes. | `mod`, `version` |
| `pane.opened` | A pane opens. | `pane`, `kind`, `title`, `directory` |
| `pane.closed` | A pane closes. | `pane`, `kind`, `title`, `directory` |
| `pane.focused` | Focus moves to a pane. | `pane`, `kind`, `title`, `directory` |
| `agent.state` | An agent's status changes. | `pane`, `state` (`working`, `needsInput`, `done`, `error` or `idle`), `agent`, `label`, `project`, `branch` |

`kind` is `terminal`, `browser`, `editor` or `mod`.

```sh
#!/bin/sh
# on-agent.sh: say so when an agent is waiting for an answer.
state=$(printf '%s' "$GOVI_EVENT_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
[ "$state" = needsInput ] && say "An agent needs you"
```

## The `govi mod` command

```
govi mod list                      Installed mods, and what each adds
govi mod new NAME                  Create a small working mod to edit
govi mod enable ID | disable ID    Turn a mod on (Govi asks first) or off
govi mod open MOD[/PANE] [--down] [--focus]
govi mod run MOD/COMMAND
govi mod reload [ID]               Read mod.json files again; with ID, restart that mod
govi mod install OWNER/REPO|URL    Download a mod with git (it stays off until enabled)
govi mod link [FOLDER]             Add a folder you're developing in as a mod
govi mod dir                       Print the Mods directory
```

## Sharing a mod

Put the mod in a git repository with `mod.json` at the top. Anyone can then
install it with `govi mod install owner/repo` (GitHub) or a full git address.
It arrives turned off. To update an installed mod, run `git pull` in its
folder; to remove one, turn it off and delete its folder.

## Limits

- A mod can't change Govi's own interface (the sidebar, title bars, settings);
  it adds panes and commands beside it.
- Web panes are the only custom interface. There are no native views.
- Up to 32 panes, 64 commands, 32 event hooks and 16 link handlers per mod,
  and eight of a mod's programs running at once.
