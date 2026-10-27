#!/usr/bin/env bash
# Offline tests for the crossagent skill: ca-stream.py, ca-approve.py, ca remote's checks
# and the worker loop end to end with a fake claude. No network, no real claude. Runs with a
# temp HOME and a private tmux server, so your ~/.crossagent and tmux sessions stay untouched.
# Usage: skills/crossagent/tests/run.sh
set -u

TESTS="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(dirname "$TESTS")"
CA="$SKILL/scripts/ca"
FIX="$TESTS/fixtures"
STREAM="$SKILL/scripts/ca-stream.py"
APPROVE="$SKILL/scripts/ca-approve.py"

T="$(mktemp -d)"
export HOME="$T/home" TMUX_TMPDIR="$T/tmux" FAKE_LOG="$T/calls"
unset TMUX TMUX_PANE CROSSAGENT_REMOTE_WORKER CROSSAGENT_ROLE CROSSAGENT_NODE CROSSAGENT_PROJECT CROSSAGENT_HOST CA_ROOT CA_SLUG
export CA_HERE=mac
mkdir -p "$HOME/.local/bin" "$TMUX_TMPDIR" "$FAKE_LOG"
cd "$T" || exit 1
cp "$TESTS/fake-claude.py" "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
EV="$HOME/.crossagent/events"
AP="$HOME/.crossagent/approvals"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "${T:?}"; }
trap cleanup EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /'; }
# t "description" command...: passes when the command succeeds
t() { local d="$1"; shift; if "$@" >"$T/out" 2>&1; then ok "$d"; else bad "$d" "$(tail -n 8 "$T/out")"; fi; }
# dies "description" "expected stderr text" command...: passes when the command fails saying that
dies() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$T/out" 2>&1; then bad "$d" "succeeded: $(tail -n 3 "$T/out")"
  elif grep -qF -- "$want" "$T/out"; then ok "$d"
  else bad "$d" "wanted '$want', got: $(tail -n 3 "$T/out")"; fi
}
# jcheck file 'python expression over e (list of events)'
jcheck() {
  python3 -I -c '
import json, sys
e = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"
}
BASE='all(x["role"] == "remote" and x["node"] == x["name"] and x["sid"] == x["tmux"] and x["host"] and x["project"] and "ts" in x for x in e)'

