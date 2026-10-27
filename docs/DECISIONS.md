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
- Project UI:
  - The welcome screen shows when no project is open, unless the station (or a pane opened from it) is up. The station still works without a project.
  - Opening a project never lands on Station, since the station isn't tied to one.
  - The "PC folder missing" choice is a card over the window rather than inside the New pane popover. That way it works however a pane is opened and can be driven by automation.
  - A failed ssh check counts as missing, so you get the choice instead of an error. Typing an existing session name skips the check.
  - Cmd+Shift+V toggles the station back to the previous mode, and Cmd+Shift+O toggles Orchestrator back to Panes.
  - Host chips hide under 1200 pt with a project open (1000 without) and the mode switch goes icon only under 760 pt, to keep the top bar uncluttered.
  - Dev only: `CROSSAGENT_NO_ACTIVATE=1` launches without stealing focus, and `CROSSAGENT_AUTOMATION_ID` gives each test instance its own automation channel. Before that, parallel test runs received each other's commands.
- Orchestrator wiring:
  - Each open project has one graph and one controller. Hooks go in when you hit Start, or when you enter the mode with an orchestrator already running, never just from looking at the start card.
  - Start waits for the hooks before launching Claude, so the first session already reports.
  - When a project with the orchestrator on reopens, the followers start right away and hook setup quietly re-runs. That refreshes the script and picks up a PC folder that has appeared since.
  - Enabling never creates the project folder on the PC. If the folder isn't there, the PC copy of the hooks is skipped until it is.
  - Esc inside a node's terminal goes to the terminal, because Claude uses Esc to interrupt. Otherwise Esc, Cmd+W or a click outside closes the card.
  - Messages to built-in subagents are pasted into the orchestrator as `@name text`, with Enter sent 150 ms later so Claude doesn't treat it as part of the paste.
  - Worker terminals attach only while their card is open. A relay with no card open attaches, pastes and detaches again.
- Canvas performance pass:
  - Cards are separate hosting views that re-render only when their node changes, and they move by frame origin.
  - Cables, glow and particles are Core Animation layers and animations, so data moving on a still graph costs the app nothing.
  - A display link runs only while something is moving.
  - One hidden cost was the root hosting view re-measuring the whole canvas through Auto Layout on every update. An explicit size fixed it.
  - Measured in the demo, release build, canvas only: idle 0.1%, busy 3.6% average (8.9% peak in 60 fps bursts), 14 nodes with constant flows 2.0%. Before: 0.4%, about 25% and about 22%, with frames running nonstop.
  - Patch then moved to pre-rendered frames looped by a CAKeyframeAnimation. It went from 5 to 7% while animating to the app's baseline (about 0.3%).
- Canvas gestures were tested with synthetic in-app events (`drag`, `scroll`, `magnify`, `dblclick` automation) that never touch the real cursor, checked against camera and node positions read back. This found four real bugs:
  - Card drags read the live cursor instead of the event.
  - Clicks were swallowed when the window wasn't key.
  - A dragged node lagged the cursor by the distance before the drag registered.
  - Slot order depended on dictionary order, so the layout changed between launches.
- Real end to end test (orchestrator on the Mac, three built-in subagents and a PC worker through `ca run`, permission prompts approved by hand):
  - Nodes, badges, flows, done and finished all behaved.
  - Typing into a PC worker's card reached its tmux session, and a message to a subagent arrived as `@scout`.
  - Relaunch reattached the orchestrator, and turning the hooks off left my own hook and permissions intact.
- Measured, release build, real app, 8 to 14 nodes: idle 0.03% CPU average (0.2% max); `demo` busy 15.5% average (40% max) at 60 fps with dips to 48; back to 0.15% after it settled. The real app costs more than the demo window alone because the hidden pane grid, the monitors and the event followers run too.
- Accepted as is:
  - Turning hooks off re-serializes `settings.local.json` (sorted keys, pretty printed). Every value is kept, but the file isn't byte for byte the same.
  - A message to a built-in subagent reaches it as coming from "user", since Claude Code routes `@name` that way.
  - Claude's own trust dialog defaults to "No, exit", so answer it with the arrow keys rather than Enter.
