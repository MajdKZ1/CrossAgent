---
name: crossagent
description: Split or run work across the user's Mac and their Linux PC (ssh pc). Local work goes to native Claude Code subagents, PC work to the pc-worker subagent (a headless Claude Code on the PC the user can watch in CrossAgent). Use when the user wants work spread over both machines, wants something run "on my pc", "overseas", "over ssh", "locally" or "on my mac", wants heavy builds or test suites offloaded to the PC, or mentions crossagent.
---

# crossagent

You orchestrate. Work on this machine goes to Claude Code's own subagents (Agent tool).
Work on the other machine goes to the `pc-worker` subagent (`mac-worker` from the PC),
which runs one headless Claude Code there through `ca remote` and returns its report.
Never start a new `claude` process or tmux session for local subagent work.

Everything goes through one script. Always call it by this exact path, never through a
shell variable (the permission allowlist matches the literal path):

`~/.claude/skills/crossagent/scripts/ca`

Below, `ca` is short for that path.

## Steps

1. Pick the machines from the user's words:
   - "local", "mac", "this mac", "on my mac": Mac only.
   - "pc", "ssh", "overseas", "my pc", "on my pc": PC only.
   - nothing named: use both, split by machine strengths. `ca host <word>` resolves a
     nickname if unsure.
2. In the project root run `ca init` for both, `ca init mac` for Mac only or
   `ca init pc` for PC only. It installs `CROSSAGENT.md`, points `CLAUDE.md` at it,
   puts the `pc-worker` and `mac-worker` definitions in `~/.claude/agents/`, keeps agent
   teams in-process, refreshes the system map and (for both) opens the Crossover
   Portal. It starts no sessions. Cheap enough to run every time.
3. Read `CROSSAGENT.md` and `.crossagent/system-map.md`. They're the rules: native
   subagents locally, pc-worker for the PC, the brief template, split by file
   ownership, verify every report yourself.
4. For each PC job: write a brief to `.crossagent/briefs/<role>.md` from
   `ca remote template` (Goal, Context, Files, Task, Constraints, Verification, all
   filled in), then call the Agent tool with `subagent_type: pc-worker` and the prompt
   `role: <role>, brief: .crossagent/briefs/<role>.md`. Background it
   (`run_in_background: true`) to keep working locally.
5. Check the report: read the diff, rerun the key checks. Send fixes to the same
   worker (SendMessage, `follow-up, brief: <file>`), which resumes the same PC
   conversation.
6. On a Portal conflict (exit 3) stop and show the user `ca portal conflicts`. Don't
   pick a side yourself.
7. Report back which machine did what, what you verified, and what's open.

## Notes

- Plain commands with no Claude in them: `ca run <host> <task> -- cmd`, then
  `ca wait <host> <task>`. `ca run --claude` is gone.
- The Mac is the source of truth and the only place git runs. Nothing on the PC
  commits or pushes.
- PC worker permissions: `acceptEdits`, plus approval cards in CrossAgent for the rest
  (5 minutes, then denied). `--allow "Bash(cmd:*)"` pre-approves what a brief needs.
  `ca remote answer pc <id> allow|deny` answers from a terminal.
- `ca remote status pc` lists remote workers, their turns, session ids and pending
  approvals. `ca remote stop pc <role>` stops one (its conversation can be continued).
- If this runs on the PC (Linux), it works PC only, because the PC can't reach the Mac.
  Local native subagents do everything. Say so.
- Role and task names: up to 40 chars of letters, digits, `-` and `_`.
- `ca help` lists everything. `ca status` shows all `ca-*` sessions on both machines.
- `ca sync ...` is the old name for `ca portal ...` and still works.
- claude wrapper (optional, `install.sh --wrapper`, undo with `install.sh --remove-wrapper`,
  both take `--mac` / `--pc`): typing `claude` in an interactive shell starts it in a tmux
  session `ca-<project>-<host>-<n>` and attaches, so several terminals or the app can view
  the same session. It runs claude plain with `-p`, `--version`, `--help`, subcommands,
  piped input or output, and with `CLAUDE_NO_TMUX=1`. `command claude` always skips it.
- Remote workers log RemoteStart, RemoteActivity, RemoteStop and permission events to
  `~/.crossagent/events/<session>.jsonl` on the machine they run on, which the CrossAgent
  app turns into one node per worker.
