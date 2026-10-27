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
- Login shell zsh, git, claude in ~/.local/bin (only on PATH in a login shell, which the spec's `$SHELL -lc` already handles).
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
- The Activity tab cost about 21 to 31% of a core. The cause was SwiftUI's `numericText` content transition, which runs a Gaussian blur over every changing digit on every sample. Numbers are now plain monospaced digits that don't animate. Sparklines and host columns are Equatable and keyed on a series version, so a sample only redraws what changed. Release build: Activity tab open 2.25%, the readout alone 0.66% (whole app).
- The PC event follower now heartbeats every 2 s. After a quit it exits within a second, where before it could linger up to 10 s.
- The tab strip measures the window rather than itself. Agent chips drop first when they'd leave less than two tab widths, the tabs scroll, and the selected tab stays in view on resize. Nothing clips at 925, 1000 or 1400 pt with 10 tabs.
- An agent tab opened before its tmux session exists now attaches once the monitor sees the session. It retries at most every 5 s and also has a Try again button.

## Linked sessions, windows, Crossover Portal and Super-Max (M19 to M24)

- Session linking reads what Claude Code 2.1.311 writes, the same on the Mac and the PC:
  - `~/.claude/sessions/<pid>.json` is the authority for pid to session id to cwd. It also has `procStart`, which catches a reused pid, and a `status`.
  - The transcript is `~/.claude/projects/<cwd with / and . as ->/<sessionId>.jsonl`. Built-in subagents get their own `<sessionId>/subagents/agent-<id>.jsonl`, plus a `.meta.json` whose `toolUseId` links back to the parent's Agent call.
  - We only ever read these files. Nothing writes to them, and the per session messaging socket is left alone.
- Where a session runs comes from walking its parent processes, for example `claude <- zsh <- login <- Ghostty`. A tmux server ancestor means it's in tmux, and the pane pid maps it to the tmux session.
- Mac GPU load: `Device Utilization %` from the IOAccelerator's performance statistics is readable without root, so the Mac shows live GPU load too.
- One window per project (M21):
  - **Windows:** project windows are plain NSWindows managed by `ProjectWindows`, not a SwiftUI WindowGroup. That gives direct control of dedupe, closing, frame restore and automation. The only SwiftUI scene left is Settings, which SwiftUI opens at launch, so the app closes it right away.
  - **Frames:** each window saves its frame under `CrossAgent.project.<hash of the path>`, so paths stay out of defaults. A new project takes the welcome window's frame, or cascades from the front window.
  - **Open list:** the list of open projects is `openProjects.v1`. It's saved in `applicationShouldTerminate`, because SwiftUI closes windows one by one before quitting. The first launch after the update falls back to `lastProject.v1`.
  - **Closing:** the close button on one of several windows closes that project. Closing the last window quits and keeps it, so it reopens next launch. File > Close Project on the last window shows Welcome. tmux sessions always keep running.
  - **Shared services:** the tmux monitor, Portal status, activity and themes are shared by every window. Fast tmux polling is counted per viewer. Event followers belong to a project, and so to its window, so nothing runs twice.
  - **Menus and tabbing:** menus act on the key window, or on the last project window that was key. Native window tabbing is on. Which windows were merged isn't restored, so they come back separate.
  - **Top bar:** the in-window project switcher is gone. Recents in the project menu open the project's window or bring it forward.
- Crossover Portal (M22), CLI part:
  - **Commands:** `ca portal` takes start, status, flush, conflicts, stop, push and pull. `ca sync` is the same command under its old name.
  - **What was renamed:** every message the CLI prints, the help, SKILL.md and the CROSSAGENT.md template.
  - **What stayed:** the Mutagen session name `ca-<project>`, the `ca-cfg` label, the `sync_allow`/`sync_ignore` keys, function names and status words like "watching (in sync)". Renaming those would break existing portals. Projects that already have a CROSSAGENT.md keep their old wording, because `ca init` never overwrites it.
  - **Flush fix:** `ca portal flush` now waits up to about 10 s while Mutagen is still scanning or staging, where before it failed straight away after a resolved conflict.
  - **Installed skill:** the installed copy on both machines was updated with `install.sh`.
- Super-Max Computer (M23):
  - **RAM total:** it's installed memory. Linux reports a bit less than what is installed as usable, so it counts memory blocks to get the installed size, and trusts that count only within 25% of the usable figure. RAM used is total minus available, as before.
  - **GPUs:** the Mac's GPU core count comes from IOKit `gpu-core-count`, with `system_profiler` only as a background fallback, so no cache file is needed. The Mac's GPU load and memory in use come from the IOAccelerator performance statistics every sample, readable without root. `nvidia-smi` gives no core count, so the PC GPU shows none.
  - **VRAM:** it adds up across discrete GPUs only. The Mac's unified memory is listed beside it, because adding it would count Mac RAM twice.
  - **Units:** storage is decimal, like Finder and drive labels, and the Mac counts purgeable space as free, like Finder. RAM is binary. Peak temperature leaves out the battery.
  - **Offline machines:** they drop out of the totals. The card says "1 of 2 online", and the offline half stays dimmed with its last known specs and the reason.
  - **Steady numbers:** the big load numbers are a 3 sample mean (4.5 s), rounded, in monospaced digits with no transitions.
  - **The portal ring:** in the card it is steady or off and never pulses, so it costs nothing. It's drawn with Core Animation, and only the crossing state animates.
  - **The PC sampler:** it stays one ssh stream. It now also sends the nvidia-smi fields, disk space and, once, the CPU specs. GPUs can only be added, after a test caught a line arriving before nvidia-smi output wiping the PC GPU.
  - **The Mac disk query:** it takes 12 ms, so it runs every 10th sample.
  - **More than two machines:** the card works for N machines, with a portal on each seam.
  - **CPU cost:** release build, 45 s runs. The Activity tab with Super-Max uses 2.4 to 2.6% of a core, against 2.2 to 2.4% for the Panes tab.
- Concurrent test instances shared the bare binary's defaults domain and reopened each other's throwaway projects. Agents now test with a renamed copy of the binary, so each gets its own defaults domain.
- Crossover Portal (M22), app part:
  - **Ring states:**
    - **Red:** a conflict or problem.
    - **Amber:** paused, connecting, or scanning without moving files.
    - **Soft pulse:** files crossing, either Mutagen staging or applying changes, or a sync cycle completed in the last 5 s. It's worked out on the existing 3 s poll, so there's no new timer.
    - **Accent:** watching, in sync.
    - **Dim:** no portal for this project.
    - The pulse runs in the render server, and a steady ring costs nothing.
  - **Indicator and popover:** a project window shows that project's portal. The welcome window shows the worst state across all portals. The popover names states in words ("In sync", "Files crossing", "Conflict in 1 file"), not Mutagen's raw status.
  - **Narrow windows:** below 1100 pt the indicator drops its "Portal" label and keeps the ring.
  - **Top bar readout:** the Super-Max readout replaces the old activity readout.
  - **What stayed:** the app still calls `ca sync start`, the permanent alias, so older installs of the skill keep working. The `synced` theme token and the automation keys keep their names.
- Sessions UI (M20):
  - **Format facts the parser found:**
    - On macOS, `procStart` is `ps lstart` in UTC. On Linux it's the starttime field of `/proc/<pid>/stat`.
    - The session file has a `tmux` field, so the tmux session comes straight from it, with `list-panes` only as a fallback.
    - The project folder name turns every character that isn't a letter or digit into `-`.
  - **Subagents:** there are three flavours: foreground, background (a later task notification) and in-process teammates (idle notifications, no meta `toolUseId`). Nodes are keyed by the Agent call's tool use id.
  - **Status:** status values are idle, busy and waiting. Waiting comes with `waitingFor`, either "permission prompt" or "input needed", which drives "waiting for input". The file is deleted on a clean exit, so no file means ended.
  - **Titles:** the order is a name the user set, then Claude's own ai-title, then the first prompt, then the folder based name.
  - **Live view layout:** a Conversation / Agents toggle rather than a split. Clicking a subagent node narrows the conversation to it.
  - **When it polls:** the Live view and discovery only run while visible. The Orchestrator tab keeps discovery going while it's up, so its session picker has a list.
  - **Continue here:**
    - It's off while discovery or the feed's own process check says the original is alive, and unknown counts as alive.
    - Right before spawning it refreshes discovery again.
    - "I've closed it" asks once, then goes ahead. The original process is never signalled.
    - The new tmux session is `ca-<slug>-<host>-resume-<6 chars of the id>`, started with `tmux new -A`, so a second click reattaches. It replaces the Live view tab.
  - **Any tmux session can be attached:** names without `:`, `.` or control characters, up to 128 characters, targeted exactly with a quoted `=name`.
  - **Project filter:** it matches the resolved path too, since macOS reports `/tmp/x` as `/private/tmp/x`. Mac and PC folders with the same home relative path share a group.
  - **Station strip:** it now lists other Claude sessions in this project, the ones CrossAgent didn't start, and they can be clicked.
  - **CPU:** release build, whole app. A Live view on an active session uses about 0.7% of a core, the Sessions tab about 1%.
- Final verification (M24):
  - **What passed:** the verifier passed sessions, windows, the Portal, Super-Max and the release bundle on both machines.
  - **Fixes after the verifier:**
    - **PC Live view order:** when subagent lines arrive after later main lines, the feed now puts everything back in time order.
    - **Recent sessions:** Claude Code's `<id>.orphaned-<ts>-<hex>.jsonl` copies and stub transcripts with no cwd are no longer listed.
    - **Release bundle:** `bundle.sh` no longer copies the test resource bundle into the app.
    - **Memory tile:** the PC memory tile shows installed memory, like the Super-Max card, instead of the smaller figure Linux calls usable.
  - **Dead code removed:** the Station's "outside tmux" Claude process scan went once Sessions replaced it, so a fast tmux poll no longer runs `ps` and `lsof`.
  - **Numbers:**
    - **Sessions:** with a PC Live view open, the app uses 0.27% of a core.
    - **Windows:** 3 idle project windows use 0.33%.
    - **Discovery:** nothing polls while no Sessions list or Live view is on screen.

## The claude wrapper and shared sessions

- **Why a shell function:** `claude` is a shell function, not a script on PATH. On both machines `~/.local/bin/claude` is the real binary, a symlink Claude's auto-updater rewrites, so a script with the same name there would collide. Only interactive shells read the rc files, so scripts, pipes and the SDK never see it.
  - **Where it lives:** the function is in `skills/crossagent/scripts/claude-wrapper.sh`, sourced from `~/.zshrc` and `~/.bashrc` through a marked block that `install.sh --wrapper` adds and `--remove-wrapper` removes.
  - **Finding the real binary:** `whence -p` in zsh, `type -P` in bash, so it never recurses.
- **When it runs plain:** it runs the real claude unchanged:
  - inside tmux, or with `CLAUDE_NO_TMUX=1`;
  - when stdin or stdout isn't a terminal, or tmux is missing;
  - with `-p`, `--print`, `--help`, `--version`, `--output-format`, `--bg`, `--background`, `--desktop` or `--tmux`;
  - when the first argument is a claude subcommand (from `claude --help`).
- **Sessions:** a new session is `ca-<slug>-<mac|pc>-<n>` with the smallest free n, and the slug matches `ProjectSlug.make`. `--ca-name` picks the name and reattaches if it exists.
  - **Environment:** the claude process gets `PATH` and the `ANTHROPIC_*` and `CLAUDE_CODE_*` variables passed with `-e`. A new session would otherwise get the tmux server's environment, which may come from another context.
  - **Variables left out:** a running Claude sets per process markers for its children (`CLAUDE_CODE_CHILD_SESSION`, the messaging socket and token, and the like). Forwarding those would turn transcripts off in the new session, so they are skipped.
- **tmux options:**
  - **Per session**, set on the `=NAME:` target, because option targets are pane targets: status off, mouse on, prefix None, prefix2 None, destroy-unattached off. CrossAgent's own sessions now get the same, so Ctrl+B reaches Claude everywhere.
  - **Server wide**, because they can't be per session, and additive: `set-clipboard on` unless it's off, `focus-events on`, and the `terminal-features` entries `xterm-ghostty:RGB:clipboard:focus` and `xterm-256color:RGB`, each added only once. `default-terminal` is a server option in tmux 3.x and already `tmux-256color`, so it's left alone.
  - **No config file:** no `~/.tmux.conf` is written.
  - **Closing a window:** a closed window sends SIGHUP to the tmux client, which detaches it. The session keeps running.
- **Who else is attached:**
  - **Discovery:** one `tmux list-clients` per poll per host. Each client is classified by its parent processes, like sessions are.
  - **CrossAgent's own clients:** they export `CROSSAGENT_CLIENT=1` and are left out. On the PC that's read from `/proc/<pid>/environ`, and on the Mac the CrossAgent app is the parent.
  - **What you see:** "Also open in Ghostty" is info, not a warning.
  - **Small leak:** if CrossAgent starts the tmux server, the variable lands in the server's environment. That only matters for a nested tmux client inside a pane.
- **Not hooked in yet:** auto mode refused to let an agent edit the user's real rc files ("Unauthorized Persistence"). The rc logic was tested against fake home folders, and the wrapper by sourcing it directly. The real hookup is one command for the user to run.

## Native subagents and remote workers (M25 to M31)

### M25 what Claude Code 2.1.311 really supports

Checked on both machines (`claude --version` says `2.1.311 (Claude Code)` on the Mac and the PC) with real runs in a scratch folder, `--model haiku` to keep it cheap.

- **`claude -p --output-format stream-json --verbose`:** one JSON object per line. Types seen: `system` (subtypes `hook_started`, `hook_response`, `init`, `commands_changed`, `thinking_tokens`), `assistant`, `user` (tool results), `rate_limit_event`, then one `result`. Every line carries `session_id`. `init` has `cwd`, `tools`, `mcp_servers`, `model`, `permissionMode`. `result` has `subtype` (`success`), `is_error`, `num_turns`, `total_cost_usd`, `permission_denials` and `result` (the final message text).
  ```
  system init 84dd3df9-f62e-4b2d-adc1-8bc2ed821923
  result success 84dd3df9-... {'is_error': 'False', 'num_turns': '2', 'result': 'The file says "hello" ...'}
  ```
- **Resume keeps the conversation and the id:** `claude -p --resume 84dd3df9-... "What word was in the file you read earlier?"` answered `Hello`, and both `init` and `result` reported the same `session_id`. `--fork-session` exists for the opposite. So follow-ups to a remote worker are `-p --resume <id>`, one conversation per worker.
- **`--permission-prompt-tool` works, but it's hidden:** not in `claude --help`, present in the binary (`--permission-prompt-tool <tool>`, "must be an MCP tool"). The visible `--permission-prompts host|none` flag refers to it. A 40 line stdlib Python stdio MCP server with one `approve` tool did the job:
  - Claude calls it with `{"tool_name":"Bash","input":{"command":"python3 -c 'print(6*7)'",...},"tool_use_id":"toolu_..."}`.
  - Answering `{"behavior":"deny","message":"Denied by test"}` blocked the call. Claude reported `DENIED` and listed it in `permission_denials`.
  - Answering `{"behavior":"allow","updatedInput":<input>}` after a deliberate 150 s delay still worked (`The output is **42**`, total run 2:39). There's no short MCP timeout in the way, so a human can take their time on an approval card. `MCP_TOOL_TIMEOUT` exists as a hard wall clock limit, so `ca remote` sets it above its own approval timeout anyway.
  - Avoid MCP server names that start like a claude.ai connector (the binary refuses those for prompt tools). Ours is `crossagent`.
  - Under `--permission-mode acceptEdits`, file commands like `touch` never reach the tool. They're auto approved, as expected.
- **Subagents:** the Agent tool takes `run_in_background`, custom agents load from `.claude/agents/` and `~/.claude/agents/`, and SendMessage continues an agent by name or id. Hooks for subagents were already checked in M6 to M11 (SubagentStart/Stop with `agent_id`, `agent_type`).
- **Agent teams are on here** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in the user's settings). With the default `teammateMode` a team started from a Claude running inside tmux can split teammates into new tmux panes, each a new claude process. That's exactly what local subagent work must not do, so `ca init` pins `"teammateMode": "in-process"` in the project's `.claude/settings.local.json` and CROSSAGENT.md says to use plain Agent subagents.
- **The PC can't reach the Mac:** `ssh pc 'ssh mac true'` gives `Could not resolve hostname mac`. Fixing that means changing ssh or network config, which is off limits.

### M30 node cards for remote workers

- **Remote nodes keep their node tab.** `canonical` no longer turns a worker with `remote` set into a plain session tab, so its card can carry Terminal, Brief and Result. The Terminal tab attaches `remote.tmuxSession` on `remote.host` (attach only, `tmux attach -t '=name'`) the first time it shows and closes with the tab.
- **The badge and cable wear `remote.host`,** not the proxy's host, so a merged pc-worker node says "PC" in the PC accent. A small network glyph marks remote nodes where workers show a terminal glyph.
- **Brief and Result are read when the tab shows,** and again when the path, the turn or running vs not changes (RemoteStop keeps the turn of its RemoteStart, so the running flag is what catches a fresh result). Local files are read directly, ssh hosts through `CommandBuilder.oneShot` (shared control master), capped at 256 KB. A missing file is the empty state, not an error. No polling.
- **Markdown is light:** headings bold, fences monospaced, inline marks parsed, line breaks kept, all in one selectable Text. No block layout engine.
- **Answers are written to `<id>.answer.tmp` then moved** to `<id>.answer`, so the waiting tool never reads an empty file. The id must match `^[a-f0-9]{12}$`. Buttons dim and stay off after a successful write until the PermissionAnswer event clears the card; a failed write re-enables them with a toast.
- **No keyboard shortcut answers an approval.** Buttons only, so a stray Enter in a terminal can't allow anything.
- **The pending approvals strip lives on the Orchestrator tab** (top center, up to three rows, then "N more waiting"). The node's own card has the full approval card. The canvas card says "Waiting on you" and its Answer button opens the node card.
- **`@name` messaging stays for remote proxy subagents** (box under the card, goes through the orchestrator). A standalone remote worker (kind worker) gets no box: its Claude is headless, so typing into its tmux session means nothing. A canvas relay to it still pastes into its session, unchanged.

### M30 canvas: one node per remote worker

- **Links are keyed by host and role,** not by tmux session. The transcript reducer doesn't know the project slug until the project's followers tell it, so `remote.tmuxSession` can be empty for a moment after a transcript link and gets filled by the first remote event.
- **Without a link a worker draws as its own node** (kind worker, id = its tmux session). When the pc-worker's `ca remote` call shows up the standalone node folds into the subagent: remote info, recent lines, a pending permission, a running turn's activity. Its done state is dropped, the subagent finishes on its own SubagentStop.
- **A new turn wakes a finished proxy.** If that proxy's own run is over (a fresh Agent call is about to take over), the node is marked revived: the new proxy's link removes it, and if no link ever comes the turn's RemoteStop finishes it so nothing stays busy forever.
- **A newer proxy takes the worker.** The old one is removed when it's done, or loses `remote` and goes once its SubagentStop comes.
- **The orchestrator calling `ca remote` itself links nothing** but marks the worker direct, so its RemoteStop finishes the node even if a proxy drew it before (orchestrator runs `ca remote wait` after its pc-worker timed out and returned).
- **RemoteStart clears `resultPath`:** a result belongs to a turn, so during a follow-up the Result tab is empty until that turn's RemoteStop.
- **A pending remote permission pins needsInput.** Mac side events of the proxy (its Bash PostToolUse, transcript tool results) and the screen check can't clear it, only PermissionAnswer or RemoteStop.
- **Live views get remote events through `RemoteEventLog`,** a per project log (last 1000) the project's followers append to. Any session feed whose cwd is in a registered project applies what it hasn't yet, so a Live view opened later still catches up. It needs the project's Orchestrator events turned on, same as the project canvas.
- **`ca run --claude` hook events (role worker) are ignored now.** The demo shows a pc-worker with an approval instead.

### M26 ca remote

- **State lives on the worker's host** in `.crossagent/remote/<role>/` (brief.md, turn-N.md, turn, turn-N.exit, session, stream.jsonl, result-N.md, result.md, allow, model, approve_timeout, loop.pid, turn-N.err). `.crossagent/` never crosses the Portal. The Mac keeps copies of each brief and report in `.crossagent/remote/<host>-<role>/`.
- **One tmux loop per role, not one process per turn.** `ca __remote_loop` polls the `turn` file once a second and runs one turn at a time, so the whole conversation's scrollback stays in one pane. `loop.pid` plus `kill -0` plus `tmux has-session` decide if it's alive; a dead loop with an open turn gets that turn closed with exit 1 so nothing waits forever.
- **No session options on the loop's tmux session.** `ca run` sets none either; the app sets status, mouse and prefixes when it attaches, same as for every other ca session.
- **`--allowedTools` gets one argv element per rule** (`--allowedTools 'Bash(npm test:*)' --allowedTools Read`). Checked on 2.1.311 with a haiku run: `Bash(python3 -c:*)` let `python3 -c 'print(6*7)'` through without asking while `curl` still went to the permission tool. The prompt goes in on stdin (`claude -p < turn-N.md`), which works the same as an argument and avoids any length or quoting limits.
- **The exact command, run in the project folder on the PC:**
  ```
  env -u CROSSAGENT_ROLE -u CROSSAGENT_NODE -u CROSSAGENT_PROJECT -u CA_ROOT -u CA_SLUG -u CA_HERE \
      CROSSAGENT_REMOTE_WORKER=1 MCP_TOOL_TIMEOUT=<(approve timeout + 60) * 1000> \
    claude -p --output-format stream-json --verbose --permission-mode acceptEdits \
      --mcp-config '{"mcpServers":{"crossagent":{"command":"<python3>","args":["-I","<skill>/scripts/ca-approve.py"],"env":{CA_HOST,CA_ROLE,CA_PROJECT,CA_TMUX,CA_APPROVE_TIMEOUT}}}}' \
      --permission-prompt-tool mcp__crossagent__approve \
      [--model M] [--resume <session id>] [--allowedTools RULE]... < turn-N.md 2> turn-N.err \
    | python3 -I <skill>/scripts/ca-stream.py --dir ... --turn N ... --rc-file turn-N.rc --err-file turn-N.err
  ```
  PATH comes from ca itself (`~/.local/bin` first), which is where claude lives on the PC.
- **`ca remote` checks the role before handing off files.** It asks the PC whether the role is mid-turn (or has no session for `--continue`) before it flushes or pushes, so a refused start never touches files.
- **Without a Portal, only a new conversation pushes.** A follow-up skips the push: rsync would overwrite whatever the worker changed on the PC in earlier turns with the Mac's older copies.
- **A new conversation for a role starts clean:** the old loop is killed and the state files (session, allow rules, model, turns) are deleted. `--allow` and `--model` persist across the turns of one conversation only.
- **`__remote_wait` prints `ca-turn N` as its first stdout line** so the Mac knows which turn it got (for `ca remote wait` without a turn). The Mac strips it, so stdout of `ca remote` is exactly the report. The footer and approval notices go to stderr.
- **The PC copy of the skill updates itself.** `ensure_remote` compares a cksum of ca, ca-stream.py and ca-approve.py on both machines and reruns `install.sh --pc` when they differ, so a new `ca remote` never talks to an old PC side. It runs on every `ca remote` start (two cheap ssh calls over the shared connection).
- **`ca remote stop` kills the loop's process group** (claude, ca-stream and the approval server die with it), writes RemoteStop rc 130 if a turn was open and drops that worker's request files. `session` stays, so `--continue` recreates the loop and resumes.
- **`CA_REMOTE_LOCAL=<dir>` runs the "remote" side on this machine** in `<dir>`. Only the tests use it, with a temp HOME, a fake claude and a private tmux server (`TMUX_TMPDIR`).
- **install.sh leaves `tests/` out of the installed skill** and copies only `pc-worker.md` and `mac-worker.md` into `~/.claude/agents`, never deleting anything else there.
- **`ca init` replaces a CROSSAGENT.md without the `<!-- crossagent template v2 -->` marker** only when the shipped template has it, and moves the old one to `.crossagent/CROSSAGENT.md.old`.
- **ca-stream.py rate limits activity:** exact repeats are dropped, text to one event a second, everything to ten a second. Tool calls in a normal run never hit the cap. Text activity uses the first line that isn't a markdown heading.

### M28 permission forwarding

- **Each `tools/call` waits on its own thread** in ca-approve.py, so parallel tool calls show up as several approval cards at once instead of one after another.
- **Request files are written atomically** (tmp then rename) with the full detail up to 2000 chars; the PermissionAsk event's `prompt` is capped at 600. Both files go away once answered or timed out.
- **`ca remote wait` announces each unanswered request once** on stderr and skips ones that already have an `.answer` file waiting to be picked up.
- **Smoke test on the PC (haiku):** turn 1 asked for `python3 hello.py` (acceptEdits doesn't cover running scripts), `ca remote answer pc <id> allow` let it through. Turn 2 (`--continue`) asked for `curl -sI https://example.com | head -n 1`, allowed the same way, got `HTTP/2 200`. Both turns reported session `143f439c-cbb1-49b5-a17f-e8234efba21c`.

### M27 and M29 worker definitions, CROSSAGENT.md and SKILL.md

- **Where the worker definitions live:** `pc-worker` and `mac-worker` are user level, in `~/.claude/agents/` on both machines (install.sh copies them, `ca init` keeps them current). That keeps them out of every project's git tree, and they're available wherever the skill is.
- **The proxy runs on haiku** with only Bash and Read. All it does is run `ca remote` and pass stdout back, so a big model would burn tokens for nothing.
- **Brief files, not inline briefs:** the orchestrator writes `.crossagent/briefs/<role>.md` itself, so the worker gets exactly what the orchestrator wrote, not a copy the proxy retyped. `.crossagent/` never crosses the Portal and is gitignored.
- **Follow-ups go through SendMessage** to the same pc-worker, which runs `ca remote --continue`. A fresh pc-worker with the same role works too, because the conversation is keyed by role on the PC.
- **mac-worker ships but can't run today:** the PC can't reach the Mac, so `ca remote mac` from the PC fails fast and says why. The code path is the same one pc-worker uses.

### M31 real end to end test (throwaway project ~/ca-e2e, deleted afterwards)

- **Setup:** a tiny stdlib Python lib with tests and a benchmark, `ca init` (CROSSAGENT.md, teammateMode pinned, Portal open, no sessions started), then the orchestrator started from the app (`ca-ca-e2e-mac-orch`, Sonnet 5.5) and given one task: one local subagent writes `sentence_count`, a second reviews it, a pc-worker runs tests and the benchmark on the PC, then a follow-up asks the same worker for medians over 3 runs.
- **Claude Code's own UI** showed `main` with `general-purpose  Implement sentence_count`, then `pc-worker  Run tests and bench on PC`, with live time and tokens. The pc-worker ran in the background.
- **No local sessions for local subagents:** before and after `ps` and `tmux ls` on the Mac differ by exactly one claude process, pid 83003, the orchestrator's own pane. No tmux session was added except the orchestrator.
- **PC:** exactly one remote worker session, `ca-ca-e2e-pc-bench`, in `/home/me/ca-e2e`. The brief it got (header with real specs plus the orchestrator's filled template plus `## Follow-up 1`) was saved and checked. Every turn's `init` and `result` carried the same session id, `4add2f7a-db34-4874-a369-069e7ac4db98`, so the follow-up resumed the conversation.
- **Permissions:** the first turn needed no approval, because the test project's own `.claude/settings.local.json` allowed `python3 -m unittest*` and `python3 bench.py*` and the Portal synced it to the PC. That's correct (project allow rules apply to workers too) but worth knowing. With those rules removed, the follow-up's `for i in 1 2 3; do ... python3 bench.py ...` raised an approval. It showed on the merged pc-worker node, was allowed from the app, and the PC logged `PermissionAnswer allow`. A third turn's `python3 -c "print(6*7)"` was denied from the app. The worker reported the denial and didn't work around it.
- **Canvas:** orchestrator, two Mac subagents, one PC worker node (proxy and remote worker merged, PC badge, Brief, Result and Terminal tabs working), plus `verify`, a `ca run` command worker.
- **The orchestrator checked the claims itself:** it read the diff and ran the tests locally after the writer, applied the reviewer's finding, and after the PC report reran the suite and benchmark on the PC with `ca run pc verify` (3108, 226 and 2546 ops/s against the worker's 3282, 235 and 2530 medians).
- **Fixed from the test:** unnamed Agent calls showed as "agent" or "general-purpose" on the canvas. The hook now names them by their description, like the transcript parser already did.
- **Known leftovers:**
  - If the project has CrossAgent's hooks, the headless worker's hooks still write an event file named after its session id. It has no role, so the app ignores it, and the follower deletes event files after 3 days.
  - The app's snapshot command doesn't capture terminal views. The card dump showed the remote Terminal tab live with the worker's feed.

### v0.1.0 events: injection, trust, hosts

- **Remote settings paths always start at `"$HOME"/`.** The project folder on a remote host comes from the project itself (`pc_dir=` in `.crossagent/project`), so it's untrusted. Before, it went to the shell as a quoted word after `cd "$HOME"`, which was safe from `$()` and quotes but not from a leading dash: a folder named `-rf` reached `cat`, `mkdir` and `rm` as an option. Now every path is `"$HOME"/'<rel>'/.claude/...`. A leading `/` is dropped, the same as the panes' `$HOME/<rel>` cwd, so `pc_dir=` can't point outside home either. `..` is left alone; it can only reach places the user can write anyway.
- **Hook script: 0600 in a 0700 folder.** Claude runs it as `python3 -I <path>`, so it doesn't need the exec bit. The install refuses a `~/.crossagent/bin` that is a symlink or someone else's, tightens a loose one and writes by rename, so a link planted at the script's name is replaced, not followed. Locally that's `PrivateFiles`; over ssh a short `test -O` / `-L` script that works in sh, bash, zsh and dash.
- **Event files: refuse what we can't trust, don't fail loudly.** The hook and the follower open event files with `O_NOFOLLOW` and only use regular files of ours that group and others can't write. A loose events folder of ours is tightened to 0700; a linked or foreign one is refused (the hook writes nothing, the follower exits 3 and the app's backoff retries). Linux user groups often run with umask 002, but every writer creates event files with mode 0600, so they still pass.
- **Session discovery and transcripts only read the user's own files:** `~/.claude/sessions`, `~/.claude/projects` and `/proc` stat lines for the process tree. Remote scripts get their arguments shell quoted. Nothing reads other users' paths.
- **Host ids are whatever hosts.json says** (`[A-Za-z0-9_-]{1,40}`). The hook takes `CROSSAGENT_HOST` when it's a valid id, else `mac` on macOS, else the short hostname turned into an id. The graph knows the hosts: events with no host count as the orchestrator's host, remote events as the only ssh host's.
- **`ca remote` host words** resolve in this order: a host id, a host's full name or one word of it when only one host has that word, `local`/`here`/`mac`/`laptop` and friends for the local host, `remote`/`ssh`/`overseas` for the only ssh host. Any other valid id passes through as is, so a host added after the graph was built still links. `pc`, `linux` and such aren't hardcoded anymore; with the example hosts they come from the name "Linux PC".
- **Test data is made up.** CPU, GPU, RAM and disk numbers are plausible but not the owner's machines. Captured session, agent and tool ids in the fixtures are replaced by fake ones of the same shape, mapped the same way everywhere they appear.

### v0.1.0 app: automation, sockets, hosts

- **Automation is debug only.** Every `Automation*.swift` file and the AppDelegate hook are inside `#if DEBUG`, so `swift build -c release` has no DistributedNotificationCenter handler, no `CROSSAGENT_AUTOMATION` check and no `automation` defaults key; `strings` on the release binary finds none of them. The synthetic pointer code moved to `SyntheticPointer.swift` and stays in every build, because the orchestrator demo uses it and it only acts on our own windows. `PointerAutomation` is a typealias so callers didn't change, and a typealias leaves no name in the binary.
- **ssh masters live in `~/.crossagent/ssh/%C`,** the same string the skill's `ca` uses, so both share one master per host. It's passed with a literal `~` so ssh expands it from the passwd entry and a home dir with spaces still parses. `~/.crossagent` and `~/.crossagent/ssh` are made 0700 at launch before anything runs ssh.
- **Socket length:** `%C` is 40 hex chars and ssh binds the master at the path plus a 17 char random suffix before renaming it, so the expanded path must stay at or under 86 bytes (103 usable in `sun_path`). That fits any home dir up to 29 chars (`/Users/` plus a 22 char name). The suggested fallback under `~/Library/Caches/CrossAgent` is always longer than `~/.crossagent/ssh`, so it can't help. Instead, when the path won't fit, or `~/.crossagent`/`ssh` is a symlink or someone else's, ssh runs without connection sharing and the app logs why. Slower connects, nothing breaks.
- **Private dirs and files:** `PrivateFiles` makes dirs 0700 (tightening ours, refusing symlinks and foreign ones) and writes files 0600 via mkstemp plus rename, so a planted symlink is replaced, not followed. At launch it also tightens `~/.crossagent/events`, `approvals` and `bin` if they exist and are ours. hosts.json is written the same way, in a 0700 `~/.config/crossagent`.
- **Trust checks in app code:** hosts.json is ignored (defaults used, logged) if it's a symlink, not ours or group/other writable; every host's id must match `[A-Za-z0-9_-]{1,40}` and an ssh target must not start with `-` or contain whitespace or control chars, or the host is dropped. The approval answer script refuses a `~/.crossagent` or `approvals` that is a symlink, not a dir or not ours (`test -L`, `-d`, `-O`), runs with umask 077, writes a mktemp file and renames it over the answer, removing a symlink at that name first. Event files and the hook script are the hook's side, see the events section above. Brief and result docs are only displayed, never run.
- **Hosts for anyone:** `HostStore.defaults` is just this Mac. `HostStore.example` keeps the Mac plus `pc` pair for tests and the README. A hosts.json that already exists is read as is.
- **First run setup** is its own small window, not a sheet on a project window, so it shows the same over the welcome window or a restored project. It appears while every host is local and the user never pressed Skip (or added one). Adding writes hosts.json through JSONSerialization so other entries and unknown keys survive.
- **New hosts need a restart.** Hosts are read once at launch and handed to the tmux monitor, discovery, activity and every window as constants. Making all of them live for an action people do once or twice wasn't worth the churn before a release, so the sheet says "Restart CrossAgent to start using it" with a Restart Now button that quits (windows and panes save as usual) and reopens the bundle.
- **The Test button** runs the probe through `exec $SHELL -lc` with the same PATH prefix panes use, not a bare `command -v`, because claude often lives in `~/.local/bin`, which a non-login ssh command doesn't have. Batch mode and a 10 s connect timeout, off the main thread.
- **Activity on a remote Mac:** the remote sampler is Linux only (`/proc`, `/sys`). On any other OS it now exits with "remote stats only work on Linux hosts for now", which the host card shows instead of empty numbers. A remote macOS sampler is future work. Spec parsing (`lscpu`, `/proc/cpuinfo`, nvidia-smi names, Mac sysctl) has nothing machine specific in it.
