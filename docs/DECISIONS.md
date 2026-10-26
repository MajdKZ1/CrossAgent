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