- The "dead card" from the real test turned out to be the canvas freezing while its window was covered. The display link pauses there, which is right, but a node that spawned meanwhile stayed at the start of its entrance: invisible, at 30% scale, on top of the orchestrator. It swallowed or misdirected clicks. Now, whenever frames can't run, entrances, exits, fades, camera moves and the layout all jump straight to their end state. The built in pointer regression covers it.
- Nodes keep their spot across launches. The positions map now holds every node, written when the layout settles and when a drag ends. Positions the canvas writes itself don't pin nodes, so the live layout still reflows. Only a user drag or an outside change pins a node.
- Keys typed into a pane while it connects are held until 0.4 s after its first output, then sent in order. tmux attaching over ssh sometimes ate the first keystroke typed into a freshly opened worker card.
- Final verification (release bundle builds and launches, 98 tests, the 13 check canvas pointer regression): everything passed after the fixes above.
- Cut or limited, and why:
  - "Waiting on" covers the orchestrator only: background subagents from `Stop`, plus `ca wait` commands. Subagents waiting on each other don't report anything a hook can see.
  - Permission prompts raised by built-in subagents are matched to the subagent by timing (a Notification within 3 s of its PermissionRequest), because Notification carries no agent id.
  - Teammate style subagents can be marked done at SubagentStop while Claude still lists them as idle teammates. That's left as Claude reports it.
  - The hover handle for relay drags can't be triggered with synthetic events, since hover follows the real cursor. It shares its code with Option-drag, which is tested.
  - Pulses, zzz and Patch run on Core Animation, so offscreen snapshots don't show them. Their models and keyframes are unit tested instead.

## Tabs, native panes, activity, themes and the new mascot (M12 to M18)
- Contracts went in first again. `App/Tabs.swift` holds `TabKind`, plus `AgentRef` (a graph node or any tmux session) and `openAgent`. `Core/ThemeModel.swift` holds the theme tokens (ui, terminal, mascot) and a theme changed notification. That let the tab strip, native panes, the activity monitor, the theme system and the mascot be built at the same time, each in its own files.
- Everything keeps reading colours through `Palette` and `Theme`, and the theme work turns those into computed values backed by the current theme, so most call sites don't change. Layer based views (canvas, mascot) recolour on the notification.
- Activity monitor:
  - The Mac uses host_processor_info, host_statistics64, sysctl and libproc on a 1.5 s timer off the main thread.
  - The PC uses one long lived ssh running an inline python script that prints raw counters (/proc/stat, meminfo, hwmon, PSI). All the maths is in Swift and unit tested. Nothing is installed on the PC. The script costs about 0.4% of one core.
  - Sampling only runs while the Activity tab or the readout is visible, and pauses when the window is hidden.
  - On the test Mac the efficiency cores come first (cpu0 to 5 are E, cpu6 to 9 are P, called "Super"), so cluster membership comes from the IORegistry `cluster-type`, not from an assumed order.
  - Apple Silicon temperatures readable without root: 24 PMU tdie die sensors (shown as SoC: average, with the hottest as detail), the SSD (NAND) and the battery. There are no cluster or GPU sensors by name, so the Mac has no GPU tile. One sensor reads -9199 and is filtered out.
  - An NVIDIA GPU on the proprietary driver, which has no hwmon, so its temperature and load come from `nvidia-smi` when it exists. PC memory "used" is total minus MemAvailable, like `free`. The total is a bit under the installed size because the kernel reserves some. PC pressure comes from PSI some avg10, with my own cut offs: under 1% normal, under 10% elevated, above that critical.
  - Session CPU is percent of one core, like top, summed over each `ca-*` session's process tree.
