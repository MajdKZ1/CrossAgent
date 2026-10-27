#!/usr/bin/env bash
# Install the crossagent skill into ~/.claude/skills/crossagent on the Mac and the PC,
# and its pc-worker / mac-worker subagents into ~/.claude/agents. Safe to re-run. Usage: install.sh [--mac | --pc] [--wrapper | --remove-wrapper]
#   --wrapper         also hook the claude tmux wrapper into ~/.zshrc / ~/.bashrc
#   --remove-wrapper  only take the wrapper hook out again (skill stays installed)
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills/crossagent"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/crossagent-%C -o ControlPersist=10m"

usage() { echo "usage: install.sh [--mac | --pc] [--wrapper | --remove-wrapper]" >&2; exit 2; }

do_mac=1; do_pc=1; wrap=""
for arg in "$@"; do
  case "$arg" in
    --mac) do_pc=0 ;;
    --pc) do_mac=0 ;;
    --wrapper) wrap=add ;;
    --remove-wrapper) wrap=remove ;;
    *) usage ;;
  esac
done
[ "$do_mac$do_pc" = 00 ] && usage

# Add or remove the marked block that sources the wrapper. Runs on either machine
# (shipped to the PC with declare -f). Only touches the marked lines.
rc_blocks() {
  local mode="$1" host="$2" rc f found=""
  local start='# >>> crossagent claude wrapper >>>'
  local end='# <<< crossagent claude wrapper <<<'
  local line='[ -f "$HOME/.claude/skills/crossagent/scripts/claude-wrapper.sh" ] && . "$HOME/.claude/skills/crossagent/scripts/claude-wrapper.sh"'
  for rc in .zshrc .bashrc; do
    f="$HOME/$rc"
    [ -f "$f" ] || continue
    found=1
    if [ "$mode" = add ]; then
      if grep -qxF "$start" "$f"; then
        echo "$host: ~/$rc already has the wrapper block"
        continue
      fi
      [ -n "$(tail -c1 "$f")" ] && printf '\n' >> "$f"
      printf '%s\n%s\n%s\n' "$start" "$line" "$end" >> "$f"
      echo "$host: added the wrapper block to ~/$rc"
    else
      if ! grep -qxF "$start" "$f"; then
        echo "$host: ~/$rc has no wrapper block"
        continue
      fi
      awk -v s="$start" -v e="$end" '$0 == s { skip = 1; next } skip && $0 == e { skip = 0; next } !skip' "$f" > "$f.ca-tmp"
      cat "$f.ca-tmp" > "$f"
      rm -f "$f.ca-tmp"
      echo "$host: removed the wrapper block from ~/$rc"
    fi
  done
  if [ -z "$found" ] && [ "$mode" = add ]; then
    rc=.zshrc
    case "${SHELL:-}" in */bash) rc=.bashrc ;; esac
    printf '%s\n%s\n%s\n' "$start" "$line" "$end" > "$HOME/$rc"
    echo "$host: created ~/$rc with the wrapper block"
  fi
}

chmod +x "$SRC/install.sh" "$SRC/scripts/ca" "$SRC/scripts/"ca-*.py

# Only our two agent files. Other agents in ~/.claude/agents are never touched.
AGENTS=()
for a in pc-worker mac-worker; do [ -f "$SRC/agents/$a.md" ] && AGENTS+=("$SRC/agents/$a.md"); done
RSYNC=(rsync -a --delete --exclude=.DS_Store --exclude=/tests/ --exclude=__pycache__)

if [ "$do_mac" = 1 ]; then
  if [ "$wrap" != remove ]; then
    if [ "$SRC" = "$(cd "$DEST" 2>/dev/null && pwd)" ]; then
      echo "mac: already running from $DEST"
    else
      mkdir -p "$DEST"
      "${RSYNC[@]}" "$SRC/" "$DEST/"
      echo "mac: installed to ~/.claude/skills/crossagent"
    fi
    if [ "${#AGENTS[@]}" -gt 0 ]; then
      mkdir -p "$HOME/.claude/agents"
      cp "${AGENTS[@]}" "$HOME/.claude/agents/"
      echo "mac: installed the pc-worker and mac-worker agents to ~/.claude/agents"
    fi
  fi
  [ -n "$wrap" ] && rc_blocks "$wrap" mac
fi

if [ "$do_pc" = 1 ]; then
  if [ "$wrap" != remove ]; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -o ConnectTimeout=20 pc 'mkdir -p ~/.claude/skills/crossagent ~/.claude/agents'
    "${RSYNC[@]}" -e "ssh $SSH_OPTS" "$SRC/" pc:.claude/skills/crossagent/
    echo "pc: installed to ~/.claude/skills/crossagent"
    if [ "${#AGENTS[@]}" -gt 0 ]; then
      rsync -a -e "ssh $SSH_OPTS" "${AGENTS[@]}" pc:.claude/agents/
      echo "pc: installed the pc-worker and mac-worker agents to ~/.claude/agents"
    fi
  fi
  if [ -n "$wrap" ]; then
    # shellcheck disable=SC2086
    { declare -f rc_blocks; echo "rc_blocks $wrap pc"; } | ssh $SSH_OPTS -o ConnectTimeout=20 pc bash -s
  fi
fi
