#!/usr/bin/env bash
# Install the crossagent skill into ~/.claude/skills/crossagent on the Mac and the PC.
# Safe to re-run. Usage: install.sh [--mac | --pc]
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills/crossagent"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/crossagent-%C -o ControlPersist=10m"

do_mac=1; do_pc=1
case "${1:-}" in
  --mac) do_pc=0 ;;
  --pc) do_mac=0 ;;
  "") ;;
  *) echo "usage: install.sh [--mac | --pc]" >&2; exit 2 ;;
esac

chmod +x "$SRC/install.sh" "$SRC/scripts/ca"

if [ "$do_mac" = 1 ]; then
  if [ "$SRC" = "$(cd "$DEST" 2>/dev/null && pwd)" ]; then
    echo "mac: already running from $DEST"
  else
    mkdir -p "$DEST"
    rsync -a --delete --exclude=.DS_Store "$SRC/" "$DEST/"
    echo "mac: installed to ~/.claude/skills/crossagent"
  fi
fi

if [ "$do_pc" = 1 ]; then
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -o ConnectTimeout=20 pc 'mkdir -p ~/.claude/skills/crossagent'
  rsync -a --delete --exclude=.DS_Store -e "ssh $SSH_OPTS" "$SRC/" pc:.claude/skills/crossagent/
  echo "pc: installed to ~/.claude/skills/crossagent"
fi