echo "== ca-stream.py"
D="$T/stream"; mkdir -p "$D"
printf '# Brief\n\n## Goal\n\nCount to three.\n\n## Task\nx\n' > "$D/brief.md"
stream() { python3 -I "$STREAM" --dir "$D" --host pc --project proj --role st --tmux ca-proj-pc-st --cwd /w "$@"; }
stream --turn 1 < "$FIX/stream-ok.jsonl" > "$T/feed"; rc=$?
t "success exits 0" test "$rc" = 0
SID="$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["session_id"])' "$FIX/stream-ok.jsonl")"
t "saves the session id" test "$(cat "$D/session")" = "$SID"
python3 -I -c 'import json,sys
r = [json.loads(l) for l in open(sys.argv[1])][-1]["result"]
sys.stdout.write(r if r.endswith("\n") else r + "\n")' "$FIX/stream-ok.jsonl" > "$T/want"
t "result-1.md is the result verbatim" cmp -s "$D/result-1.md" "$T/want"
t "result.md is a copy" cmp -s "$D/result.md" "$T/want"
t "raw stream is kept" test "$(wc -l < "$D/stream.jsonl")" -eq "$(wc -l < "$FIX/stream-ok.jsonl")"
t "feed shows tool calls" grep -q "> Running python3 -c 'print(6\*7)'" "$T/feed"
F="$EV/ca-proj-pc-st.jsonl"
t "events carry the contract fields" jcheck "$F" "$BASE"
t "RemoteStart has turn, path, cwd, goal" jcheck "$F" 'e[0]["ev"] == "RemoteStart" and e[0]["turn"] == 1 and e[0]["path"].endswith("/brief.md") and e[0]["cwd"] == "/w" and e[0]["sum"] == "Count to three." and "csid" not in e[0]'
t "RemoteActivity per tool call" jcheck "$F" 'len([x for x in e if x["ev"] == "RemoteActivity" and x.get("tool") == "Bash"]) == 2'
t "RemoteActivity for text has no tool" jcheck "$F" 'any(x["ev"] == "RemoteActivity" and "tool" not in x for x in e)'
t "RemoteStop has turn, rc 0, csid, path" jcheck "$F" "e[-1]['ev'] == 'RemoteStop' and e[-1]['rc'] == 0 and e[-1]['turn'] == 1 and e[-1]['csid'] == '$SID' and e[-1]['path'] == '$D/result.md' and len(e[-1]['sum']) <= 160"
stream --turn 2 < "$FIX/stream-error.jsonl" > /dev/null; rc=$?
t "is_error exits 1" test "$rc" = 1
t "follow-up RemoteStart has csid, RemoteStop rc 1" jcheck "$F" "[x for x in e if x['ev'] == 'RemoteStart'][-1].get('csid') == '$SID' and e[-1]['rc'] == 1 and e[-1]['turn'] == 2"
echo 7 > "$T/rc"; echo "boom: no auth" > "$T/err"
: | stream --turn 3 --rc-file "$T/rc" --err-file "$T/err" > /dev/null; rc=$?
t "no result line passes claude's exit code" test "$rc" = 7
t "no result line explains in result-3.md" grep -q "boom: no auth" "$D/result-3.md"
printf '## Summary\nAll good here.\n' > "$T/sumtest"
t "sum is the first line under Summary" python3 -I -c '
import importlib.util, sys
sys.dont_write_bytecode = True
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
sys.exit(0 if m.section_line(open(sys.argv[2]).read(), "summary") == "All good here." else 1)' "$STREAM" "$T/sumtest"

echo "== ca-approve.py"
mcp() {  # mcp <timeout> <answer or ""> : one tools/call, prints the reply
  local to="$1" a="$2"
  if [ -n "$a" ]; then
    ( for _ in $(seq 50); do f="$(ls "$AP"/*.json 2>/dev/null | head -1)"; [ -n "$f" ] && break; sleep 0.1; done
      echo "$a" > "${f%.json}.answer.tmp"
      [ "$a" = stray ] || mv -f "${f%.json}.answer.tmp" "${f%.json}.answer" ) &
  fi
  { echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo 'not json'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"curl -sI https://example.com"},"tool_use_id":"toolu_1"}}}'
    echo '{"jsonrpc":"2.0","id":4,"method":"nope/nope"}'
  } | CA_HOST=pc CA_ROLE=ap CA_PROJECT=proj CA_TMUX=ca-proj-pc-ap CA_APPROVE_TIMEOUT="$to" python3 -I "$APPROVE"
  wait
}
mcp 10 allow > "$T/allow"
F="$EV/ca-proj-pc-ap.jsonl"
t "initialize names the server crossagent" grep -q '"name": "crossagent"' "$T/allow"
t "tools/list has approve" grep -q '"name": "approve"' "$T/allow"
t "unknown method gets an error" grep -q '"id": 4, "error"' "$T/allow"
t "allow answer returns updatedInput" grep -qF '\"behavior\": \"allow\", \"updatedInput\": {\"command\": \"curl -sI https://example.com\"}' "$T/allow"
t "PermissionAsk event" jcheck "$F" "$BASE"' and e[0]["ev"] == "PermissionAsk" and len(e[0]["req"]) == 12 and e[0]["tool"] == "Bash" and e[0]["sum"] == "Needs permission: Running curl -sI https://example.com" and e[0]["prompt"] == "curl -sI https://example.com"'
t "PermissionAnswer allow" jcheck "$F" 'e[1]["ev"] == "PermissionAnswer" and e[1]["msg"] == "allow" and e[1]["req"] == e[0]["req"]'
t "request files are cleaned up" test -z "$(ls -A "$AP")"
mcp 10 deny > "$T/deny"
t "deny answer denies" grep -qF 'Denied by the user in CrossAgent.' "$T/deny"
t "PermissionAnswer deny" jcheck "$F" 'e[-1]["msg"] == "deny"'
mcp 10 maybe > "$T/maybe"
t "anything but allow denies" grep -qF 'Denied by the user in CrossAgent.' "$T/maybe"
mcp 2 stray > "$T/stray"
t "a lone .answer.tmp is ignored" grep -qF 'No answer within 2 s' "$T/stray"
t "stray .answer.tmp is cleaned up" test -z "$(ls -A "$AP")"
start=$(date +%s); mcp 2 "" > "$T/to"; took=$(( $(date +%s) - start ))
t "timeout denies by default" grep -qF 'No answer within 2 s, so it was denied by default.' "$T/to"
t "timeout took about 2 s" test "$took" -ge 2 -a "$took" -le 5
t "PermissionAnswer timeout" jcheck "$F" 'e[-1]["msg"] == "timeout"'

