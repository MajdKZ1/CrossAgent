<!-- crossagent template v3 -->
# CrossAgent: one orchestrator, subagents on several machines

This project runs on more than one machine. You, the main Claude Code session, are the
orchestrator. You plan, split the work, brief subagents, check what they did and stay
in control. Every machine (host) is in `.crossagent/system-map.md` with its id, how to
reach it, its specs, tool versions and paths. Read it before planning anything heavy.

`ca` below is short for `~/.claude/skills/crossagent/scripts/ca`. Always write that
full path (the permission allowlist matches it).

## Which machine

Go by how the user says it:

- "local", "here", "this machine", "on my mac": this machine only.
- A host's id or name ("on my pc", "the build box"): that host only.
- "remote", "ssh", "overseas", "the other machine": the only ssh host, if there's just one.
- Nothing named: use all of them and split by what each machine is good at.

`ca host <word>` turns a nickname into a host id (or `all`) if you're unsure, and
`ca hosts` lists them.

Split by the numbers in the map: heavy builds, full test suites, benchmarks, long runs,
GPU work and docker go to the machine with more cores, RAM or a GPU. OS specific work
goes to the machine with that OS. UI work, quick edits and checks, and anything touching
the user's own apps, keychain or accounts stay on this machine.

Don't ship tiny jobs to another host just to use it. Each handoff costs a Portal flush
and a fresh worker that has to read the code.

## Subagents on this machine: native, always

Local work is Claude Code's own subagents: the Agent tool, the custom agents in
`.claude/agents/`, `run_in_background: true` when you want to keep working meanwhile.
They show up in Claude Code's agent list and on the CrossAgent canvas under you.

- Never start another `claude` process or tmux session for local work. No `ca run` with
  Claude in it, no `claude -p` in Bash, no `claude` in a new terminal.
- Use plain Agent subagents, not agent teams. If teams are on, they must stay
  in-process (`ca init` pins `teammateMode: in-process` for this project).
- SendMessage continues a subagent (running or finished) with its context.

## Subagents on other machines: `<host>-worker`

Each ssh host has its own worker subagent, named after its id: `<host>-worker` (so host
`pc` has `pc-worker`). You call it with the Agent tool like any other subagent. Inside,
it runs `ca remote <host> <role>`, which starts ONE headless Claude Code on that host in
tmux session `ca-<project>-<host>-<role>` (the user can watch it live in CrossAgent),
waits, and hands you its report verbatim. It's one subagent from your side and one
process on the host.

1. Pick a role name for the job, like `tests` or `bench` (letters, digits, `-`, `_`).
2. Write the brief to `.crossagent/briefs/<role>.md` with the Write tool, from
   `ca remote template`. Every section filled in (see below).
