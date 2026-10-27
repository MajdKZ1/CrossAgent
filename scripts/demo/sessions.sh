#!/bin/bash
# Scripted tmux sessions for recording the README GIFs. Everything runs on its own
# tmux server (tmux -L ca-demo) in a clean env with a throwaway HOME, prints canned
# output and touches no network and no real files.
#
#   scripts/demo/sessions.sh          (re)creates the demo sessions
#   scripts/demo/sessions.sh stop     kills the ca-demo server
#
# Then run a debug build with CROSSAGENT_DEMO=1 (see scripts/demo/run.sh).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=/tmp/crossagent-demo
prompt='\[\e[32m\]demo\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]$ '

demo_env() {
  env -i HOME="$root/home" USER=demo LOGNAME=demo PATH="$here/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SHELL="$here/bin/demo-shell" PS1="$prompt" DEMO_PS1="$prompt" HISTFILE=/dev/null TERM=xterm-256color LANG=en_US.UTF-8 \
    BASH_SILENCE_DEPRECATION_WARNING=1 "$@"
}
t() { demo_env "$here/bin/tmux" "$@"; }

# new NAME PROJECT CMD...: a detached session in ~/Projects/PROJECT of the fake home.
new() {
  local name=$1 dir="$root/home/Projects/$2"
  shift 2
  mkdir -p "$dir"
  t new-session -d -s "$name" -x 140 -y 36 -c "$dir" "$(printf '%q ' "$@")"
}

# MARK: feeds, each a loop of canned lines

c_dim=$'\e[2m' c_off=$'\e[0m' c_green=$'\e[32m' c_yellow=$'\e[33m' c_cyan=$'\e[36m' c_blue=$'\e[34m'
c_bold=$'\e[1m' c_mag=$'\e[35m' c_red=$'\e[31m'

pick() { local a=("$@"); printf '%s' "${a[RANDOM % ${#a[@]}]}"; }
ms() { printf '%d' $(( $1 + RANDOM % $2 )); }

feed_build() {
  local files=(Parser Lexer Tokens Scheduler Cache Router Config Logger Retry Pool Codec Metrics Session Store)
  while :; do
    clear
    printf '%s$ swift build%s\n' "$c_dim" "$c_off"
    sleep 0.6
    printf 'Building for debugging...\n'
    local n=${#files[@]} i=0
    for f in "${files[@]}"; do
      i=$((i + 1))
      printf '%s[%d/%d]%s Compiling DemoKit %s.swift\n' "$c_dim" "$i" $((n + 3)) "$c_off" "$f"
      sleep "0.$((2 + RANDOM % 5))"
    done
    printf '%s[%d/%d]%s Emitting module DemoKit\n' "$c_dim" $((n + 1)) $((n + 3)) "$c_off"; sleep 0.5
    printf '%s[%d/%d]%s Compiling demo main.swift\n' "$c_dim" $((n + 2)) $((n + 3)) "$c_off"; sleep 0.6
    printf '%s[%d/%d]%s Linking demo\n' "$c_dim" $((n + 3)) $((n + 3)) "$c_off"; sleep 0.8
    printf '%sBuild complete!%s (%d.%02ds)\n' "$c_green" "$c_off" $((4 + RANDOM % 4)) $((RANDOM % 100))
    sleep 6
  done
}

feed_tests() {
  local names=("parses an empty file" "rejects a bad header" "retries on 503" "gives up after 3 tries"
    "keeps the cache warm" "expires stale entries" "streams large bodies" "round trips unicode"
    "handles a closed socket" "sorts by date" "merges two configs" "escapes shell input")
  while :; do
    clear
    printf '%s$ npm test%s\n\n' "$c_dim" "$c_off"
    local pass=0 suite
    for suite in client cache config; do
      printf ' %s%s RUNS %s src/%s.test.ts\n' "$c_yellow" "$c_bold" "$c_off" "$suite"
      sleep 0.4
      for _ in 1 2 3 4; do
        printf '   %s✓%s %s %s(%s ms)%s\n' "$c_green" "$c_off" "$(pick "${names[@]}")" "$c_dim" "$(ms 1 40)" "$c_off"
        pass=$((pass + 1))
        sleep "0.$((3 + RANDOM % 6))"
      done
      printf ' %s%s PASS %s src/%s.test.ts\n\n' "$c_green" "$c_bold" "$c_off" "$suite"
    done
    printf '%sTests:%s  %s%d passed%s, %d total\n' "$c_bold" "$c_off" "$c_green" "$pass" "$c_off" "$pass"
    printf '%sTime:%s   %d.%ds\n' "$c_bold" "$c_off" $((2 + RANDOM % 3)) $((RANDOM % 10))
    sleep 7
  done
}

feed_server() {
  local paths=(/api/items /api/items/42 /api/users/me /api/health /api/search?q=tea /api/orders /api/cart)
  local verbs=(GET GET GET POST GET PUT GET DELETE)
  clear
  printf '%s$ npm run serve%s\n' "$c_dim" "$c_off"
  printf '%s[api]%s listening on %shttp://localhost:8080%s\n' "$c_cyan" "$c_off" "$c_bold" "$c_off"
  while :; do
    local code=200 color=$c_green
    case $((RANDOM % 12)) in 0) code=404 color=$c_yellow ;; 1) code=201 ;; esac
    printf '%s%s%s %s[api]%s %-6s %-22s %s%d%s %sms\n' "$c_dim" "$(date +%H:%M:%S)" "$c_off" "$c_cyan" "$c_off" \
      "$(pick "${verbs[@]}")" "$(pick "${paths[@]}")" "$color" "$code" "$c_off" "$(ms 2 60)"
    sleep "0.$((3 + RANDOM % 7))"
  done
}

