#!/usr/bin/env python3
# Permission prompts for `ca remote` workers. Stdlib only, run with `python3 -I`.
#
# A stdio MCP server (newline delimited JSON-RPC) named "crossagent" with one tool,
# `approve`, used as `claude -p --permission-prompt-tool mcp__crossagent__approve`.
# Each call becomes ~/.crossagent/approvals/<id>.json plus a PermissionAsk event, then
# waits for "allow" or "deny" in ~/.crossagent/approvals/<id>.answer (the CrossAgent app
# or `ca remote answer` writes it). No answer in CA_APPROVE_TIMEOUT seconds means deny.
#
# Env: CA_HOST, CA_ROLE, CA_PROJECT, CA_TMUX, CA_APPROVE_TIMEOUT (default 300).

import importlib.util
import json
import os
import sys
import threading
import time

# Shares tool_summary and the event writer with ca-stream.py (python3 -I won't import from here).
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    "ca_stream", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ca-stream.py"))
stream = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stream)

APPROVALS = os.path.join(os.path.expanduser("~"), ".crossagent", "approvals")
TOOL = {
    "name": "approve",
    "description": "Asks the user in CrossAgent whether a tool call may run.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "tool_name": {"type": "string"},
            "input": {"type": "object"},
            "tool_use_id": {"type": "string"},
        },
        "required": ["tool_name", "input"],
    },
}
ASK_AGAIN = " Don't work around it, note it in your report."
LOCK = threading.Lock()


def send(o):
    with LOCK:
        sys.stdout.write(json.dumps(o) + "\n")
        sys.stdout.flush()


def detail(tool, inp):
    if not isinstance(inp, dict):
        return None
    for k in ("command", "file_path", "notebook_path", "url", "query", "pattern"):
        if inp.get(k):
            return str(inp[k])
    try:
        return json.dumps(inp, ensure_ascii=False)
    except Exception:
        return None


def write_json(path, obj):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, path)


def ask(args):
    tool = str(args.get("tool_name") or "tool")
    inp = args.get("input") if isinstance(args.get("input"), dict) else {}
    try:
        limit = float(os.environ.get("CA_APPROVE_TIMEOUT") or 300)
    except ValueError:
        limit = 300.0
    host = os.environ.get("CA_HOST", "")
    role = os.environ.get("CA_ROLE", "")
    tmux = os.environ.get("CA_TMUX", "")
    ev = stream.Events(host, os.environ.get("CA_PROJECT", ""), role, tmux)

    rid = os.urandom(6).hex()
    summary = stream.clip("Needs permission: " + stream.tool_summary(tool, inp), 160)
    full = detail(tool, inp)
    os.makedirs(APPROVALS, mode=0o700, exist_ok=True)
    req = os.path.join(APPROVALS, rid + ".json")
    ans = os.path.join(APPROVALS, rid + ".answer")
    write_json(req, {"id": rid, "role": role, "host": host, "tmux": tmux,
                     "project": os.environ.get("CA_PROJECT", ""), "tool": tool, "sum": summary,
                     "detail": (full or "")[:2000], "ts": round(time.time(), 3)})
    ev.emit("PermissionAsk", req=rid, tool=tool, sum=summary,
            prompt=(full[:597] + "...") if full and len(full) > 600 else full)

    answer = "timeout"
    end = time.time() + limit
    while time.time() < end:
        # Answers arrive whole (written to <id>.answer.tmp, then renamed), so the
        # first read of <id>.answer is final. Anything but "allow" denies.
        try:
            with open(ans) as f:
                answer = "allow" if f.read().strip().lower() == "allow" else "deny"
            break
        except OSError:
            pass
        time.sleep(0.3)
    for p in (req, ans, ans + ".tmp"):
        try:
            os.remove(p)
        except OSError:
            pass
    ev.emit("PermissionAnswer", req=rid, msg=answer)
    if answer == "allow":
        return {"behavior": "allow", "updatedInput": inp}
    if answer == "deny":
        return {"behavior": "deny", "message": "Denied by the user in CrossAgent." + ASK_AGAIN}
    return {"behavior": "deny",
            "message": "No answer within %d s, so it was denied by default.%s" % (limit, ASK_AGAIN)}


def answer(mid, args):
    try:
        r = ask(args)
    except Exception as e:
        r = {"behavior": "deny", "message": "The permission tool failed (%s)." % str(e)[:120] + ASK_AGAIN}
    try:
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(r)}]}})
    except Exception:
        pass


def handle(m):
    mid, meth = m.get("id"), m.get("method")
    params = m.get("params") if isinstance(m.get("params"), dict) else {}
    if mid is None:
        return  # notifications need no reply
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": params.get("protocolVersion") or "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "crossagent", "version": "1"}}})
    elif meth == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [TOOL]}})
    elif meth == "tools/call":
        if params.get("name") != "approve":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool"}})
            return
        args = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        # Each prompt waits on its own thread, so parallel tool calls all show up at once.
        threading.Thread(target=answer, args=(mid, args), daemon=True).start()
    elif meth == "ping" or (isinstance(meth, str) and meth.endswith("/list")):
        send({"jsonrpc": "2.0", "id": mid, "result": {} if meth == "ping" else {meth.split("/")[0]: []}})
    else:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}})


def main():
    for line in sys.stdin:
        try:
            m = json.loads(line)
        except Exception:
            continue
        if not isinstance(m, dict):
            continue
        try:
            handle(m)
        except Exception as e:
            if m.get("id") is not None:
                try:
                    send({"jsonrpc": "2.0", "id": m.get("id"), "error": {"code": -32603, "message": str(e)[:200]}})
                except Exception:
                    pass


if __name__ == "__main__":
    try:
        main()
        # stdin closed: let answers still in flight go out before exiting.
        for t in threading.enumerate():
            if t is not threading.current_thread():
                t.join()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