- Activity accuracy, measured at the same moments as the reference tools:

  | Reading | Reference | CrossAgent |
  | --- | --- | --- |
  | Mac CPU idle | top 5.46% | 5.6% |
  | Mac CPU under 5x `yes` | top 52.7% | 53.4 to 61.7% (top uses a 1 s window, CrossAgent 1.5 s) |
  | Mac memory | vm_stat math 13.96 / 14.04 GiB | 13.96 / 14.04 GiB |
  | PC CPU idle | top 0.9% | 1.0 to 1.5% |
  | PC CPU under 9 busy loops | top 57.1% | 57.0 to 58.2% |
  | PC memory | free 4117 MiB | 4.02 GiB |
  | PC Tctl idle / load | 39.75 / 61.5 °C | 39.8 / 61.4 to 61.9 °C |
  | PC NVMe | 36.85 °C | 36.9 °C |
  | PC GPU | nvidia-smi 42 °C | 42 °C |
  | Session test (a busy loop in a ca-* session) | about 100% | 99.9% on the Mac, 100% on the PC |
- Tabs:
  - One `Window` scene, so there's no File > New Window. The tab strip carries the traffic lights, the project switcher, the tabs, up to 5 agent chips (then a "+n" menu), Sync, the activity readout, broadcast, and a "+" menu.
  - The old host chips and mode switch are gone. The cwd and PC path moved to the top of the switcher popover and the project name tooltip.
  - Panes and Welcome can't be closed, so a project always has a tab. Cmd+W on Panes still closes the focused pane.
  - Cmd+1..9 switch tabs. Pane focus moved to Ctrl+1..9, and pane cycling to Cmd+Option+[ / ].
  - Only tabs with terminals (the pane grid and agent tabs) stay alive while hidden, so no terminal is ever recreated. Station, the canvas, Activity and Welcome are built only while selected, so they don't poll or animate in the background. The canvas camera resets when you leave its tab.
  - Agent tabs dedupe by one canonical ref. A worker node becomes its tmux session. The orchestrator's session becomes the orchestrator node, which follows whatever host it runs on.
  - A station tile whose session is already a pane in the grid maximizes that pane instead of opening a tab, to avoid two clients on one session in one window.
  - Switching projects parks the current one with its panes, orchestrator, graph and followers still running, so switching back is instant and keeps scrollback. Broadcast turns off on a switch. Closing a project brings the most recent other open project forward.
  - Relaunch reopens the last active project and its tabs, and the others go back to recents.
  - Tabs open and close without animation, because a removal animation left a gap in the strip while the window was covered. Content fades in for 0.12 s, or not at all with Reduce Motion.
  - The orchestrator demo and the mascot gallery are now dev only tabs and are never saved. No code opens an NSWindow or NSPanel any more, and the automation `windows` count stayed at 1 through a full dev run.