feed_bench() {
  local cases=(encode/small encode/large decode/small decode/large hash/sha256 compress/lz4 parse/json sort/1e6)
  while :; do
    clear
    printf '%s$ cargo bench%s\n' "$c_dim" "$c_off"
    printf '%s   Compiling%s demo-bench v0.1.0\n' "$c_green" "$c_off"; sleep 1
    printf '%s    Finished%s bench profile [optimized] target(s) in 4.2s\n' "$c_green" "$c_off"; sleep 0.5
    printf '%s     Running%s benches/main.rs\n\n' "$c_green" "$c_off"
    local c
    for c in "${cases[@]}"; do
      sleep "1.$((RANDOM % 6))"
      local delta=$((RANDOM % 9 - 4)) mark=$c_dim word="no change"
      if [ $delta -le -3 ]; then mark=$c_green word="improved"; elif [ $delta -ge 3 ]; then mark=$c_red word="regressed"; fi
      printf '%s%-16s%s time: [%s%d.%02d µs%s]  %s%+d%%%s  %s%s%s\n' "$c_bold" "$c" "$c_off" "$c_bold" $((1 + RANDOM % 90)) \
        $((RANDOM % 100)) "$c_off" "$mark" "$delta" "$c_off" "$c_dim" "$word" "$c_off"
    done
    sleep 8
  done
}

feed_web() {
  local files=(src/App.tsx src/pages/Home.tsx src/components/Nav.tsx src/styles/main.css src/components/Card.tsx)
  clear
  printf '%s$ npm run dev%s\n\n' "$c_dim" "$c_off"
  printf '  %s%sdev server%s ready in %s ms\n\n' "$c_mag" "$c_bold" "$c_off" "$(ms 200 300)"
  printf '  %s➜%s  %sLocal:%s   %shttp://localhost:5173/%s\n' "$c_green" "$c_off" "$c_bold" "$c_off" "$c_cyan" "$c_off"
  printf '  %s➜  Network: use --host to expose%s\n\n' "$c_dim" "$c_off"
  while :; do
    sleep $((2 + RANDOM % 4))
    printf '%s%s%s %s[hmr]%s update %s%s\n' "$c_dim" "$(date +%H:%M:%S)" "$c_off" "$c_green" "$c_off" \
      "$(pick "${files[@]}")" "$c_off"
  done
}

case "${1:-start}" in
  start)
    t kill-server 2>/dev/null || true
    mkdir -p "$root/home/.claude"
    new ca-demo-mac-1 demo claude --play
    new ca-demo-mac-build demo "$here/sessions.sh" feed build
    new ca-site-mac-3 site "$here/sessions.sh" feed web
    new ca-demo-pc-tests demo "$here/sessions.sh" feed tests
    new ca-demo-pc-bench demo "$here/sessions.sh" feed bench
    new ca-api-pc-2 api "$here/sessions.sh" feed server
    t ls -F '#{session_name}'
    ;;
  stop)
    t kill-server 2>/dev/null || true
    ;;
  feed)
    "feed_$2"
    ;;
  *)
    echo "usage: $0 [start|stop]" >&2
    exit 2
    ;;
esac
