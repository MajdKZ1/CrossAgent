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
