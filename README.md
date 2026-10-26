# CrossAgent

One window, every workstation. CrossAgent is a native macOS app that puts Claude Code (or a plain shell) on your Mac and on your Linux box side by side, in one grid of terminal panes. Remote panes go over plain `ssh`, and every pane lives in tmux on its own host, so closing the window never kills your work. Open it again and everything reattaches.

It also comes with a viewing station that shows every session on both machines at once, and a Claude Code skill that splits work across the two machines for you.

## What you need

- A Mac on macOS 14+ (Apple Silicon), with Xcode or the Swift toolchain.
- tmux on the Mac (`brew install tmux`).
- A Linux box you can reach with a plain `ssh <alias>`, ideally with key auth, plus tmux and Claude Code on it. No server or agent to install, CrossAgent just runs `ssh`.
- Claude Code on both machines if you want Claude panes.

## Install

```sh
git clone <this repo> CrossAgent && cd CrossAgent
swift build -c release && scripts/bundle.sh
open build/CrossAgent.app        # or drag it into /Applications
```

On first launch it writes `~/.config/crossagent/hosts.json`:

```json
{"hosts": [
  {"id": "mac", "name": "This Mac", "type": "local", "accent": "#6ea8fe"},
  {"id": "pc",  "name": "Linux PC", "type": "ssh", "target": "pc", "accent": "#5fd39a"}
]}
```

`target` is anything `ssh` understands, usually a `Host` alias from `~/.ssh/config`. Add more hosts if you have them.

## Using it

- Hit `Cmd+T`, pick a host and Claude or Shell, press Enter. The pane opens right away and goes live once the host answers.
- Each pane runs in a tmux session named `ca-<host>-<n>` on that host. Close a pane and the session keeps running. Kill it for real with Option+click on the close button, or right click the header and pick Kill Session.
- Quit the app and relaunch: every pane comes back attached to the same tmux session, history and all.
- If a session ends, the pane says so and gives you a Reconnect button.
- Double click a pane header (or `Cmd+Enter`) to maximize it.

### Broadcast and relay

- **Broadcast** (`Cmd+Shift+B`): what you type in the focused pane goes to every live pane. A thin accent bar at the top tells you it's on.
- **Relay** (`Cmd+Shift+R`): select text in one pane and send it to another, say a stack trace from a Mac pane into Claude on the PC. It's pasted without hitting Enter, so you can add to it first.

### Viewing station

`Cmd+Shift+V` or the Station button in the top bar. It's a wall of every `ca-*` tmux session on every host, live:

- a small live preview of each session's screen
- host, session name, and how long it's been running
- status: running, idle, needs input (Claude is waiting on a prompt), or exited

It also picks up `ca-*` sessions you didn't open from this window, like ones the skill started or ones you made by hand. Click any tile (or arrow to it and press Enter) to jump in full size. Esc goes back. Claude Code processes running outside tmux show in a strip at the bottom so you know they exist, but you can't attach to them.

## Shortcuts

| Keys | What it does |
| --- | --- |
| `Cmd+T` | New pane (last used host preselected, Enter to open) |
| `Cmd+W` | Close focused pane (the tmux session keeps running) |
| `Cmd+Shift+[` / `Cmd+Shift+]` | Previous / next pane |
| `Cmd+1` ... `Cmd+9` | Focus pane by number |
| `Cmd+Enter` | Maximize / restore |
| `Cmd+Shift+B` | Broadcast on / off |
| `Cmd+Shift+R` | Relay selection to another pane |
| `Cmd+Shift+V` | Viewing station |

They all work while a terminal has focus.

## The crossagent skill

`skills/crossagent` is a Claude Code skill that spreads work across both machines. Install it on both:

```sh
skills/crossagent/install.sh          # copies to ~/.claude/skills/crossagent on the Mac and on the PC
skills/crossagent/install.sh --mac    # or just one side (--pc)
```

Then inside any project, ask Claude Code to use it ("use crossagent to run the tests on my pc and build locally", or just "/crossagent"). It will:

- drop a `CROSSAGENT.md` in the project and point the project's `CLAUDE.md` at it. That file holds the split rules: heavy builds, test suites, long runs, Linux and docker work go to the PC, while UI, Xcode, macOS stuff and quick edits stay on the Mac. Independent pieces run on both at once.
- map your machines into `~/.config/crossagent/system-map.md` (OS, CPU, RAM, disk, tools, paths, how to reach each, where the project lives on each), keep it in sync on both machines, and put a copy in `.crossagent/` (gitignored) in the project.
- sync the project to the PC with rsync (the Mac is the source of truth) and run each piece in a tmux session named `ca-<host>-<task>`. They show up in the viewing station on their own.

By default it splits across both machines. Name a machine to keep it on one:

- Mac only: "local", "mac", "this mac", "on my mac"
- PC only: "pc", "ssh", "overseas", "my pc", "on my pc"

Under the hood it's one script you can use yourself:

```sh
~/.claude/skills/crossagent/scripts/ca init
~/.claude/skills/crossagent/scripts/ca run pc tests -- make test
~/.claude/skills/crossagent/scripts/ca run mac build -- make build
~/.claude/skills/crossagent/scripts/ca run pc refactor --claude "split utils.py into modules"
~/.claude/skills/crossagent/scripts/ca wait pc tests mac build
~/.claude/skills/crossagent/scripts/ca status
```

`ca help` lists the rest.

## How it works

- SwiftUI app, one window. Terminals are [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `LocalProcessTerminalView`s, each running a real PTY.
- Local panes run `$SHELL -lc '<script>'`. Remote panes run `/usr/bin/ssh -tt <target> 'exec $SHELL -lc <script>'`, so your ssh config, keys and agent just work.
- The script is `tmux new -A -s <session> claude` (or a shell), falling back to plain `claude` if tmux is missing.
- ssh connections share one master per host (`ControlMaster`), so new panes skip the handshake.
- The station polls each host with one `tmux list-panes` plus `capture-pane` round trip, about every 1.5 s while it's open and every 10 s otherwise.

## Development

```sh
swift build && swift test
CROSSAGENT_AUTOMATION=1 .build/debug/CrossAgent    # dev hook, drive it with scripts/automation.sh
```

Design notes and judgment calls live in `docs/DECISIONS.md`, and the spec is in `docs/SPEC.md`.

## License

MIT