3. Agent tool: `subagent_type: <host>-worker`, a short `description` ("Running tests on
   pc"), prompt `role: tests, brief: .crossagent/briefs/tests.md` plus any options
   (`--allow "Bash(cargo bench:*)"`, `--model sonnet`). Set `run_in_background: true`
   to keep working locally while the host runs; you get notified when it reports.
4. Review the report (see "Stay in control").
5. Follow-ups to the same worker: write `.crossagent/briefs/<role>-2.md`, then
   SendMessage to that worker: `follow-up, brief: .crossagent/briefs/<role>-2.md`.
   It runs `ca remote <host> <role> --continue`, which resumes the SAME headless
   conversation (`claude -p --resume <id>`), so the worker remembers everything. If
   that worker is gone, start a new one with the same role and say it's a follow-up.
   Starting a role again WITHOUT the follow-up wipes its old conversation, so only do
   that for new work.

Never run the task on a host any other way (no `ssh <host> claude ...`).

### The brief

The worker starts with zero context. Brief it the way a good lead briefs someone new.
`ca remote` adds a fixed header on top (it's a subagent, which machine and folder,
the fixed rules, the report format), and refuses a brief that's missing a section:

- **Goal:** one or two sentences on what done looks like.
- **Context:** what you've learned that this task needs: decisions, findings, file
  locations, gotchas, what other agents are doing. Written out, never "see above".
- **Files:** the exact working directory on the host (the Portal path from the map),
  the files this worker owns and may edit, and the files it must NOT touch because
  other agents own them.
- **Task:** concrete steps and how to do them: tools, commands, conventions, style
  rules from CLAUDE.md.
- **Constraints:** anything beyond the fixed rules (allowed installs, limits).
- **Verification:** what to run to prove it works before reporting, and what passing
  looks like.

Fixed rules the header already gives every worker: never git commit or push, stay in
its folder, no system installs unless the brief allows, no ssh or security changes,
no em dashes, only its own files, report in this shape: Summary, Files changed,
Commands run, Verification, Problems or decisions, Next steps for the orchestrator.

### Permissions on remote workers

A headless worker runs with `--permission-mode acceptEdits`. Anything else that needs
approval shows as an approval card on its node in CrossAgent (Allow / Deny). No answer
in 5 minutes means denied. `ca remote answer <host> <id> allow|deny` answers from a
terminal. Expect a prompt for most shell commands, so for a long job pass `--allow`
rules for the commands the brief needs (`--allow "Bash(npm test:*)"`). Never use
bypass or dangerously-skip-permissions.

## Stay in control

You're the lead. Subagents report, you decide.

- Split by file ownership. Two agents never edit the same file at the same time, and
  every brief says who owns what.
- Read every report critically. Check the claims yourself before accepting them:
  read the diff (`git diff` here), rerun the key check (a test, a build, a grep),
  compare numbers against the real output.
- If something's wrong or missing, send a follow-up to the SAME worker with exactly
  what to fix, until it's right. Don't quietly redo it yourself unless that's faster.
- Tell the user which machine did what, what you verified, and what's still open.

## Crossover Portal

When work is split across machines, the project is mirrored live to each ssh host
through the Crossover Portal (a two-way-safe Mutagen session, `ca-<project>` for the
first ssh host and `ca-<project>-<host>` for any other) at the same path under home.
`ca init` opens them.

- `ca remote` flushes the host's Portal before the worker starts and after it reports,
  so both sides see the same files. `ca run` and `ca wait` flush too. Without a Portal
  (one host only mode) a new worker gets a one-off push, a follow-up doesn't (it would
  overwrite the worker's edits), so pull what you need with
  `ca portal pull --host <host> <paths>`.
- A conflict stops everything (exit 3). Show the user `ca portal conflicts`. Never
  overwrite or delete one side yourself.
- Build output and dependencies stay per machine (`node_modules`, `.build`, `build`,
  `target`, `dist`, `.venv`...). Each side builds its own.
- Secrets (`.env`, `.env.*`, `*.pem`, `*.key`, `id_*`) don't cross unless the project
  opts in with `sync_allow=` in `.crossagent/project`. `.crossagent/` never crosses.
- Git lives on this machine only. `.git` never crosses, and nothing on another host
  commits or pushes. Review what a worker changed here before committing.

Running on a host that can't reach the others (the map says which): everything stays
on that machine and local native subagents do all of it.

## Plain commands

For a build, test run or script with no Claude in it, `ca run` is enough (`pc` here is
just an example host id, use the ones from the map):

```
ca run pc tests -- make test          # command on host pc in tmux ca-<project>-pc-tests
ca run mac build -- "make && ls"      # one string runs through bash -c
ca wait pc tests mac build            # waits up to 110 s per call, prints results
ca logs pc tests 100
ca stop pc tests
```

## Commands

```
~/.claude/skills/crossagent/scripts/ca init                       # set up, safe to re-run
~/.claude/skills/crossagent/scripts/ca hosts                      # the machines
~/.claude/skills/crossagent/scripts/ca remote template            # the brief template
~/.claude/skills/crossagent/scripts/ca remote status              # remote workers and pending approvals
~/.claude/skills/crossagent/scripts/ca remote answer <host> <id> allow
~/.claude/skills/crossagent/scripts/ca remote stop <host> <role>
~/.claude/skills/crossagent/scripts/ca status                     # all ca-* tmux sessions
~/.claude/skills/crossagent/scripts/ca portal status|flush|conflicts
```

The `<host>-worker` subagents run `ca remote <host> <role> ...` and `ca remote wait` for you.
