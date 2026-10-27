# Contributing

Thanks for taking a look. CrossAgent is small on purpose, so the bar for new
features is "does it make the core loop faster or clearer".

## Build and test

```sh
swift build && swift test
skills/crossagent/tests/run.sh          # the skill's offline tests
swift build -c release && scripts/bundle.sh
```

Debug builds have a dev automation channel (`CROSSAGENT_AUTOMATION=1`, driven by
`scripts/automation.sh`) for scripted checks. Release builds don't contain it.

## Ground rules

- Read `docs/SPEC.md`, and skim `docs/DECISIONS.md` for why things are the way they are.
  Log new judgment calls there.
- No new dependencies, plugins or networking layers. SwiftTerm, the system `ssh`,
  tmux and plain scripts do the heavy lifting.
- The skill stays bash plus python3 stdlib, and works on macOS's /bin/bash 3.2.
- Small commits with conventional messages (`feat(term): ...`, `fix(skill): ...`).
- Casual, direct copy in the UI and docs. No em dashes.
- Never commit build output, secrets or machine specific config (`hosts.json`,
  `system-map.md`, `.crossagent/`).

## Reporting security issues

Please don't open a public issue for anything that lets another local user or a
remote machine control CrossAgent or approve a worker's actions. Open a private
security advisory on GitHub instead.