echo "== ca checks"
P="$T/proj"; mkdir -p "$P"; cd "$P" || exit 1
export CA_REMOTE_LOCAL="$P" CA_ROOT="$P"
good="$T/good.md"; printf '# Brief: smoke\n\n## Goal\nCheck the loop.\n\n## Context\nTests.\n\n## Files\nnone\n\n## Task\nRun it.\n\n## Verification\nIt ran.\n' > "$good"
printf '# Brief\n\n## goal\nx\n## Task\ny\n' > "$T/partial.md"
: > "$T/empty.md"
dies "brief missing sections is refused" "missing these sections: Context Files Verification" "$CA" remote pc r1 --brief "$T/partial.md"
dies "empty brief is refused" "the brief is empty" "$CA" remote pc r1 --brief "$T/empty.md"
dies "missing brief is refused" "--brief" "$CA" remote pc r1
dies "bad role is refused" "task name must be" "$CA" remote pc 'bad role!' --brief "$good"
dies "same host goes to a native subagent" "native subagent (Agent tool)" "$CA" remote mac r1 --brief "$good"
dies "the PC can't start Mac workers" "can't reach the Mac" env CA_HERE=pc "$CA" remote mac r1 --brief "$good"
dies "remote workers can't nest" "you're a remote worker" env CROSSAGENT_REMOTE_WORKER=1 "$CA" remote pc r1 --brief "$good"
dies "--continue needs an earlier conversation" "no earlier conversation for r1" "$CA" remote pc r1 --continue --brief "$good"
dies "ca run --claude is gone" "ca run --claude is gone" "$CA" run mac t1 --claude "do things"
dies "bad request id is refused" "12 hex chars" "$CA" remote answer pc nothex allow
dies "answer for unknown request" "no pending request abcdef123456" "$CA" remote answer pc abcdef123456 allow
t "template prints the brief template" sh -c "'$CA' remote template | grep -qi '## Goal'"

echo "== worker loop (fake claude, private tmux)"
S=ca-proj-pc-smoke; R="$P/.crossagent/remote/smoke"
"$CA" remote pc smoke --brief "$good" --model haiku --allow 'Bash(npm test:*)' --timeout 30 > "$T/r1" 2> "$T/e1"; rc=$?
t "turn 1 exits 0" test "$rc" = 0
t "stdout is exactly the report" sh -c "printf '## Summary\nDid turn 1.\n\n## Files changed\nnone\n' | cmp -s - '$T/r1'"
t "footer on stderr" grep -q "smoke on pc: turn 1, exit 0, session " "$T/e1"
t "tmux session exists" tmux has-session -t "=$S"
t "brief.md has the header and the brief" sh -c "grep -q 'You are a subagent of the CrossAgent orchestrator' '$R/brief.md' && grep -q '## Verification' '$R/brief.md'"
t "turn-1.md is the full prompt" cmp -s "$R/brief.md" "$R/turn-1.md"
t "claude got the prompt on stdin" python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if "Check the loop." in c["prompt"] and "Brief from the CrossAgent orchestrator" in c["prompt"] else 1)' "$FAKE_LOG/call-1.json"
t "claude command line" python3 -I -c '
import json, sys
c = json.load(open(sys.argv[1])); a = c["argv"]
need = ["-p", "--verbose", "--permission-prompt-tool", "mcp__crossagent__approve"]
ok = all(x in a for x in need) and a[a.index("--output-format") + 1] == "stream-json" \
  and a[a.index("--permission-mode") + 1] == "acceptEdits" and a[a.index("--model") + 1] == "haiku" \
  and a[a.index("--allowedTools") + 1] == "Bash(npm test:*)" and "--resume" not in a \
  and "--dangerously-skip-permissions" not in a and "bypassPermissions" not in a
