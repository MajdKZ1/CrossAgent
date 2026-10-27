#!/usr/bin/env python3
# Live feed for a `ca remote` worker. Stdlib only, run with `python3 -I`.
#
#   claude -p --output-format stream-json --verbose ... | ca-stream.py --dir D --turn N \
#       --host H --project SLUG --role ROLE --tmux SESSION --cwd ROOT [--rc-file F] [--err-file F]
#
# Reads stream-json from stdin, appends every raw line to D/stream.jsonl, prints a readable
# feed, saves the headless session id to D/session and the final result to D/result-N.md
# (copied to D/result.md). Writes RemoteStart/RemoteActivity/RemoteStop events to
# ~/.crossagent/events/<tmux session>.jsonl, fields as in Core/Contracts.swift.
# Exit 0 when the result is a success, else 1 (or claude's own code from --rc-file).
#
#   ca-stream.py --emit EV --host H --project SLUG --role ROLE --tmux SESSION [key=value...]
#
# Writes one event and exits (used by `ca remote stop`). Numeric values become ints.

import json
import os
import sys
import time

MAX_FILE = 512 * 1024


def clip(s, n):
    if s is None:
        return None
    s = " ".join(str(s).split())
    if len(s) > n:
        s = s[: n - 3].rstrip() + "..."
    return s or None


def base(p):
    p = str(p or "").rstrip("/")
    return p.rsplit("/", 1)[-1] or p


# Same as tool_summary in Sources/CrossAgent/Resources/crossagent-hook.py.
def tool_summary(tool, inp):
    inp = inp if isinstance(inp, dict) else {}
    if tool == "Bash":
        cmd = (inp.get("command") or "").strip().splitlines()
        return "Running " + (cmd[0] if cmd else "a command")
    if tool in ("Edit", "MultiEdit"):
        return "Editing " + base(inp.get("file_path"))
    if tool == "Write":
        return "Writing " + base(inp.get("file_path"))
    if tool == "Read":
        return "Reading " + base(inp.get("file_path"))
    if tool == "NotebookEdit":
        return "Editing " + base(inp.get("notebook_path"))
    if tool == "Grep":
        return "Searching for " + str(inp.get("pattern") or "")
    if tool == "Glob":
        return "Finding " + str(inp.get("pattern") or "files")
    if tool == "WebFetch":
        url = str(inp.get("url") or "")
        host = url.split("://", 1)[-1].split("/", 1)[0]
        return "Fetching " + (host or "a page")
    if tool == "WebSearch":
        return "Searching the web: " + str(inp.get("query") or "")
    if tool in ("Agent", "Task"):
        who = inp.get("name") or inp.get("subagent_type") or "agent"
        what = inp.get("description")
        return "Starting " + who + (": " + what if what else "")
    if tool == "SendMessage":
        to = inp.get("to") or inp.get("recipient") or "someone"
        what = inp.get("summary") or inp.get("message") or ""
        return "Messaging " + str(to) + (": " + str(what) if what else "")
    if tool in ("TodoWrite", "TaskCreate", "TaskUpdate"):
        return "Updating the todo list"
    if tool.startswith("mcp__"):
        return "Using " + tool.split("__")[-1]
    return "Using " + tool


