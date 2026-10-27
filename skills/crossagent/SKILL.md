---
name: crossagent
description: Split or run work across this machine and the user's other machines over ssh (the hosts in ~/.config/crossagent/hosts.json). Local work goes to native Claude Code subagents, work on another host to its <host>-worker subagent (a headless Claude Code there that the user can watch in CrossAgent). Use when the user wants work spread over their machines, wants something run "on my pc", "on the server", "overseas", "over ssh", "remote", "locally" or "on my mac", wants heavy builds or test suites offloaded to a bigger machine, or mentions crossagent.
---

# crossagent

You orchestrate. Work on this machine goes to Claude Code's own subagents (Agent tool).
Work on another machine goes to that host's `<host>-worker` subagent (host `pc` has
`pc-worker`), which runs one headless Claude Code there through `ca remote` and returns
its report. Never start a new `claude` process or tmux session for local subagent work.

Everything goes through one script. Always call it by this exact path, never through a
shell variable (the permission allowlist matches the literal path):

`~/.claude/skills/crossagent/scripts/ca`

Below, `ca` is short for that path.

## Steps

1. Pick the machines from the user's words. `ca hosts` lists them, `ca host <word>`
   turns a nickname into a host id:
   - "local", "here", "this machine", "on my mac": this machine only.
   - a host's id or name ("on my pc"): that host only.
   - "remote", "ssh", "overseas": the only ssh host (ca asks for a name if there are several).
   - nothing named: all of them, split by machine strengths per the system map.
2. In the project root run `ca init` for all hosts, or `ca init <host>` for one. With
   this machine's id: no Portal. With one ssh host: a one-off push to it. It installs
   `CROSSAGENT.md`, points `CLAUDE.md` at it, writes a `<host>-worker` definition per
   ssh host to `~/.claude/agents/`, keeps agent teams in-process, refreshes the system
   map and (for all) opens a Crossover Portal to each ssh host. It starts no sessions.
   Cheap enough to run every time.
3. Read `CROSSAGENT.md` and `.crossagent/system-map.md`. They're the rules: native
   subagents locally, `<host>-worker` for other hosts, the brief template, split by
   file ownership, verify every report yourself.
4. For each job on another host: write a brief to `.crossagent/briefs/<role>.md` from
   `ca remote template` (Goal, Context, Files, Task, Constraints, Verification, all
   filled in), then call the Agent tool with `subagent_type: <host>-worker` and the
   prompt `role: <role>, brief: .crossagent/briefs/<role>.md`. Background it
   (`run_in_background: true`) to keep working locally.
5. Check the report: read the diff, rerun the key checks. Send fixes to the same
   worker (SendMessage, `follow-up, brief: <file>`), which resumes the same remote
   conversation.
6. On a Portal conflict (exit 3) stop and show the user `ca portal conflicts`. Don't
   pick a side yourself.
7. Report back which machine did what, what you verified, and what's open.

## Notes

- Hosts live in `~/.config/crossagent/hosts.json`, shared with the CrossAgent app.
  `ca hosts add <id> <ssh-target> [name]` adds one (ssh has to work without a prompt),
  `ca hosts remove <id>` takes it out. Then run `install.sh` again to put the skill there.
- Plain commands with no Claude in them: `ca run <host> <task> -- cmd`, then
  `ca wait <host> <task>`. `ca run --claude` is gone.
- This machine is the source of truth and the only place git runs. Nothing on another
  host commits or pushes.
- Remote worker permissions: `acceptEdits`, plus approval cards in CrossAgent for the
  rest (5 minutes, then denied). `--allow "Bash(cmd:*)"` pre-approves what a brief needs.
  `ca remote answer <host> <id> allow|deny` answers from a terminal.
- `ca remote status` lists remote workers, their turns, session ids and pending
  approvals. `ca remote stop <host> <role>` stops one (its conversation can be continued).
- Hosts can't reach back to the machine that set them up unless the user sets that up.
  Run on such a host, ca works on that host only and local native subagents do
  everything. Say so.
- Role and task names: up to 40 chars of letters, digits, `-` and `_`.
- `ca help` lists everything. `ca status` shows all `ca-*` sessions on every host.
- `ca sync ...` is the old name for `ca portal ...` and still works.
- claude wrapper (optional, `install.sh --wrapper`, undo with `install.sh --remove-wrapper`,
  both take `--local` / `--host <id>`): typing `claude` in an interactive shell starts it
  in a tmux session `ca-<project>-<host>-<n>` and attaches, so several terminals or the app
  can view the same session. It runs claude plain with `-p`, `--version`, `--help`,
  subcommands, piped input or output, and with `CLAUDE_NO_TMUX=1`. `command claude` always
  skips it.
- Remote workers log RemoteStart, RemoteActivity, RemoteStop and permission events to
  `~/.crossagent/events/<session>.jsonl` on the machine they run on, which the CrossAgent
  app turns into one node per worker.