m = json.loads(a[a.index("--mcp-config") + 1])["mcpServers"]["crossagent"]
ok = ok and m["args"][0] == "-I" and m["args"][1].endswith("ca-approve.py") and m["env"]["CA_TMUX"] == "ca-proj-pc-smoke"
sys.exit(0 if ok else 1)' "$FAKE_LOG/call-1.json"
t "claude env: worker flag set, CrossAgent hook vars unset" python3 -I -c '
import json, sys
e = json.load(open(sys.argv[1]))["env"]
sys.exit(0 if e["CROSSAGENT_REMOTE_WORKER"] == "1" and e["CROSSAGENT_ROLE"] is None and e["CROSSAGENT_NODE"] is None and e["CROSSAGENT_PROJECT"] is None and e["MCP_TOOL_TIMEOUT"] == "360000" else 1)' "$FAKE_LOG/call-1.json"
t "Mac side keeps brief and result copies" sh -c "test -f '$P/.crossagent/remote/pc-smoke/brief-1.md' && cmp -s '$T/r1' '$P/.crossagent/remote/pc-smoke/result-1.md'"
SID1="$(cat "$R/session")"

printf 'Now ASK_PERMISSION please.\n' > "$T/f1.md"
"$CA" remote pc smoke --continue --brief "$T/f1.md" --timeout 30 > "$T/r2" 2> "$T/e2" &
W=$!
id=""; for _ in $(seq 100); do id="$(grep -o 'approval [a-f0-9]\{12\}' "$T/e2" 2>/dev/null | head -1 | cut -d' ' -f2)"; [ -n "$id" ] && break; sleep 0.1; done
t "wait prints the pending approval once" test -n "$id"
t "status lists the pending approval" sh -c "'$CA' remote status pc | grep -q 'approvals: $id'"
t "ca remote answer writes the answer" "$CA" remote answer pc "$id" allow
wait "$W"; rc=$?
t "turn 2 exits 0" test "$rc" = 0
t "approval line printed only once" test "$(grep -c "approval $id" "$T/e2")" = 1
t "the worker saw the allow" grep -q "Permission: allow." "$T/r2"
t "same session id on turn 2" test "$(cat "$R/session")" = "$SID1"
t "turn 2 resumes the session" python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1]))["argv"]; sys.exit(0 if a[a.index("--resume")+1] == sys.argv[2] and a[a.index("--allowedTools")+1] == "Bash(npm test:*)" else 1)' "$FAKE_LOG/call-2.json" "$SID1"
t "follow-up prompt has its header" grep -q "# Follow-up from the CrossAgent orchestrator" "$R/turn-2.md"
t "brief.md gets the follow-up appended" grep -q "## Follow-up 1" "$R/brief.md"
t "status says idle after turn 2" sh -c "'$CA' remote status pc smoke | grep -q 'idle after turn 2, exit 0'"
F="$EV/$S.jsonl"
t "events: 2 starts, 2 stops, ask and answer" jcheck "$F" "$BASE"' and [x["ev"] for x in e if x["ev"] != "RemoteActivity"] == ["RemoteStart", "RemoteStop", "RemoteStart", "PermissionAsk", "PermissionAnswer", "RemoteStop"]'

