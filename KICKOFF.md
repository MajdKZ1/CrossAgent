Paste this into Claude Code from inside ~/CrossAgent:

---

Read CLAUDE.md and docs/SPEC.md. You are the orchestrator for this repo. Build CrossAgent v0.1 milestone by milestone (M0 to M5) using the subagents in .claude/agents. Run work in parallel where files do not overlap. After each milestone: build, have verifier check it, fix what fails, commit. Log any judgment calls in docs/DECISIONS.md. Do not stop until every v0.1 acceptance criterion passes, then give me a short summary of what works, what you tested on the PC, and the commit log.
