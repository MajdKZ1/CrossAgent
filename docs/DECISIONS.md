# Decisions

Log of calls made during the build. Newest at the bottom.

- Native Swift + SwiftTerm over Tauri/Electron: lighter, faster, feels like a Mac app.
- System ssh + tmux instead of our own protocol: zero server install on the PC, sessions survive.

## M0 environment check (2026-10-27)

Mac (verified with sw_vers, sysctl, system_profiler, df):
- An Apple Silicon Mac, current macOS.
- zsh, git, Swift 6.4, Xcode installed, Homebrew present, claude 2.1.310 in ~/.local/bin.
- tmux was missing. Installed with `brew install tmux` (3.8).

PC (verified over `ssh pc` with uname, os-release, lscpu, free, df):
- An 8-core Ryzen Linux PC with an NVIDIA GPU, running a current Ubuntu.
- Login shell zsh, git 2.51, claude 2.1.303 in ~/.local/bin (only on PATH in a login shell, which the spec's `$SHELL -lc` already handles).
- `ssh pc` works non-interactively with BatchMode.
- tmux was missing and sudo needs a password. Calls: no root install. Ran `apt-get download` for tmux 3.5a and libevent-core, extracted them with `dpkg-deb -x` into ~/.local/lib/ca-tmux, and added a tiny ~/.local/bin/tmux wrapper that sets LD_LIBRARY_PATH to that dir. Works from login shells. Side effect: LD_LIBRARY_PATH (pointing at only that dir) is inherited inside tmux sessions, which is harmless. If the user later runs `sudo apt install tmux`, delete the wrapper and the dir.

## Build calls

- ssh connection sharing: every ssh call adds `ControlMaster=auto`, `ControlPath=/tmp/crossagent-%C`, `ControlPersist=10m` on top of the spec's keepalive options. A fresh connect to the PC takes 5 to 7 s through its tunnel, a multiplexed one about 0.9 s. Client side only, the PC config is untouched. The app also opens a master at launch so the first pc pane is quick.
- Pane scripts start with `export PATH="$HOME/.local/bin:$HOME/.claude/local:$PATH"; `. On the Mac a login non-interactive zsh does not have ~/.local/bin (it is added in .zshrc), so `claude` was not found. Rest of the script is exactly the spec's.
- SwiftTerm resolved to 1.99.x. It hides the raw Terminal, so screen text and bracketed paste state come from its snapshot APIs.
- Focus tracking: SwiftTerm's becomeFirstResponder is not open, so focus follows the window's first responder instead of a view override.
- Broadcast hooks `send(source:data:)` (open) on a LocalProcessTerminalView subclass and fans the bytes out with `process.send`, which skips the hook.
- Relay sends the selection as a bracketed paste when the receiving app enabled it, so multi line text does not submit early in Claude Code.
- Dev automation hook (`scripts/automation.sh`, off unless `CROSSAGENT_AUTOMATION=1`) lets the verifier drive real flows (open panes, type, relay, dump screen text) without clicking.

## Skill (skills/crossagent)

- One bash CLI (`scripts/ca`) does everything. The Mac is the hub: for PC work it rsyncs the project, then runs the PC's own copy of `ca` over ssh. On the PC the skill works PC only, since the PC can't reach the Mac.
- System map lives at `~/.config/crossagent/system-map.md` on both machines, regenerated from real probes and copied to the PC. A project copy goes to `<project>/.crossagent/system-map.md` (gitignored in the project) and CROSSAGENT.md points at it. Generated blocks are refreshed, the `## Notes` section is kept.
- PC project dir defaults to `~/crossagent/projects/<name>`, recorded in `.crossagent/project` and the map.
- `sync push` never deletes by default so a running PC worker's files survive. `.git` is pushed, heavy build dirs are not.
- Tasks stay open in a shell after finishing so the viewing station still shows them. Each run leaves an exit marker plus `.crossagent/results/<task>.md`.
- `ca wait` returns after 110 s at most (exit 124 means call again) so it fits in Claude Code's 2 minute Bash timeout.
- Claude workers run with `--permission-mode acceptEdits`, never bypass. A blocked prompt shows as waiting for input in the station.
- Docs tell Claude to call `ca` by its literal path, no shell variables, so a permission allowlist can match it.

## Blocked, then fixed

- (Fixed: the user logged in on the PC and installed tmux with apt, so the ~/.local wrapper from M0 is gone and `/usr/bin/tmux` 3.5a is used.)
- Claude Code on the PC had an expired login (`claude -p` says "OAuth session expired"). Its TUI still starts, so panes, tmux and the station work, but a Claude worker on the PC can't actually answer until the user runs `claude` then `/login` on the PC once. Needs a browser OAuth, so I left it for the user.

## After verification

- The tmux command gets `\; set -q status off \; set -sq focus-events on`. The pane header already names the session and tmux's green status bar clashed with the dark UI. Claude Code asks for focus-events. status is per session; focus-events is a server option, which is harmless for other sessions. Side effect: jumping into an outside ca-* session from the station also hides its status bar. Kept, it's ca-* sessions only.
- Station running dot pulses with Core Animation. The SwiftUI repeatForever pulse made the whole station re-render every frame (25% CPU with one running tile, about 2.5% now).
- A shell whose screen changes between polls counts as running, so loops in a shell show up right.
- If the monitor hasn't heard from a host yet, a new auto named pane asks the host for its sessions first, so `tmux new -A` never silently joins an existing `ca-<host>-1`.
- Mac Claude panes start in the home folder, so Claude asks to trust it the first time. Left as is, it's the user's call.

## App icon
- The icon is a static asset now (bridge design). Source PNGs live in `assets/icon/`, with the retina files renamed from `-2x` to `@2x` because iconutil only accepts `@2x`. `assets/AppIcon.icns` is built once with `iconutil -c icns assets/icon/CrossAgent.iconset -o assets/AppIcon.icns` and committed. `scripts/make-icon.swift` is gone and nothing in the build regenerates the icon. `bundle.sh` only copies it.
- Runtime Dock icon: `Sources/CrossAgent/Resources/AppIcon.icns` is a symlink to `assets/AppIcon.icns`. SwiftPM copies the real file into `CrossAgent_CrossAgent.bundle`, so there's one source of truth. The app loads it by hand instead of using `Bundle.module`, which traps if the bundle is missing. It shows under `swift run` too.
- Icon cache: after bundling I ran `touch` on the app and `lsregister -f` on it as a precaution. Finder and the Dock showed the new icon right away, so the Dock didn't need a restart. If an old icon ever sticks, run those two and then `killall Dock`.

## Live sync (Mutagen)
- Setup: Mutagen 0.18.1 from `mutagen-io/mutagen/mutagen` on the Mac, daemon registered as a login item (`mutagen daemon register`, LaunchAgent `io.mutagen.mutagen`). The first connect copied the agent to the PC as `~/.mutagen/agents/0.18.1/mutagen-agent`, same version as the Mac. No changes to the PC's SSH or security config.
- Tunnel quirks: Mutagen uses the system ssh, so the `pc` alias and its ProxyCommand just work. The first connect took about 48 s because it uploads the agent (around 10 MB) through the ssh tunnel. After that a session starts in a few seconds. Mutagen won't create the parent folder on the remote side (`unable to walk to transition root parent`), so `ca sync start` runs `mkdir -p` over ssh first. The tunnel's round trip is about 425 ms at best, and a plain `ssh pc true` over a ControlMaster takes about 0.9 s.
- Paths: the PC folder is the same path relative to home (`~/Projects/x` to `~/Projects/x`). A project outside home goes to `~/crossagent/projects/<name>`. `pc_dir=` in `.crossagent/project` still overrides, so older projects that had `crossagent/projects/<name>` written into their config keep it. `ca init` no longer writes `pc_dir`.
- Safety on start: if the PC folder isn't empty and has no `.crossagent/project` marker with this project's name, `ca sync start` refuses (`--force` merges, which is still two-way-safe). It also refuses to sync the home folder itself. The marker lives in `.crossagent/`, which never syncs, so each side keeps its own.
- Mode is `two-way-safe`, so conflicts are never auto resolved. `ca sync flush` exits 3 on conflicts, and `ca run` and `ca wait` stop instead of handing off. Resolving means deleting the losing side's copy. `ca sync conflicts` prints both sides' size, time, a short diff for small text files, and the exact rm command for each choice. It never runs those itself.
- Symlinks: `portable` rather than `posix-raw`. Relative links inside the project sync. Absolute links or links that leave the root are skipped and reported ("skipped on mac: link-abs (invalid symbolic link: target is absolute)"). posix-raw would copy Mac-only absolute targets to the PC verbatim.
- Permissions: `portable` mode keeps the executable bit. New files default to 0644 and folders to 0755, instead of Mutagen's 0600/0700, so the PC user's tools can read them normally.
- Ignores: `--ignore-vcs` plus `.build build DerivedData node_modules target dist .venv venv __pycache__ .DS_Store .crossagent/ *.log`. Secrets: `.env .env.* *.pem *.key id_*`. Opting in is `sync_allow=a,b` in `.crossagent/project`, which adds `!pattern` (tested with `.env.prod`). `sync_ignore=` adds more ignores. `id_*` also catches files like `id_map.py`; `sync_allow=id_map.py` fixes that. I kept it because it's the safe side.
- Rule changes: the session carries a label `ca-cfg=<hash of rules and paths>`. `ca sync start` recreates the session if the hash changed and otherwise just resumes it, so running it twice is a no-op. Recreating keeps the files, and a fresh session with differing files flags conflicts instead of picking a side.
- Map: the projects table gained "sync session" and "last sync status (since time)". It's only rewritten (and copied to the PC) when the status word changes, so a flush stays cheap.
- Handoff: `ca run` flushes when a sync session exists, falling back to the old rsync push without one. `ca wait` flushes after waiting on a remote task, so the Mac reads fresh results. Status checks use Mutagen's Go templates, so there's no jq or python dependency.
- Single machine mode: `ca init mac` doesn't sync anything, and `ca init pc` does a one-off rsync push with no live session.
- App indicator: polls `mutagen sync list --template '{{json .}}'` every 3 s, only while the window is visible, with `MUTAGEN_DISABLE_AUTOSTART=1` so the app never starts the daemon. It's hidden when Mutagen is missing or there are no `ca-*` sessions. Red means conflicts, a last error, failed writes, disconnected or halted. A skipped absolute symlink (a scan problem) is a note in the popover, not red. The CLI treats it the same way.
- Measured on the real tunnel (2026-10-27, about 425 ms best round trip). Small new file, polled every 5 ms on the receiving side, clock offset taken over one ssh stream (plus or minus 0.2 s): Mac to PC 1.57 to 1.89 s (median 1.69 s), PC to Mac 0.68 to 0.95 s (median 0.71 s). The full round trip is about 2.4 s whichever way the offset falls. Mac to PC takes more round trips, because the Mac daemon has to ask the PC agent to scan, stage and apply. Over a LAN this would be well under a second. The 1 s goal isn't reachable on this link from the Mac side, so I kept the defaults instead of tuning.
- Large file: the first copy of a 40 MB random file took about 150 s (tunnel bandwidth). A 1 KB edit in the middle then synced in 1.2 to 1.6 s with about 72 KiB on the wire (rsync style deltas). PC side edits reached the Mac about 1 s after the write. One PC edit followed by an immediate flush took 10.5 s once; repeat runs were 1.9 to 3 s.
- Recovery: killing the transport's tunnel process got it back to watching on its own in 11 s. Turning Wi-Fi off for 30 s: Mutagen noticed after 10 s (ssh keepalive), reconnected about 20 s after Wi-Fi came back, and a file written while offline crossed in that first cycle.
- After verification: the indicator now also starts polling when AppState gets its window. A launch without focus fires none of the occlusion, key or active notifications, so the Sync button never showed up. Read only PC calls (`__probe`, `__status`) no longer `mkdir` the project folder, so `ca init mac` leaves nothing on the PC.
- Ignore patterns without a slash match at any depth (Mutagen works like gitignore), so `build`, `dist`, `target` and `id_*` also skip nested folders and files like `src/id_utils.py`. That's the safe side of the requested list. Use `sync_allow=` to let one back in.

## Projects, Orchestrator mode and the mascot (M6 to M11)
- Shared contracts first (`Core/Contracts.swift`): project slug, session names, the event line format and the agent graph. That let the project layer, the event pipeline, the canvas and the mascot be built in parallel without touching each other's files.
- Session names are now `ca-<slug>-<host>-<task>`. The slug is the project folder name, lowercased, with a-z 0-9 and single dashes, cut to 16 chars, so names stay under tmux-friendly lengths. The orchestrator is `ca-<slug>-<host>-orch`. Old `ca-<host>-<task>` names are still parsed (`CASessionName.parse`), and the station lists any `ca-*` session as before.
- Hooks were checked against the installed Claude Code 2.1.311 instead of the docs. The event list was taken from the binary, and real payloads were captured with a catch-all hook during a `claude -p` run that launched a subagent. What matters:
  - Built-in subagents run in the background. The Agent tool's PostToolUse comes back in milliseconds with `agentId`. SubagentStart and SubagentStop carry `agent_id` and `agent_type`, and every tool call inside a subagent carries its `agent_id`.
  - The subagent's name comes from the Agent tool input (`name`), not from SubagentStart.
  - `Stop` lists still running subagents in `background_tasks`, which is where "Waiting on <names>" comes from.
  - A finished subagent shows up in the parent as a `<task-notification>` UserPromptSubmit.
- Project layer:
  - The last open project reopens on launch. With none, the welcome screen shows. The old global `layout.v1` is no longer read, and its old sessions still show in the station.
  - Per project state is a JSON file in `~/Library/Application Support/CrossAgent/projects/<slug>-<hash>.json`. It holds panes, mode, orchestrator host and session, node positions and finished nodes.
  - Panes start in the project folder via `tmux new -c` (the PC gets `"$HOME/<rel>"` so its shell expands it) and carry `CROSSAGENT_PROJECT` (plus `CROSSAGENT_ROLE=orchestrator` for the orchestrator) via `-e`. cwd and env only apply when a session is created; reattaching keeps the old ones.
  - The PC path uses the same rule as the skill's `pc_dir()`, and a unit test runs both against the real script.
- tmux targets are now exact (`-t '=name'`, quoted because zsh expands `=word`). Before this, killing `ca-pc-1` after it had ended could hit `ca-pc-10` by prefix match.
- Typing into a worker from the canvas attaches with `tmux attach -t '=name'` and never creates a session, so a stale node can't spawn an empty one.
- Event pipeline:
  - One Python stdlib script does both jobs: the hook, and the follower (`--follow`). It is installed to `~/.crossagent/bin/` on both machines. The hooks are `async: true` (in 2.1.311's hook schema), so Claude never waits on them. A call costs about 26 ms.
  - Event files are trimmed past 512 KB, and files older than 3 days go when a follower starts. In a stress run (800 calls, 8 at a time, through several trims), nothing was lost or duplicated.
  - The PC is followed by one long lived ssh process over the existing control master. It sends a heartbeat every 10 s, restarts after 40 s of silence with 2/5/15/30 s backoff, and replays 60 to 120 s with dedupe, so a drop loses nothing.
  - Only events carrying `CROSSAGENT_ROLE` count. The app starts the orchestrator with `ROLE=orchestrator` and `PROJECT=<slug>`, `ca run` workers set `ROLE=worker`, and built-in subagents inherit the orchestrator's env. Random Claude sessions in the same folder don't show up.
  - Payload facts from a live interactive session:
    - Notification has `notification_type` but never an `agent_id`, so a permission Notification within 3 s of a subagent's PermissionRequest is credited to that subagent.
    - Declining a permission sends no event, so "needs input" stays up until the next activity.
    - Named interactive agents run as teammates. Their `background_tasks` ids don't match agent ids, so "Waiting on" falls back to whichever agents are still busy.
    - Hidden helper agents (empty `agent_type`) are ignored.
- Mascot:
  - **Patch** is a chunky little terminal with a white case, a dark screen face, mint eyes, pink blush and stubby feet. A blue to purple cable arcs over its head like the arch in the app icon.
  - It's a 28x28 pixel canvas drawn from string grids in Swift, shown at 2x (56 pt), with no image files. It's all original, and the clawd-on-desk repo was never opened.
  - Nine states, priority: error > needs input > done > juggling (2+ active, one orb per agent in its host colour) > bobbing (1 active) > working > thinking > sleeping (60 s quiet) > idle.
  - A finished node in error only keeps Patch sad for 20 s.
  - It redraws only when its frame changes (idle is about 1/s), and pauses when covered, hidden or off screen. A sprite costs about 0.1% CPU idle, and juggling at 12 fps about 1% (release build). It can be hidden with the `mascotHidden` setting.
- Canvas:
  - Nodes spread by angle around the orchestrator, and cards are pushed off other nodes' cables. Plain repulsion had stacked nodes on one ray with cables through cards.
  - The layout freezes 8 s after its last change, so it can never keep the canvas awake.
  - Plain scroll pans, Cmd+scroll and pinch zoom (0.35x to 2.5x). Option-drag or the edge handle starts a relay cable.
  - Pulses and zzz are Core Animation. Cables and particles are one Canvas whose TimelineView pauses when nothing moves.
