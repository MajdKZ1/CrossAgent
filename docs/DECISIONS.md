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
