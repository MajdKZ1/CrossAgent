# CrossAgent: splitting work across the Mac and the PC

This project runs on two machines. Use the crossagent skill and its `ca` script
(`~/.claude/skills/crossagent/scripts/ca`, always call it by that exact path) to
spread work across them. Specs, tool versions and paths for both machines are in
`.crossagent/system-map.md` (a copy of `~/.config/crossagent/system-map.md`). Read it
before planning anything heavy.

## Which machine

Look at how the user phrases it:

- "local", "mac", "this mac", "on my mac": Mac only.
- "pc", "ssh", "overseas", "my pc", "on my pc": PC only.
- No machine named: split the work across both so they run in parallel.

`ca host <word>` turns a nickname into `mac`, `pc` or `both` if you're unsure.

## How to split

Check the map for real specs. Usually the PC is the bigger Linux x86 box with headroom to burn,
and the Mac is the user's own machine. So by default send to the PC:
- heavy builds, full test suites, long runs, benchmarks
- Linux or x86 specific work, docker, servers
- big parallel jobs, anything that would make the Mac hot or slow

Keep on the Mac (Apple Silicon, the user's machine):
- UI work, Xcode, Swift, macOS specific stuff, anything that needs the user's screen
- quick edits and small checks (just do them directly, no tmux needed)
- anything that touches the user's apps, keychain or local accounts

Split independent pieces so both machines work at the same time, for example tests on
the PC while you build or edit on the Mac. Don't split work that has to happen in order,
and don't ship tiny jobs to the PC just to use it, each round trip costs a second or two.
Use your judgment.

## Live sync

When work is split across both machines, the project is mirrored live with Mutagen
(session `ca-<project>`, two-way-safe) at the same path under home on both machines, so a
file written on one side shows up on the other in a second or two. `ca init` starts it.
Single machine work (Mac only or PC only) doesn't sync.

- Split work by file ownership. Two machines never edit the same file in the same task.
  Give each task its own files or folders and say so in the task prompt.
- Run `ca sync flush` before handing a task to the other machine and before using its
  results. `ca run` and `ca wait` already do this for you.
- On a conflict, stop and report it to the user with `ca sync conflicts`. Never overwrite
  or delete one side to make it go away unless the user picked which side wins.
- Build output and dependencies are per machine (`node_modules`, `.build`, `build`, `target`,
  `dist`, `.venv` and friends never sync). Each side installs and builds its own.
- Secrets (`.env`, `.env.*`, `*.pem`, `*.key`, `id_*`) don't sync unless the project opts in
  with `sync_allow=` in `.crossagent/project`.
- Git only on the Mac. `.git` never syncs, the Mac is the source of truth for commits, and
  nothing on the PC ever runs `git commit` or `git push` in a synced folder.

## Rules

- The Mac is the source of truth for code. With live sync on, edits on either side cross
  over by themselves; review anything a PC worker changed on the Mac before committing.
  Without sync (PC only mode), `ca run pc` pushes the project first and
  `ca sync pull <paths>` brings files back.
- Every task runs in a tmux session `ca-<project>-<host>-<task>` (project = folder name as a
  short slug), which the user can watch in the CrossAgent viewing station. Short task names,
  letters, digits, `-` and `_`, up to 40 chars.
- Output goes to `.crossagent/logs/<task>.log` and a short result to
  `.crossagent/results/<task>.md` on the host that ran it. `ca wait` and `ca logs` read them back.
- Claude workers (`--claude`) run with `--permission-mode acceptEdits`. If one stops on a
  permission prompt or a trust dialog, tell the user to answer it in the viewing station.
- Running on the PC itself: the PC can't reach the Mac, so everything stays on the PC.

## Commands

Write the full path every time (no shell variables, it keeps the permission allowlist happy):

```
~/.claude/skills/crossagent/scripts/ca init                                # once per project, safe to re-run
~/.claude/skills/crossagent/scripts/ca run pc tests -- make test           # command on the PC
~/.claude/skills/crossagent/scripts/ca run mac build -- "make build && ls" # one string runs through bash -c
~/.claude/skills/crossagent/scripts/ca run pc refactor --claude "prompt"   # Claude Code worker on the PC
~/.claude/skills/crossagent/scripts/ca wait pc tests mac build             # wait for both, prints results
~/.claude/skills/crossagent/scripts/ca logs pc tests 100
~/.claude/skills/crossagent/scripts/ca status
~/.claude/skills/crossagent/scripts/ca stop pc tests
~/.claude/skills/crossagent/scripts/ca sync status                         # live sync state per project
~/.claude/skills/crossagent/scripts/ca sync flush                          # sync now and wait, fails on conflicts
~/.claude/skills/crossagent/scripts/ca sync conflicts                      # what clashed, both sides' info
~/.claude/skills/crossagent/scripts/ca sync push                           # one-off copy when live sync is off
~/.claude/skills/crossagent/scripts/ca sync pull path/to/file
```