- Native panes, compared by measurement with Terminal.app and Ghostty (screen capture wasn't allowed while you were using the screen):
  - **Line height:** SwiftTerm makes a row ceil(ascent + descent + leading) tall, which is 16 pt for Menlo 13, where Terminal.app and Ghostty use 15. `TerminalAppearance` sets line spacing so rows land on the native height (Menlo 15, JetBrains Mono 13 gets 17 like Ghostty). Cell width already snapped to whole pixels.
  - **Font:** the font list used "SFMono-Regular", which NSFont doesn't resolve, so every pane had silently fallen back to Menlo. Panes now use the system monospaced font (SF Mono) unless JetBrains Mono is installed.
  - **Scrolling:** with tmux on the alternate screen and mouse off, the wheel became arrow keys, which in Claude Code cycled prompt history instead of scrolling. Each `ca-*` session now gets tmux `mouse on` (scoped per session, like `status off`). The pane forwards only wheel events, at 1/5 sensitivity because tmux scrolls 5 lines a step, so a trackpad tracks about 1:1. Clicks and drags stay local, so native selection works.
  - **Typing after scrolling back:** this used to land in tmux copy mode. Now the next key first leaves copy mode, only when tmux's `[n/m]` marker is on the top row and a wheel up happened, so a stray `q` never reaches the app.
  - **Cmd+K:** clears local scrollback and sends Ctrl+L so the app redraws. `tmux clear-history` runs 300 ms later, because tmux pushes the cleared screen into history.
  - **Key equivalents:** Cmd+C/V/A/K/F/G/Shift+G are handled by the focused terminal's container and its key monitor, never by the global Shortcuts monitor. SwiftTerm's own handlers aren't open to subclass.
  - **Find bar:** Cmd+F opens it. It searches the screen; in a tmux pane the history lives in tmux. Direction follows iTerm and Ghostty: typing finds the newest match, and Enter / Cmd+G go older.
  - **Links and menus:** Cmd hover over a URL now shows the pointing hand (SwiftTerm already opened URLs and OSC 8 links). Right click has Copy, Paste, Select All, Find and Clear.
  - **Pane chrome:** in a grid, a 24 pt header whose text sits at 55% until hovered or focused, buttons on hover only, and a 1 pt focus border. A solo or maximized pane has no header row and no border, sits edge to edge with 12 to 14 pt padding, and shows a small capsule at the top right on hover or exit. Reduce Motion makes the fades instant. The pane background is now the terminal's own background, which removed a band of a different colour around the terminal.
  - **Not changed:** synchronized output (mode 2026). SwiftTerm supports it, but tmux 3.5 doesn't pass it to xterm style outer terminals, and the fix is a server wide tmux option.
- Themes:
  - Built in themes ship as JSON in the app bundle. User themes in `~/.config/crossagent/themes/*.json` are watched and apply as soon as you save. A broken file is skipped with a toast.
  - `Palette` keeps its names, computed from the current theme. The window root re-renders on a change. Terminals are registered weakly and re-coloured and redrawn in place, including running Claude Code. Canvas cables and the sleep zzz re-colour on the theme notification.
  - Optional per theme host colours override `hosts.json`.
  - Default reproduces the earlier colours exactly.
- Mono theme, derived from background #101010 and foreground #c8c8c8:
  - **Surfaces:** window #0b0b0b, surface #101010, raised #181818.
  - **Lines and chips:** border #c8c8c814, hairline #c8c8c80d, chip #c8c8c80a, chip hover #c8c8c814 (all the foreground at low alpha).
  - **Text:** text #c8c8c8, muted #8c8c8c, faint #626262.
  - **Accents:** accent #8fa1b3, success and synced #8fae94, warning #bba67c, danger #bf8a8a, broadcast #c09a84.
  - **Terminal:** cursor #a8a8a8, selection #333333 with #e0e0e0 text.
  - **ANSI normal:** #2e2e2e #b07a7a #8aa585 #b0a073 #7f91ad #a089ad #7fa6a6 #b4b4b4.
  - **ANSI bright:** #808080 #c79a9a #a8c2a3 #cbbd93 #a2b2cb #bba9c7 #a2c2c2 #dedede.
  - **Hosts:** mac #8fa1b3, pc #8fae94.
  - **Mascot:** body #b3dcff and eyes #0b1218, kept from the reference.
- Mono contrast (WCAG, enforced by `testMonoContrast`):
  - **Text on #101010:** text 11.37, muted 5.66, faint 3.12 (Default's faint is about 3 too).
  - **On raised #181818:** text 10.61, muted 5.28.
  - **Accents on #101010:** accent 7.17, success 7.84, warning 8.03, danger 6.54.
  - **Selection:** #e0e0e0 on #333333, 9.57.
  | ANSI | normal | ratio | bright | ratio |
  |---|---|---|---|---|
  | black | #2e2e2e | 1.40 (exempt) | #808080 | 4.82 |
  | red | #b07a7a | 5.36 | #c79a9a | 7.72 |
  | green | #8aa585 | 7.07 | #a8c2a3 | 9.89 |
  | yellow | #b0a073 | 7.36 | #cbbd93 | 10.18 |
  | blue | #7f91ad | 5.94 | #a2b2cb | 8.85 |
  | magenta | #a089ad | 6.05 | #bba9c7 | 8.71 |
  | cyan | #7fa6a6 | 7.17 | #a2c2c2 | 10.00 |
  | white | #b4b4b4 | 9.18 | #dedede | 14.14 |
- Mascot redesign: **Puff** replaces Patch. All the pixel art is gone.
  - **Look:** a soft, chunky, light blue (#b3dcff) blob with no outline and two dark (#0b1218) leaning pill eyes, matched to the user's two reference images over about ten render rounds. The references stay out of the repo.
  - **Shapes:** four body outlines (squircle, round, cloud, puffy), each with exactly 48 cubic points, so Core Animation morphs between them cleanly.
  - **Moods:** at rest Puff is the reference squircle, and it's round only while asleep. Thinking is a full cloud with a thought bubble. Working and having agents use a lighter "puffy" cloud, so the busy look stays close to the reference.
  - **Right eye:** the brief said smaller and higher, but in both references it sits slightly lower, so it follows the images.
  - **Idle gestures:** one timer at a time, every 2.4 to 5.8 s, so nothing redraws between gestures. Hover follows the pointer through a tracking area on the view only, with no global monitors.
  - **Clicks:** a trick never repeats twice in a row. Quick clicks (within 1.3 s) make each trick bigger, and from the third quick click two tricks chain.
  - **Orbs:** clicking one opens that agent's tab. Orb colours follow the theme's host overrides.
  - **Cost:** about 0.01% of one core per mood in a release build. All motion is Core Animation, so the app only wakes for the gesture timer.
- Real test fixes (M18):
  - **Sampler and follower spin:** the PC sampler and the event followers both had a pipe handler that returned early after a stop and then fired forever at EOF. Every pause or restart leaked one, and the app climbed to 570% CPU. Handlers now clear on EOF, on stop and on termination. Both have regression tests that reproduce the old spin (720% and 950%).
  - **Quit:** stops the samplers and every follower synchronously, so no ssh is left running on the PC.
  - **Puff clicks:** Puff sat inside a SwiftUI hosting view that never claims points outside a real mouse event, so clicks fell through to the orchestrator card. The canvas now hosts Puff's layer view directly, Puff's own hit test decides, and it follows whichever graph the canvas shows (the demo included).
  - **Tab strip:** tabs share the strip width, shrink from 150 to 76 pt with truncating titles (the selected tab keeps 112), then scroll. The close x overlays instead of taking room, and the fixed items never clip. Cmd+9 goes to the last tab.
  - **Hidden tabs:** keys never reach a terminal in a hidden tab. Focus is checked after every tab switch and before every key.
  - **Busy workers:**
    - A `ca run` command worker stays working until its WorkerStop. tmux can't tell `yes` from `read x`, so screen activity isn't a usable signal. A Claude worker counts as busy while its screen changed in the last 15 s.
    - The check runs every 5 s from the monitor's last poll. The monitor stays at its slow 10 s poll, well inside the 45 s idle window.
    - Telling Claude workers from command workers is a heuristic for now: the screen capture names Claude, or hook events have filled `recent`. A `mode` field on WorkerStart would make it exact.
  - **Ctrl+C in a `ca run` worker:** stops the command and keeps the worker. The runner and its pipeline trap SIGINT, so the result and WorkerStop still get written (exit 130).
- Performance, release build, real app with the orchestrator tab on screen: idle 1.05% of a core, `demo` busy 8.15%, Panes tab 1.2%. Puff alone stays at the app's baseline, because its motion is Core Animation.
