#!/usr/bin/env python3
# CrossAgent hook for Claude Code. Stdlib only, run with `python3 -I`.
#
#   crossagent-hook.py                 read one hook payload on stdin, append one
#                                      compact event line to
#                                      ~/.crossagent/events/<session>.jsonl
#   crossagent-hook.py --follow DIR [--since TS]
#                                      print every new line appended to DIR/*.jsonl
#
# Hook mode never prints and always exits 0: a broken hook must never get in
# Claude's way. Field names match AgentEvent in Core/Contracts.swift.

import json
import os
import sys
import time

MAX_FILE = 512 * 1024
KEEP_DAYS = 3


def clip(s, n):
    if s is None:
        return None
    if not isinstance(s, str):
        s = str(s)
    s = " ".join(s.split())
    if len(s) > n:
        s = s[: n - 3].rstrip() + "..."
    return s or None


def clip_lines(s, n):
    """Like clip, but keeps line breaks (blank lines dropped)."""
    if s is None:
        return None
    lines = [" ".join(l.split()) for l in str(s).splitlines()]
    s = "\n".join(l for l in lines if l)
    if len(s) > n:
        s = s[: n - 3].rstrip() + "..."
    return s or None


def base(p):
    p = str(p or "").rstrip("/")
    return p.rsplit("/", 1)[-1] or p


def tool_summary(tool, inp):
    """Human one liner for a tool call, like "Running swift build"."""
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
    if tool == "SubagentHandback":
        return "Reporting back"
    if tool in ("TodoWrite", "TaskCreate", "TaskUpdate"):
        return "Updating the todo list"
    if tool.startswith("mcp__"):
        return "Using " + tool.split("__")[-1]
    return "Using " + tool


def tag(text, name):
    a, b = "<" + name + ">", "</" + name + ">"
    i = text.find(a)
    if i < 0:
        return None
    j = text.find(b, i)
    return text[i + len(a): j if j >= 0 else None].strip()


def default_host():
    h = os.environ.get("CROSSAGENT_HOST")
    if h:
        return h
    return "mac" if sys.platform == "darwin" else "pc"


def make_event(d):
    ev = str(d.get("hook_event_name") or "")
    e = {"ts": round(time.time(), 3), "ev": ev, "host": default_host()}

    def put(k, v):
        if v is not None and v != "" and v != []:
            e[k] = v

    put("sid", d.get("session_id"))
    put("cwd", d.get("cwd"))
    put("role", os.environ.get("CROSSAGENT_ROLE"))
    put("project", os.environ.get("CROSSAGENT_PROJECT"))
    put("node", os.environ.get("CROSSAGENT_NODE"))
    put("aid", d.get("agent_id"))
    put("atype", d.get("agent_type"))

    tool = d.get("tool_name")
    inp = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
    if tool:
        put("tool", tool)
        put("tuid", d.get("tool_use_id"))
        summary = tool_summary(str(tool), inp)
        if ev == "PermissionRequest":
            summary = "Needs permission: " + summary
        put("sum", clip(summary, 160))
        if tool in ("Agent", "Task"):
            put("name", clip(inp.get("name") or inp.get("subagent_type"), 60))
            put("prompt", clip(inp.get("prompt"), 600))
            resp = d.get("tool_response")
            if isinstance(resp, dict):
                # The spawned agent's id. `to` is the target of Agent and SendMessage.
                put("to", resp.get("agentId") or resp.get("agent_id"))
        elif tool == "Bash":
            # The full command (the summary only has its first line), for `ca wait` and such.
            put("prompt", clip_lines(inp.get("command"), 300))
        elif tool == "SendMessage":
            put("to", clip(inp.get("to") or inp.get("recipient"), 60))
            put("prompt", clip_lines(inp.get("message"), 300))
        elif tool == "SubagentHandback":
            # A teammate style subagent's final report; its Stop message can be empty.
            put("prompt", clip_lines(inp.get("message"), 300))

    if ev == "UserPromptSubmit":
        p = str(d.get("prompt") or "")
        if p.lstrip().startswith("<task-notification>"):
            put("sum", clip(tag(p, "summary") or "A background task finished", 160))
            put("to", tag(p, "task-id"))
        else:
            put("sum", clip("Asked: " + p, 160))
    elif ev == "Notification":
        # notification_type rides in `tool` (permission_prompt, idle_prompt, ...).
        put("tool", d.get("notification_type"))
        put("sum", clip(d.get("message") or d.get("title"), 160))
        put("msg", clip(d.get("message"), 300))
    elif ev in ("Stop", "SubagentStop"):
        put("msg", clip_lines(d.get("last_assistant_message"), 300))
        if ev == "Stop":
            tasks = d.get("background_tasks") or []
            put("bg", [str(t.get("id")) for t in tasks
                       if isinstance(t, dict) and t.get("id") and t.get("status", "running") == "running"])
    elif ev == "StopFailure":
        put("err", clip(d.get("error"), 300))
        put("msg", clip_lines(d.get("last_assistant_message"), 300))
    elif ev == "PostToolUseFailure":
        if d.get("is_interrupt"):
            e["ev"] = "PostToolUse"  # an interrupt is not a failure worth a red node
        else:
            put("err", clip(d.get("error") or "Tool failed", 300))
    elif ev == "PermissionDenied":
        put("err", clip(d.get("reason"), 300))
    elif ev == "SessionStart":
        put("sum", "Session started")
    elif ev == "SessionEnd":
        put("sum", "Session ended")
        put("msg", clip(d.get("reason"), 300))
    elif ev == "TaskCompleted":
        put("sum", clip("Finished task: " + str(d.get("task_subject") or ""), 160))
    elif ev == "TeammateIdle":
        put("name", d.get("teammate_name"))
    return e


