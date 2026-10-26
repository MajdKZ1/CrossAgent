# CrossAgent v0.1 spec

## Stack

- Swift 5.9+, SwiftUI app for macOS 14+, Apple Silicon.
- SwiftTerm (Swift Package, https://github.com/migueldeicaza/SwiftTerm) for terminals.
  Use `LocalProcessTerminalView` to spawn each pane's process in a real PTY.
- System `/usr/bin/ssh` for remote panes (inherits ~/.ssh/config, so `pc` alias works).
- tmux on each host for persistent sessions.
- Build with Swift Package Manager. If Xcode is installed, an Xcode project is fine too,
  but `swift build` plus `scripts/bundle.sh` (makes `CrossAgent.app`) must always work.

## Hosts config

`~/.config/crossagent/hosts.json`, created with defaults on first launch:

```json
{"hosts": [
  {"id": "mac", "name": "This Mac", "type": "local", "accent": "#6ea8fe"},
  {"id": "pc",  "name": "Linux PC", "type": "ssh", "target": "pc", "accent": "#5fd39a"}
]}
```

## What each pane runs

Session name: `ca-<hostId>-<n>`, validated `[A-Za-z0-9_-]{1,40}`.

Script (claude mode):
`if command -v tmux >/dev/null 2>&1; then exec tmux new -A -s SESSION claude; else exec claude; fi`

Script (shell mode):
`if command -v tmux >/dev/null 2>&1; then exec tmux new -A -s SESSION; else exec "$SHELL" -l; fi`

- local: `$SHELL -lc SCRIPT` (login shell so PATH has claude)
- ssh: `/usr/bin/ssh -tt -o ServerAliveInterval=15 -o ServerAliveCountMax=3 TARGET 'exec $SHELL -lc <quoted SCRIPT>'`

Env: TERM=xterm-256color, COLORTERM=truecolor.
Closing a pane ends the ssh/client process only. tmux session keeps running.
"Kill session" is a separate explicit action (runs `tmux kill-session -t SESSION` on that host).

## UI

- Single window, dark, minimal. Background #0b0c0f, panes #0f1115, 1px borders rgba(255,255,255,0.07), 10px radius, 6px gaps.
- Top bar: "CrossAgent" wordmark, host chips with pane counts, "New pane" button, broadcast toggle.
- New pane popover: pick host, mode (Claude / Shell), optional session name, Enter to create.
- Pane grid auto layout: 1 full, 2 side by side, 3-4 as 2x2, 5-6 as 3x2.
- Pane header (28px): host accent dot (amber while connecting, grey when exited), host name, mode badge, session name muted, buttons: relay, reconnect, close. Double click header to maximize / restore.
- Focused pane gets its host accent border.
- Exited pane shows "Session ended" overlay with Reconnect (reattaches the same tmux session).
- Font: JetBrains Mono if installed, else SF Mono / Menlo, 13pt.

## Cross agent features (keep simple)

- Broadcast: when on, keystrokes in the focused pane go to every live pane. Thin accent bar at top when on.
- Relay: send the selected text in the focused pane to another pane you pick (no Enter appended).
- Layout persists (UserDefaults): list of {hostId, mode, session}. On relaunch panes reopen and reattach tmux.

## Shortcuts

- Cmd+T new pane (last used host), Cmd+W close pane, Cmd+Shift+[ / ] move focus, Cmd+Enter maximize/restore,
  Cmd+Shift+B broadcast, Cmd+Shift+R relay, Cmd+1..9 focus pane.

## Milestones

- M0 Environment check: swift, Xcode or not, `ssh pc` works non-interactively, tmux and claude present on both hosts (install tmux on pc if missing; on Mac via brew if missing). Write findings to docs/DECISIONS.md.
- M1 Single window, one local shell pane via SwiftTerm. Builds and runs.
- M2 Hosts config + ssh pane to pc running claude inside tmux. Close and reopen reattaches.
- M3 Pane grid, new pane popover, close, focus, maximize, shortcuts.
- M4 Broadcast and relay.
- M5 Polish: styling per spec, exited overlay + reconnect, layout persistence, `scripts/bundle.sh` makes CrossAgent.app, README with install and usage.

## v0.1 acceptance criteria

1. `swift build -c release && scripts/bundle.sh` produces a launchable CrossAgent.app.
2. Can open at least 2 panes on Mac and 2 on pc at once, all running claude, all usable.
3. Quitting the app and relaunching reattaches all 4 tmux sessions with their history.
4. Broadcast types into all panes, relay moves selected text between a Mac pane and a pc pane.
5. Resizing the window reflows panes and the remote claude TUI redraws correctly.
6. No crashes in a 10 minute session of normal use. Feels instant.
