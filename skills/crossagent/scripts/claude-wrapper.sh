# crossagent claude wrapper. Sourced from ~/.zshrc / ~/.bashrc (interactive shells only),
# so scripts and the SDK never see it. Defines a `claude` function that runs Claude Code
# inside a tmux session named ca-<project>-<host>-<n> and attaches to it, so the same
# session can be watched from several places (terminal, CrossAgent app) at once.
#
# Runs the real claude unchanged when: already in tmux, CLAUDE_NO_TMUX=1, stdin or stdout
# isn't a terminal, tmux is missing, or the args mean non interactive use (-p, --version,
# subcommands...). `command claude` always skips the wrapper.
#
#   claude --ca-name NAME ...   use session NAME (attaches if it exists)

unalias claude 2>/dev/null

# Session options for ca-* sessions. Mirrored by the CrossAgent app, keep them in sync.
# (default-terminal is a server option in tmux 3.x and already tmux-256color, so it's left alone.)
_ca_wrap_session_opts() {
  tmux set -t "=$1:" status off \; \
    set -t "=$1:" mouse on \; \
    set -t "=$1:" prefix None \; \
    set -t "=$1:" prefix2 None \; \
    set -t "=$1:" destroy-unattached off >/dev/null 2>&1
}

# Server wide bits that can't be per session. Additive, only set when not already there.
_ca_wrap_server_opts() {
  [ "$(tmux show -sv set-clipboard 2>/dev/null)" = off ] || tmux set -s set-clipboard on
  tmux set -s focus-events on
  _ca_f="$(tmux show -s terminal-features 2>/dev/null | sed 's/^[^ ]* //; s/^"//; s/"$//')"
  for _ca_t in 'xterm-ghostty:RGB:clipboard:focus' 'xterm-256color:RGB'; do
    printf '%s\n' "$_ca_f" | grep -qxF "$_ca_t" || tmux set -as terminal-features "$_ca_t"
  done
  unset _ca_f _ca_t
}

# Same as slug() in scripts/ca and ProjectSlug.make in the app.
_ca_wrap_slug() {
  _ca_s="$(printf %s "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-16 | sed 's/-*$//')"
  echo "${_ca_s:-project}"
  unset _ca_s
}

claude() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L sh
  local bin a name="" plain="" n i v val

  bin="$HOME/.local/bin/claude"
  if [ -n "${ZSH_VERSION:-}" ]; then
    a="$(whence -p claude 2>/dev/null)"
  else
    a="$(type -P claude 2>/dev/null)"
  fi
  [ -n "$a" ] && bin="$a"

  if [ -n "${TMUX:-}" ] || [ "${CLAUDE_NO_TMUX:-}" = 1 ] || [ ! -t 0 ] || [ ! -t 1 ] \
    || ! command -v tmux >/dev/null 2>&1; then
    plain=1
  fi
  case "${1:-}" in
    agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|purge|\
    respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade) plain=1 ;;
  esac
  for a in "$@"; do
    case "$a" in
      --) break ;;
      -p|--print|-h|--help|-v|--version|--output-format|--output-format=*|\
      --bg|--background|--desktop|--tmux|--tmux=*) plain=1 ;;
    esac
  done

  # Pull out --ca-name, keep everything else in order.
  n=$#
  while [ "$n" -gt 0 ]; do
    a="$1"; shift; n=$((n - 1))
    case "$a" in
      --ca-name) [ "$n" -gt 0 ] && { name="$1"; shift; n=$((n - 1)); } ;;
      --ca-name=*) name="${a#--ca-name=}" ;;
      *) set -- "$@" "$a" ;;
    esac
  done

  if [ -n "$plain" ]; then
    command "$bin" "$@"
    return
  fi

  name="$(printf %s "$name" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-')"
  if [ -n "$name" ] && tmux has-session -t "=$name" 2>/dev/null; then
    tmux attach -t "=$name"
    return
  fi
  if [ -z "$name" ]; then
    case "$(uname -s)" in Darwin) v=mac ;; *) v=pc ;; esac
    v="ca-$(_ca_wrap_slug "$(basename "$PWD")")-${CA_HERE:-$v}-"
    i=1
    while tmux ls -F '#S' 2>/dev/null | grep -qxF "$v$i"; do i=$((i + 1)); done
    name="$v$i"
  fi

  # New sessions get the tmux server's environment, so hand over this shell's. Skip the
  # markers a running Claude Code sets for its own children, the new session is its own.
  set -- -- "$bin" "$@"
  for v in $(env | sed -n 's/^\(ANTHROPIC_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(CLAUDE_CODE_[A-Za-z0-9_]*\)=.*/\1/p' \
    | grep -vE '^CLAUDE_CODE_(ENTRYPOINT|EXECPATH|CHILD_SESSION|SESSION_|MESSAGING_|BRIDGE_|SSE_PORT)'); do
    eval "val=\${$v-}"
    set -- -e "$v=$val" "$@"
  done
  tmux new-session -d -s "$name" -c "$PWD" -e "PATH=$PATH" "$@" || return
  _ca_wrap_session_opts "$name"
  _ca_wrap_server_opts
  tmux attach -t "=$name"
}
