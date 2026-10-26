# CrossAgent

One native macOS window with a grid of terminal panes. Each pane runs Claude Code
(or a plain shell) on a chosen workstation: this Mac, or the Linux PC over SSH
(`ssh pc` already works from this Mac). Sessions live in tmux on each host so
they survive the window closing. Open source later, MIT.

Read `docs/SPEC.md` before doing anything. It is the source of truth.

## How you work here (orchestrator mode)

You are the orchestrator. You plan, delegate, integrate, build, verify, commit.
Subagents in `.claude/agents/` do focused work:

- `terminal-engineer`: SwiftTerm integration, process spawning, ssh + tmux commands, hosts config, reconnect.
- `ui-builder`: SwiftUI layout, pane grid, headers, popovers, shortcuts, broadcast and relay UI, styling.
- `verifier`: builds, runs, checks behaviour on both machines, reports bugs. Never writes features.

Rules:
1. Work milestone by milestone from `docs/SPEC.md`. Do not stop until v0.1 acceptance criteria all pass.
2. Delegate in parallel when work does not touch the same files. Integrate yourself.
3. After every milestone: build must pass, `verifier` checks it, then commit.
4. Do not ask the user questions unless something is truly blocked (missing tool, auth failure). Make the reasonable call and note it in `docs/DECISIONS.md`.
5. Do not over engineer. No plugins, no databases, no networking layer of our own. SwiftTerm + system `ssh` + `tmux` does the heavy lifting.
6. You may run anything on the Linux PC through `ssh pc` (install tmux, check claude, etc). Do not change its SSH or security config.

## Commits

This history goes to a public GitHub repo later. Treat every commit like people will read it.

- Commit a lot. Many small, meaningful commits as you go (every working step, fix, or feature piece), not one dump per milestone. The history should tell the story of how the app was built.
- Each commit should build on its own and leave the repo working where possible.
- Messages short, technical and accurate, conventional style (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`). Say exactly what changed. Example: `feat(term): spawn ssh panes via LocalProcessTerminalView with tmux attach`.
- No Co-Authored-By lines and no Claude or AI attribution in any commit. Commits are authored by the user's git config.
- Stay on `main`, clean and linear, ready to push as is. No remote yet, do not add one.
- Never commit build output (`.build/`, `build/`, `*.app`, DerivedData), secrets, hostnames beyond the `pc` alias, IPs, usernames, or anything from `~/.ssh`. The system map and machine specific config stay out of the repo (gitignored). Only templates and examples go in.

## Style

- Casual, direct copy in UI and docs. No em dashes anywhere (code comments, UI, README).
- Elegant and fast beats feature-rich.
