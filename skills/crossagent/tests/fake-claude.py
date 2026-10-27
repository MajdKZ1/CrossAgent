#!/usr/bin/env python3
# Stand-in for `claude -p --output-format stream-json` in the offline tests.
# Logs its argv, env and prompt to $FAKE_LOG/call-<n>.json, then prints a canned stream.
# Words in the prompt steer it: ASK_PERMISSION runs the --permission-prompt-tool MCP server
# from --mcp-config once, SLOW sleeps 30 s, FAIL_HARD dies without a result.

import json
import os
import subprocess
import sys
import time
import uuid

argv = sys.argv[1:]
if argv[:1] in (["--version"], ["-v"]):
    print("0.0.0 (fake claude)")
    sys.exit(0)


def opt(name, many=False):
    vals = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == name]
    return vals if many else (vals[-1] if vals else None)


prompt = sys.stdin.read()
log = os.environ.get("FAKE_LOG", ".")
n = len([f for f in os.listdir(log) if f.startswith("call-")]) + 1
sid = opt("--resume") or str(uuid.uuid4())
keep = ["CROSSAGENT_REMOTE_WORKER", "CROSSAGENT_ROLE", "CROSSAGENT_NODE", "CROSSAGENT_PROJECT",
        "CROSSAGENT_HOST", "MCP_TOOL_TIMEOUT"]
with open(os.path.join(log, "call-%d.json" % n), "w") as f:
    json.dump({"argv": argv, "env": {k: os.environ.get(k) for k in keep}, "prompt": prompt,
               "cwd": os.getcwd()}, f)


def emit(o):
    o["session_id"] = sid
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()


emit({"type": "system", "subtype": "init", "cwd": os.getcwd(), "model": opt("--model") or "fake",
      "permissionMode": opt("--permission-mode")})

if "FAIL_HARD" in prompt:
    sys.stderr.write("fake claude: something broke\n")
    sys.exit(3)

note = ""
if "ASK_PERMISSION" in prompt:
    cfg = json.loads(opt("--mcp-config"))["mcpServers"]["crossagent"]
    env = dict(os.environ, **cfg.get("env", {}))
    p = subprocess.Popen([cfg["command"]] + cfg["args"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         env=env, text=True)
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": {"protocolVersion": "2025-06-18"}}) + "\n")
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "approve", "arguments": {"tool_name": "Bash", "input": {"command": "curl -sI https://example.com"},
                                         "tool_use_id": "toolu_x"}}}) + "\n")
    p.stdin.flush()
    p.stdout.readline()
    r = json.loads(json.loads(p.stdout.readline())["result"]["content"][0]["text"])
    p.stdin.close()
    p.wait()
    note = " Permission: %s." % r["behavior"]

if "SLOW" in prompt:
    time.sleep(30)

emit({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [
    {"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "python3 --version"}}]}})
emit({"type": "user", "parent_tool_use_id": None, "message": {"content": [
    {"type": "tool_result", "tool_use_id": "toolu_1", "content": "Python 3"}]}})
report = "## Summary\nDid turn %d.%s\n\n## Files changed\nnone\n" % (n, note)
emit({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "text", "text": report}]}})
emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "duration_ms": 1200,
      "total_cost_usd": 0.001, "result": report})
