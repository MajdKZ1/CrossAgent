#!/usr/bin/env bash
# Install the crossagent skill into ~/.claude/skills/crossagent on this machine and on every
# ssh host in ~/.config/crossagent/hosts.json, with a <host>-worker subagent per host in
# ~/.claude/agents on each side. Safe to re-run.
# Usage: install.sh [--local] [--host <id>]... [--wrapper | --remove-wrapper]
#   --local           this machine only
#   --host <id>       that ssh host only (repeat for more). --mac and --pc still work as
#                     old names for --local and --host pc
#   --wrapper         also hook the claude tmux wrapper into ~/.zshrc / ~/.bashrc
#   --remove-wrapper  only take the wrapper hook out again (skill stays installed)
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills/crossagent"
CA="$SRC/scripts/ca"
# Same ControlPath as ca and the CrossAgent app, so they share one ssh connection per host.
SSH_OPTS="-o ControlMaster=auto -o ControlPath=~/.crossagent/ssh/%C -o ControlPersist=10m"
(umask 077 && mkdir -p "$HOME/.crossagent/ssh")
chmod 700 "$HOME/.crossagent" "$HOME/.crossagent/ssh"

usage() { echo "usage: install.sh [--local] [--host <id>]... [--wrapper | --remove-wrapper]" >&2; exit 2; }
q() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }

do_local=""; sel=""; picked=""; wrap=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local|--mac) do_local=1; picked=1 ;;
    --pc) sel="$sel pc"; picked=1 ;;
    --host)
      [ $# -ge 2 ] || usage
      case "$2" in ""|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) echo "install.sh: bad host id '$2'" >&2; exit 2 ;; esac
      sel="$sel $2"; picked=1; shift ;;
    --wrapper) wrap=add ;;
    --remove-wrapper) wrap=remove ;;
    *) usage ;;
  esac
  shift
done
[ -n "$picked" ] || do_local=1

# Add or remove the marked block that sources the wrapper. Runs on any machine (shipped
# to ssh hosts with declare -f). Only touches the marked lines.
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

# First run with no hosts.json: ask once for another machine (blank keeps it to this one).
if [ -z "$picked" ] && [ "$wrap" != remove ] && [ ! -e "$HOME/.config/crossagent/hosts.json" ]; then
  if [ -t 0 ]; then
    printf 'ssh target of another machine to work on (an alias from ~/.ssh/config, host or user@host), blank for this machine only: ' >&2
    read -r tgt || tgt=""
    if [ -n "$tgt" ]; then
      id="$(printf %s "$tgt" | sed 's/^.*@//; s/\..*$//' | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -cs 'a-z0-9_' '-' | sed 's/^-*//; s/-*$//' | cut -c1-40)"
      "$CA" hosts add "${id:-remote}" "$tgt" \
        || echo "couldn't add $tgt, so this machine only for now. Add it later with: ca hosts add <id> <ssh-target>, then run install.sh again" >&2
    fi
  else
    echo "no ~/.config/crossagent/hosts.json yet, so this machine only. Add another with: ~/.claude/skills/crossagent/scripts/ca hosts add <id> <ssh-target>, then run install.sh again" >&2
  fi
fi

HOSTS="$("$CA" __hosts)"
HUB="$(printf '%s\n' "$HOSTS" | head -1 | cut -f1)"
field() { printf '%s\n' "$HOSTS" | awk -F'\t' -v i="$1" -v f="$2" '$1 == i && $2 == "ssh" { print $f; exit }'; }
if [ -n "$picked" ]; then
  for h in $sel; do [ -n "$(field "$h" 3)" ] || { echo "install.sh: no ssh host '$h' in ~/.config/crossagent/hosts.json (see ca hosts)" >&2; exit 2; }; done
  targets="$sel"
else
  targets="$(printf '%s\n' "$HOSTS" | awk -F'\t' '$2 == "ssh" { print $1 }')"
fi

RSYNC=(rsync -a --delete --exclude=.DS_Store --exclude=/tests/ --exclude=__pycache__)

if [ -n "$do_local" ]; then
  if [ "$wrap" != remove ]; then
    if [ "$SRC" = "$(cd "$DEST" 2>/dev/null && pwd)" ]; then
      echo "$HUB: already running from $DEST"
    else
      mkdir -p "$DEST"
      "${RSYNC[@]}" "$SRC/" "$DEST/"
      echo "$HUB: installed to ~/.claude/skills/crossagent"
    fi
    "$DEST/scripts/ca" __agents
  fi
  [ -z "$wrap" ] || rc_blocks "$wrap" "$HUB"
fi

fail=0
for h in $targets; do
  t="$(field "$h" 3)"
  if [ "$wrap" != remove ]; then
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS -o ConnectTimeout=20 -- "$t" 'mkdir -p ~/.claude/skills/crossagent' < /dev/null; then
      echo "$h: can't reach it with ssh $t, skipped" >&2; fail=1; continue
    fi
    # No -- in -e (rsync may add -l user before the host); ca hosts add refuses targets starting with -.
    "${RSYNC[@]}" -e "ssh $SSH_OPTS" "$SRC/" "$t:.claude/skills/crossagent/"
    echo "$h: installed to ~/.claude/skills/crossagent"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -- "$t" "CA_HERE=$h ~/.claude/skills/crossagent/scripts/ca __setup_remote $HUB $(q "$(field "$h" 4)")" < /dev/null
  fi
  if [ -n "$wrap" ]; then
    # shellcheck disable=SC2086
    { declare -f rc_blocks; echo "rc_blocks $wrap $h"; } | ssh $SSH_OPTS -o ConnectTimeout=20 -- "$t" bash -s
  fi
done
exit "$fail"
