---
name: crossagent
description: Split or run work across the user's Mac and their Linux PC (ssh pc) in tmux sessions. Use when the user wants work spread over both machines, wants something run "on my pc", "overseas", "over ssh", "locally" or "on my mac", wants heavy builds or test suites offloaded to the PC, or mentions crossagent.
---

# crossagent

Runs pieces of work on the Mac and the Linux PC in tmux sessions named `ca-<host>-<task>`,
so the user can watch them in the CrossAgent viewing station. Everything goes through one
script. Always call it by this exact path, never through a shell variable (the permission
allowlist matches the literal path):

`~/.claude/skills/crossagent/scripts/ca`

Below, `ca` is short for that path.

## Steps

1. In the project root run `~/.claude/skills/crossagent/scripts/ca init`. It installs
   `CROSSAGENT.md`, points `CLAUDE.md` at it, creates or refreshes the system map on both
   machines and pushes the project to the PC. Cheap enough to run every time.
2. Read `CROSSAGENT.md` and `.crossagent/system-map.md`. They say what goes where.
3. Pick the host from the user's words:
   - "local", "mac", "this mac", "on my mac": Mac only.
   - "pc", "ssh", "overseas", "my pc", "on my pc": PC only.
   - nothing named: split across both. `ca host <word>` resolves a nickname if unsure.
4. Start the pieces, all before waiting, so they run in parallel:
   - `ca run pc tests -- make test` (pushes the project to the PC first)
   - `ca run mac build -- make build`
   - `ca run pc fix-lint --claude "fix the lint errors in src/"` for a Claude Code worker
5. `ca wait pc tests mac build` until they finish. It waits up to 110 s per call, so if it
   says "still running", call it again. It prints each result and exits non zero if any task failed.
   `ca logs <host> <task> [lines]` shows more output.
6. If a PC task changed files you need, `ca sync pull <paths>` brings them back to the Mac.
7. Report back which machine did what and the results. Leave the tmux sessions running
   unless the user asks to stop them (`ca stop <host> <task>`).

## Notes

- One command string after `--` runs through `bash -c`, so `-- "npm ci && npm test"` works.
- The Mac is the source of truth. Don't edit code on the PC by hand, edit on the Mac and push.
- Claude workers run with `--permission-mode acceptEdits`. A blocked prompt shows as
  waiting for input in the viewing station, tell the user.
- If this runs on the PC (Linux), it works PC only, because the PC can't reach the Mac.
  Say so.
- `ca help` lists everything. `ca status` shows all `ca-*` sessions on both machines.