def safe_name(s):
    s = "".join(c for c in str(s or "") if c.isalnum() or c in "-_")[:80]
    return s or "unknown"


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
        os.close(fd)  # another hook trimmed and replaced the file meanwhile
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


def hook():
    try:
        raw = sys.stdin.buffer.read()
        d = json.loads(raw.decode("utf-8", "replace"))
        if not isinstance(d, dict):
            return
        e = make_event(d)
        if not e["ev"]:
            return
        root = os.path.join(os.path.expanduser("~"), ".crossagent", "events")
        os.makedirs(root, mode=0o700, exist_ok=True)
        line = (json.dumps(e, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
        append(os.path.join(root, safe_name(e.get("sid")) + ".jsonl"), line)
    except BaseException:
        pass


# MARK: follower

def read_new(fh, n, files, first, since):
    """Complete new lines of one event file, or b"". Uses fstat on the open file so a
    trim (file replaced) between listing and reading cannot mix up offsets."""
    st = os.fstat(fh.fileno())
    f = files.get(n)
    if f is None:
        if first:
            # Existing files: start at the end, or replay from --since.
            f = [st.st_ino, 0, since, 0.0] if since is not None else [st.st_ino, st.st_size, None, 0.0]
        else:
            f = [st.st_ino, 0, None, 0.0]
        files[n] = f
    elif f[0] != st.st_ino or st.st_size < f[1]:
        # Trimmed and replaced: reread, skipping what we already sent.
        f[0], f[1], f[2] = st.st_ino, 0, f[3] + 0.0005
    if st.st_size <= f[1]:
        return b""
    fh.seek(f[1])
    data = fh.read(st.st_size - f[1])
    end = data.rfind(b"\n")
    if end < 0:
        return b""
    f[1] += end + 1
    return data[: end + 1]


def follow(root, since):
    os.makedirs(root, mode=0o700, exist_ok=True)
    now = time.time()
    for n in os.listdir(root):
        p = os.path.join(root, n)
        try:
            if n.endswith(".jsonl") and now - os.stat(p).st_mtime > KEEP_DAYS * 86400:
                os.remove(p)
        except OSError:
            pass

    out = sys.stdout.buffer
    files = {}  # name -> [inode, offset, skip_before_ts or None, last_ts], see read_new
    first = True
    last_beat = now
    while True:
        try:
            names = [n for n in os.listdir(root) if n.endswith(".jsonl")]
        except OSError:
            names = []
        lines = []
        for n in names:
            try:
                fh = open(os.path.join(root, n), "rb")
            except OSError:
                continue
            with fh:
                data = read_new(fh, n, files, first, since)
            if not data:
                continue
            f = files[n]
            for line in data.splitlines():
                if not line.strip():
                    continue
                try:
                    ts = float(json.loads(line).get("ts", 0))
                except Exception:
                    ts = None
                if ts is not None:
                    if f[2] is not None and ts < f[2]:
                        continue
                    f[3] = max(f[3], ts)
                lines.append(line)
            f[2] = None
        for gone in set(files) - set(names):
            del files[gone]
        first = False
        now = time.time()
        if lines or now - last_beat > 2:
            # A blank heartbeat line every 2 s, so a dead reader (the app quit) ends us quickly.
            out.write(b"".join(l + b"\n" for l in lines) if lines else b"\n")
            out.flush()
            last_beat = now
        time.sleep(0.5)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--follow":
        root = os.path.expanduser(args[1] if len(args) > 1 else "~/.crossagent/events")
        since = None
        if "--since" in args:
            try:
                since = float(args[args.index("--since") + 1])
            except (IndexError, ValueError):
                since = None
        try:
            follow(root, since)
        except (BrokenPipeError, KeyboardInterrupt):
            pass
        try:
            sys.stdout = None
        except Exception:
            pass
        os._exit(0)
    hook()
    os._exit(0)


if __name__ == "__main__":
    main()
