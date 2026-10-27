<!-- crossagent template v2 -->
# CrossAgent: one orchestrator, subagents on the Mac and the PC

This project runs on two machines. You, the main Claude Code session, are the
orchestrator. You plan, split the work, brief subagents, check what they did and stay
in control. Specs, tool versions and paths for both machines are in
`.crossagent/system-map.md`. Read it before planning anything heavy.

`ca` below is short for `~/.claude/skills/crossagent/scripts/ca`. Always write that
full path (the permission allowlist matches it).

## Which machine

Go by how the user says it:

- "local", "mac", "this mac", "on my mac": Mac only.
- "pc", "ssh", "overseas", "my pc", "on my pc": PC only.
- Nothing named: use both and split by what each machine is good at.

`ca host <word>` turns a nickname into `mac`, `pc` or `both` if you're unsure.

Default split (check the map for real numbers):
- PC (8-core Ryzen, NVIDIA GPU, Linux x86): heavy builds, full test suites,
  benchmarks, long runs, GPU work, docker, Linux specific work.
- Mac (Apple Silicon, the user's machine): UI, Xcode, Swift and macOS specific work, quick
  edits and checks, anything touching the user's apps, keychain or accounts.

Don't ship tiny jobs to the PC just to use it. Each handoff costs a Portal flush and a
fresh worker that has to read the code.

## Subagents on this machine: native, always

Local work is Claude Code's own subagents: the Agent tool, the custom agents in
`.claude/agents/`, `run_in_background: true` when you want to keep working meanwhile.
They show up in Claude Code's agent list and on the CrossAgent canvas under you.

- Never start another `claude` process or tmux session for local work. No `ca run` with
  Claude in it, no `claude -p` in Bash, no `claude` in a new terminal.
- Use plain Agent subagents, not agent teams. If teams are on, they must stay
  in-process (`ca init` pins `teammateMode: in-process` for this project).
- SendMessage continues a subagent (running or finished) with its context.

## Subagents on the other machine: pc-worker

PC work goes through the `pc-worker` subagent (`mac-worker` when you run on the PC).
You call it with the Agent tool like any other subagent. Inside, it runs
`ca remote pc <role>`, which starts ONE headless Claude Code on the PC in tmux session
`ca-<project>-pc-<role>` (the user can watch it live in CrossAgent), waits, and hands
you its report verbatim. It's one subagent from your side and one process on the PC.

1. Pick a role name for the job, like `tests` or `bench` (letters, digits, `-`, `_`).
2. Write the brief to `.crossagent/briefs/<role>.md` with the Write tool, from
   `ca remote template`. Every section filled in (see below).
3. Agent tool: `subagent_type: pc-worker`, a short `description` ("Running tests on
   PC"), prompt `role: tests, brief: .crossagent/briefs/tests.md` plus any options
   (`--allow "Bash(cargo bench:*)"`, `--model sonnet`). Set `run_in_background: true`
   to keep working locally while the PC runs; you get notified when it reports.
4. Review the report (see "Stay in control").
5. Follow-ups to the same worker: write `.crossagent/briefs/<role>-2.md`, then
   SendMessage to that pc-worker: `follow-up, brief: .crossagent/briefs/<role>-2.md`.
   It runs `ca remote pc <role> --continue`, which resumes the SAME headless
   conversation (`claude -p --resume <id>`), so the worker remembers everything. If
   that pc-worker is gone, start a new one with the same role and say it's a follow-up.

Never run the task on the PC any other way (no `ssh pc claude ...`).

### The brief

The worker starts with zero context. Brief it the way a good lead briefs someone new.
`ca remote` adds a fixed header on top (it's a subagent, which machine and folder,
the fixed rules, the report format), and refuses a brief that's missing a section:

- **Goal:** one or two sentences on what done looks like.
- **Context:** what you've learned that this task needs: decisions, findings, file
  locations, gotchas, what other agents are doing. Written out, never "see above".
- **Files:** the exact working directory on the PC (the Portal path from the map),
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

### Permissions on the PC worker

The headless worker runs with `--permission-mode acceptEdits`. Anything else that
needs approval shows as an approval card on its node in CrossAgent (Allow / Deny).
No answer in 5 minutes means denied. `ca remote answer pc <id> allow|deny` answers
from a terminal. Expect a prompt for most shell commands, so for a long job pass
`--allow` rules for the commands the brief needs (`--allow "Bash(npm test:*)"`).
Never use bypass or dangerously-skip-permissions.

## Stay in control

You're the lead. Subagents report, you decide.

- Split by file ownership. Two agents never edit the same file at the same time, and
  every brief says who owns what.
- Read every report critically. Check the claims yourself before accepting them:
  read the diff (`git diff` on the Mac), rerun the key check (a test, a build, a
  grep), compare numbers against the real output.
- If something's wrong or missing, send a follow-up to the SAME worker with exactly
  what to fix, until it's right. Don't quietly redo it yourself unless that's faster.
- Tell the user which machine did what, what you verified, and what's still open.

## Crossover Portal

When work is split across both machines, the project is mirrored live through the
Crossover Portal (Mutagen session `ca-<project>`, two-way-safe) at the same path under
home on both machines. `ca init` opens it.

- `ca remote` flushes the Portal before the worker starts and after it reports, so
  both sides see the same files. `ca run` and `ca wait` flush too.
- A conflict stops everything (exit 3). Show the user `ca portal conflicts`. Never
  overwrite or delete one side yourself.
- Build output and dependencies stay per machine (`node_modules`, `.build`, `build`,
  `target`, `dist`, `.venv`...). Each side builds its own.
- Secrets (`.env`, `.env.*`, `*.pem`, `*.key`, `id_*`) don't cross unless the project
  opts in with `sync_allow=` in `.crossagent/project`. `.crossagent/` never crosses.
- Git lives on the Mac only. `.git` never crosses, and nothing on the PC commits or
  pushes. Review what a PC worker changed on the Mac before committing.

Running on the PC itself: the PC can't reach the Mac, so everything stays on the PC
and local native subagents do all of it.

## Plain commands

For a build, test run or script with no Claude in it, `ca run` is enough:

```
ca run pc tests -- make test          # command on the PC in tmux ca-<project>-pc-tests
ca run mac build -- "make && ls"      # one string runs through bash -c
ca wait pc tests mac build            # waits up to 110 s per call, prints results
ca logs pc tests 100
ca stop pc tests
```

## Commands

```
~/.claude/skills/crossagent/scripts/ca init                       # set up, safe to re-run
~/.claude/skills/crossagent/scripts/ca remote template            # the brief template
~/.claude/skills/crossagent/scripts/ca remote status pc           # remote workers and pending approvals
~/.claude/skills/crossagent/scripts/ca remote answer pc <id> allow
~/.claude/skills/crossagent/scripts/ca remote stop pc <role>
~/.claude/skills/crossagent/scripts/ca status                     # all ca-* tmux sessions
~/.claude/skills/crossagent/scripts/ca portal status|flush|conflicts
```

The pc-worker subagent runs `ca remote pc <role> ...` and `ca remote wait` for you.