def append(path, line):
    import fcntl
    for _ in range(5):
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            if os.fstat(fd).st_ino == os.stat(path).st_ino:
                break
        except OSError:
            pass
        os.close(fd)
    try:
        os.write(fd, line)
        size = os.fstat(fd).st_size
        if size > MAX_FILE:
            with open(path, "rb") as f:
                f.seek(size - MAX_FILE // 2)
                data = f.read()
            nl = data.find(b"\n")
            data = data[nl + 1:] if nl >= 0 else b""
            tmp = path + ".tmp"
            tfd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                os.write(tfd, data)
            finally:
                os.close(tfd)
            os.replace(tmp, path)
    finally:
        os.close(fd)


def safe_name(s):
    s = "".join(c for c in str(s or "") if c.isalnum() or c in "-_")[:80]
    return s or "unknown"


class Events:
    def __init__(self, host, project, role, tmux):
        self.base = {"host": host, "sid": tmux, "tmux": tmux, "project": project,
                     "role": "remote", "node": role, "name": role}
        self.path = os.path.join(os.path.expanduser("~"), ".crossagent", "events",
                                 safe_name(tmux) + ".jsonl")
        self.last = None
        self.text_ts = 0.0
        self.window = [0.0, 0]  # second, events in it

    def emit(self, ev, **kw):
        try:
            e = {"ts": round(time.time(), 3), "ev": ev}
            e.update(self.base)
            for k, v in kw.items():
                if v is not None and v != "":
                    e[k] = v
            os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
            append(self.path, (json.dumps(e, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8"))
        except Exception:
            pass

    def activity(self, tool, sum_):
        # Drop repeats, keep text to one event a second and everything to 10 a second.
        key = (tool, sum_)
        now = time.time()
        if not sum_ or key == self.last or (tool is None and now - self.text_ts < 1):
            return
        sec = int(now)
        if self.window[0] != sec:
            self.window = [sec, 0]
        if self.window[1] >= 10:
            return
        self.window[1] += 1
        self.last = key
        if tool is None:
            self.text_ts = now
        self.emit("RemoteActivity", tool=tool, sum=clip(sum_, 160))


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def section_line(text, heading):
    """First non-empty line under a `## <heading>` heading (case-insensitive prefix match)."""
    on = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#"):
            on = s.startswith("## ") and s[3:].strip().lower().startswith(heading)
            continue
        if on and s:
            return s
    return None


def first_line(text):
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()
    return None


def args_dict(argv):
    a, i = {}, 0
    while i < len(argv):
        k = argv[i]
        if k.startswith("--") and i + 1 < len(argv):
            a[k[2:]] = argv[i + 1]
            i += 2
        else:
            a.setdefault("_", []).append(k)
            i += 1
    return a


def out(s=""):
    try:
        sys.stdout.write(s + "\n")
        sys.stdout.flush()
    except Exception:
        pass


def emit_only(a):
    ev = Events(a.get("host", ""), a.get("project", ""), a.get("role", ""), a.get("tmux", ""))
    kw = {}
    for kv in a.get("_", []):
        k, _, v = kv.partition("=")
        kw[k] = int(v) if v.lstrip("-").isdigit() else v
    ev.emit(a["emit"], **kw)
    return 0


def run(a):
    d = a["dir"]
    turn = int(a.get("turn", "1"))
    role = a.get("role", "")
    host = a.get("host", "")
    ev = Events(host, a.get("project", ""), role, a.get("tmux", ""))
    brief = os.path.join(d, "brief.md")
    result_n = os.path.join(d, "result-%d.md" % turn)
    result = os.path.join(d, "result.md")
    sess = read(os.path.join(d, "session")).strip() or None

    goal = section_line(read(brief), "goal")
    ev.emit("RemoteStart", turn=turn, path=brief, cwd=a.get("cwd"),
            sum=clip(goal or "Remote worker " + role, 160), csid=sess if turn > 1 else None)
    out("=== %s on %s, turn %d ===" % (role, host, turn))
    if goal:
        out("Goal: " + goal)
    out()

    raw = open(os.path.join(d, "stream.jsonl"), "ab")
    res = None
    said = None  # last assistant text, so the result isn't printed twice
    names = {}  # tool_use_id -> tool name, to label failing results
    for line in sys.stdin.buffer:
        if not line.strip():
            continue
        raw.write(line if line.endswith(b"\n") else line + b"\n")
        raw.flush()
        try:
            m = json.loads(line.decode("utf-8", "replace"))
        except Exception:
            out(line.decode("utf-8", "replace").rstrip())
            continue
        if not isinstance(m, dict):
            continue
        sid = m.get("session_id")
        if sid and sid != sess:
            sess = sid
            write(os.path.join(d, "session"), sid + "\n")
        t = m.get("type")
        sub = "  " if m.get("parent_tool_use_id") else ""
        if t == "system" and m.get("subtype") == "init":
            out("[session %s, model %s, %s]" % (sid, m.get("model"), m.get("permissionMode")))
        elif t == "assistant":
            for c in (m.get("message") or {}).get("content") or []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    name = str(c.get("name") or "tool")
                    names[c.get("id")] = name
                    s = tool_summary(name, c.get("input"))
                    out(sub + "> " + s)
                    ev.activity(name, s)
                elif c.get("type") == "text" and (c.get("text") or "").strip():
                    text = c["text"].strip()
                    said = text
                    out()
                    out("\n".join(sub + l for l in text.splitlines()))
                    out()
                    ev.activity(None, first_line(text))
        elif t == "user":
            content = (m.get("message") or {}).get("content")
            for c in content if isinstance(content, list) else []:
                if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("is_error"):
                    body = c.get("content")
                    if isinstance(body, list):
                        body = " ".join(str(x.get("text", "")) for x in body if isinstance(x, dict))
                    out(sub + "! %s failed: %s" % (names.get(c.get("tool_use_id"), "tool"), clip(body, 200)))
        elif t == "result":
            res = m
    raw.close()

    rc_claude = None
    try:
        rc_claude = int(read(a.get("rc-file", "")).strip())
    except ValueError:
        pass

    if res is not None:
        text = res.get("result")
        ok = res.get("subtype") == "success" and not res.get("is_error")
        rc = 0 if ok else 1
        if not isinstance(text, str) or not text.strip():
            text = "# %s on %s, turn %d\n\nThe worker ended (%s) without a final message.\n" % (
                role, host, turn, res.get("subtype") or "no result")
        out("=== result (%s) ===" % ("ok" if ok else "error"))
        if text.strip() != said:
            out(text.rstrip())
        cost = res.get("total_cost_usd")
        dur = res.get("duration_ms")
        out()
        out("[turns %s, %s, $%s]" % (res.get("num_turns"),
                                    "%.0fs" % (dur / 1000) if isinstance(dur, (int, float)) else "?",
                                    "%.4f" % cost if isinstance(cost, (int, float)) else "?"))
    else:
        rc = rc_claude if rc_claude not in (None, 0) else 1
        err = read(a.get("err-file", "")).strip().splitlines()[-15:]
        text = "# %s on %s, turn %d\n\nClaude exited (code %s) without a final result.\n" % (
            role, host, turn, "?" if rc_claude is None else rc_claude)
        if err:
            text += "\nLast stderr lines:\n\n```\n" + "\n".join(err) + "\n```\n"
        out("=== no result ===")
        out(text.rstrip())
    if not text.endswith("\n"):
        text += "\n"
    write(result_n, text)
    write(result, text)

    summary = section_line(text, "summary") or first_line(text)
    ev.emit("RemoteStop", turn=turn, rc=rc, csid=sess, path=result, sum=clip(summary, 160))
    return rc


def main():
    a = args_dict(sys.argv[1:])
    if "emit" in a:
        return emit_only(a)
    if "dir" not in a:
        sys.stderr.write("usage: ca-stream.py --dir D --turn N --host H --project P --role R --tmux S\n")
        return 2
    try:
        return run(a)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