printf 'SLOW one\n' > "$T/f2.md"
"$CA" remote pc smoke --continue --brief "$T/f2.md" --detach > "$T/r3" 2>&1
t "--detach returns right away with the turn" grep -q "turn 3" "$T/r3"
dies "a running role refuses a new turn" "still running" "$CA" remote pc smoke --continue --brief "$T/f2.md"
"$CA" remote wait pc smoke --timeout 1 > "$T/r4" 2> "$T/e4"; rc=$?
t "wait times out with 124" test "$rc" = 124
t "timeout says how to keep waiting" grep -q "is still running (turn 3). Run: ca remote wait pc smoke" "$T/e4"
t "timeout prints nothing on stdout" test ! -s "$T/r4"
t "stop kills the session" "$CA" remote stop pc smoke
t "session is gone" sh -c "! tmux has-session -t '=$S' 2>/dev/null"
t "stop logs RemoteStop rc 130" jcheck "$F" 'e[-1]["ev"] == "RemoteStop" and e[-1]["rc"] == 130 and e[-1]["turn"] == 3 and e[-1]["sum"] == "Stopped with ca remote stop"'
t "status says stopped" sh -c "'$CA' remote status pc | grep -q 'stopped after turn 3, exit 130'"
printf 'Back again.\n' > "$T/f3.md"
"$CA" remote pc smoke --continue --brief "$T/f3.md" --timeout 30 > "$T/r5" 2>&1; rc=$?
t "--continue after stop recreates the loop" sh -c "test $rc = 0 && tmux has-session -t '=$S'"
t "and keeps the session id" test "$(cat "$R/session")" = "$SID1"
printf 'FAIL_HARD\n' > "$T/f4.md"
"$CA" remote pc smoke --continue --brief "$T/f4.md" --timeout 30 > "$T/r6" 2>&1; rc=$?
t "a crashed claude passes its exit code" test "$rc" = 3
t "and its stderr lands in the report" grep -q "fake claude: something broke" "$T/r6"
"$CA" remote pc smoke --brief "$good" --timeout 30 > /dev/null 2>&1
t "a new conversation starts clean at turn 1" sh -c "test \"\$(cat '$R/turn')\" = 1 && test ! -f '$R/turn-2.md' && test \"\$(cat '$R/session')\" != '$SID1'"
"$CA" remote stop pc smoke > /dev/null
unset CA_REMOTE_LOCAL CA_ROOT
cd "$T" || exit 1

echo "== ca init"
I="$T/initproj"; mkdir -p "$I/.claude"
echo '{"permissions": {"allow": ["Bash(ls)"]}}' > "$I/.claude/settings.local.json"
echo "my old notes" > "$I/CROSSAGENT.md"
(cd "$I" && CA_HERE=pc CA_ROOT="$I" "$CA" init) > "$T/init" 2>&1
t "init pins teammateMode and keeps other keys" python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["teammateMode"] == "in-process" and d["permissions"]["allow"] == ["Bash(ls)"] else 1)' "$I/.claude/settings.local.json"
t "init moves an old CROSSAGENT.md aside" sh -c "grep -q 'my old notes' '$I/.crossagent/CROSSAGENT.md.old' && head -1 '$I/CROSSAGENT.md' | grep -qF '<!-- crossagent template v2 -->'"
for a in pc-worker mac-worker; do
  [ -f "$SKILL/agents/$a.md" ] && t "init installs $a" cmp -s "$SKILL/agents/$a.md" "$HOME/.claude/agents/$a.md"
done
(cd "$I" && CA_HERE=pc CA_ROOT="$I" "$CA" init) > "$T/init2" 2>&1
t "second init changes nothing" sh -c "! grep -qE 'pinned|moved|added ~/.claude/agents' '$T/init2'"
t "init starts no sessions" sh -c "! tmux ls 2>/dev/null | grep -q initproj"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
