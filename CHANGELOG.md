# Changelog

## v0.1.0

First public release.

- Native macOS app with project windows and tabs: Panes (a grid of terminals running
  Claude Code or a shell, each in tmux on its own host, local or over ssh), Station,
  Orchestrator, Sessions and Activity.
- Any number of machines from `~/.config/crossagent/hosts.json`, added on first run.
- Broadcast and relay between panes, layout persistence, reattach after relaunch.
- Orchestrator canvas built from Claude Code hooks and transcripts: native subagents,
  remote workers with Brief, Result and Terminal tabs, and approval cards.
- The crossagent Claude Code skill: native subagents for local work, a `<host>-worker`
  subagent that runs a headless Claude Code on another machine through `ca remote`
  (written briefs, follow-ups in the same conversation, permission requests answered in
  the app), `ca run` for plain commands, and the Crossover Portal for live project sync
  with Mutagen.
- Optional claude wrapper so every interactive `claude` lives in tmux and can be viewed
  from several places.
