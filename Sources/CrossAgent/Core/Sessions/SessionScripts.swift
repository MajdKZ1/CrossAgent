import Foundation

/// The python that runs on ssh hosts. Discovery is one short run per poll; the follower
/// is one long run per open feed. Both only read files under ~/.claude and /proc.
enum SessionScripts {
    /// argv: root, include recent (0/1), recent days, known heads as JSON {path: size,
    /// -1 when the head is final}. Prints one JSON object, see `RemoteScan`.
    static let discovery = #"""
import json, os, re, sys, time, subprocess
UUID = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
root = os.path.expanduser(sys.argv[1]); want_recent = sys.argv[2] == '1'; days = float(sys.argv[3])
known = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
MAXHEAD = 524288
def stat(pid):
    try:
        with open('/proc/%d/stat' % pid) as f: s = f.read()
    except OSError: return None
    r = s.rfind(')'); rest = s[r + 2:].split()
    return s[s.find('(') + 1:r], int(rest[1]), rest[19]
def tty(pid):
    try:
        t = os.readlink('/proc/%d/fd/0' % pid)
        return t[5:] if t.startswith('/dev/') and not t.startswith('/dev/null') else None
    except OSError: return None
def head(path):
    h = {}
    try:
        with open(path, 'rb') as f: data = f.read(MAXHEAD)
    except OSError: return h
    for l in data.split(b'\n'):
        t = b'"type":"ai-title"' in l; u = b'"type":"user"' in l
        if not (t or u or 'cwd' not in h or 'started' not in h): continue
        try: d = json.loads(l)
        except ValueError: continue
        if not isinstance(d, dict): continue
        if 'cwd' not in h and isinstance(d.get('cwd'), str): h['cwd'] = d['cwd']
        if 'started' not in h and isinstance(d.get('timestamp'), str):
            try:
                import datetime
                h['started'] = datetime.datetime.fromisoformat(d['timestamp'].replace('Z', '+00:00')).timestamp()
            except ValueError: pass
        if d.get('type') == 'ai-title' and d.get('aiTitle'): h['aiTitle'] = d['aiTitle']
        if 'prompt' not in h and d.get('type') == 'user' and not d.get('isMeta') and not d.get('isSidechain'):
            c = (d.get('message') or {}).get('content'); p = None
            if isinstance(c, str): p = c
            elif isinstance(c, list):
                p = next((b.get('text') for b in c if isinstance(b, dict) and b.get('type') == 'text'), None)
            p = (p or '').strip()
            if p and not p.startswith('<') and not p.startswith('Caveat:'): h['prompt'] = p[:400]
    return h
def fileinfo(e, path):
    e['path'] = path
    try:
        st = os.stat(path); e['mtime'] = st.st_mtime; e['size'] = st.st_size
    except OSError: return e
    k = known.get(path)
    if k is None or (k != -1 and k != st.st_size):
        e['head'] = head(path); e['headFull'] = st.st_size >= MAXHEAD
    try: e['subagents'] = sum(1 for n in os.listdir(path[:-6] + '/subagents') if n.endswith('.meta.json'))
    except OSError: e['subagents'] = 0
    return e
panes = None
def tmux_of(pids):
    global panes
    if panes is None:
        panes = {}
        try:
            out = subprocess.run(['tmux', 'list-panes', '-a', '-F', '#{pane_pid} #{session_name}'], capture_output=True, text=True, timeout=3).stdout
            for l in out.splitlines():
                a = l.split(' ', 1)
                if len(a) == 2 and a[0].isdigit(): panes[int(a[0])] = a[1]
        except Exception: pass
    return next((panes[p] for p in pids if p in panes), None)
running = []; seen = set()
try: names = os.listdir(root + '/sessions')
except OSError: names = []
for n in names:
    if not n.endswith('.json'): continue
    try:
        with open(root + '/sessions/' + n) as f: s = json.load(f)
        pid = int(s['pid']); sid = s['sessionId']; cwd = s['cwd']
    except Exception: continue
    st = stat(pid)
    if st is None or (s.get('procStart') and str(s['procStart']) != st[2]): continue
    chain = []; pids = []; p = st[1]
    while p > 1 and len(chain) < 32:
        a = stat(p)
        if a is None: break
        chain.append(a[0]); pids.append(p); p = a[1]
    t = s.get('tmux'); t = t.split(':')[0] if isinstance(t, str) and t else None
    if t is None and any(c.startswith('tmux') for c in chain): t = tmux_of(pids)
    e = {'sid': sid, 'cwd': cwd, 'pid': pid, 'tty': tty(pid), 'chain': chain, 'tmux': t,
         'name': s.get('name'), 'nameSource': s.get('nameSource'), 'status': s.get('status'),
         'waitingFor': s.get('waitingFor'), 'started': (s.get('startedAt') or 0) / 1000 or None,
         'statusAt': (s.get('statusUpdatedAt') or 0) / 1000 or None}
    running.append(fileinfo(e, root + '/projects/' + re.sub('[^A-Za-z0-9]', '-', cwd) + '/' + sid + '.jsonl'))
    seen.add(sid)
def environ_marked(pid):
    try:
        with open('/proc/%d/environ' % pid, 'rb') as f: return b'\0CROSSAGENT_CLIENT=1\0' in b'\0' + f.read()
    except OSError: return False
wanted = set(e['tmux'] for e in running if e.get('tmux'))
if wanted:
    clients = {}
    try:
        out = subprocess.run(['tmux', 'list-clients', '-F', '#{client_pid}\t#{session_name}\t#{client_tty}'], capture_output=True, text=True, timeout=3).stdout
    except Exception: out = ''
    for l in out.splitlines():
        a = l.split('\t')
        if len(a) < 2 or not a[0].isdigit() or a[1] not in wanted: continue
        cp = int(a[0]); st = stat(cp)
        if st is None: continue
        chain = []; p = st[1]
        while p > 1 and len(chain) < 32:
            q = stat(p)
            if q is None: break
            chain.append(q[0]); p = q[1]
        clients.setdefault(a[1], []).append({'chain': chain, 'ca': environ_marked(cp)})
    for e in running:
        if e.get('tmux') in clients: e['clients'] = clients[e['tmux']]
recent = None
if want_recent:
    recent = []; cut = time.time() - days * 86400
    try: dirs = list(os.scandir(root + '/projects'))
    except OSError: dirs = []
    for d in dirs:
        if not d.is_dir(): continue
        try: files = list(os.scandir(d.path))
        except OSError: continue
        for f in files:
            if not f.name.endswith('.jsonl') or not f.is_file(): continue
            sid = f.name[:-6]
            if sid in seen or not UUID.match(sid): continue
            try:
                if f.stat().st_mtime < cut: continue
            except OSError: continue
            recent.append(fileinfo({'sid': sid}, f.path))
print(json.dumps({'running': running, 'recent': recent, 'now': time.time()}, separators=(',', ':')))
"""#

    /// argv: root, session id, max bytes to read back on start. Streams
    /// `<tag>\t<payload>` lines: `m` main transcript line, `a:<agentId>` subagent line,
    /// `meta:<agentId>` {"mtime", "meta"}, `s` the session file or null, `hb` heartbeat.
    /// Exits when stdout closes (the heartbeat makes sure it notices).
    static let follower = #"""
import json, os, sys, time, glob
root = os.path.expanduser(sys.argv[1]); sid = sys.argv[2]; cap = int(sys.argv[3])
KEYS = (b'"type":"user"', b'"type":"assistant"', b'"type":"system"')
def emit(tag, s): sys.stdout.write(tag + '\t' + s + '\n')
def clip(v, n): return v[:n] if isinstance(v, str) else v
def slim(line):
    try: d = json.loads(line)
    except ValueError: return None
    if not isinstance(d, dict): return None
    tur = d.get('toolUseResult')
    if isinstance(tur, dict): d['toolUseResult'] = {k: tur[k] for k in ('status', 'agentId') if k in tur}
    elif tur is not None: del d['toolUseResult']
    for k in ('hookInfos', 'wireToolInputs'): d.pop(k, None)
    m = d.get('message')
    if isinstance(m, dict):
        m.pop('usage', None)
        c = m.get('content')
        if isinstance(c, str): m['content'] = clip(c, 20000)
        elif isinstance(c, list):
            for b in c:
                if not isinstance(b, dict): continue
                b.pop('signature', None); t = b.get('type')
                if t == 'tool_result':
                    cc = b.get('content')
                    if isinstance(cc, list): cc = '\n'.join(x.get('text') or '' for x in cc if isinstance(x, dict) and x.get('type') == 'text')
                    b['content'] = clip(cc, 4000)
                elif t == 'tool_use' and isinstance(b.get('input'), dict):
                    b['input'] = {k: clip(v, 2000) for k, v in b['input'].items()}
                elif t in ('text', 'thinking'): b[t] = clip(b.get(t), 20000)
    return json.dumps(d, separators=(',', ':'))
files = {}
def pump(path, tag):
    try: size = os.path.getsize(path)
    except OSError: return
    st = files.get(path)
    if st is None:
        off = max(0, size - cap); st = files[path] = [off, b'', off > 0]
    if size < st[0]: st[0], st[1], st[2] = 0, b'', False
    if size == st[0]: return
    with open(path, 'rb') as f:
        f.seek(st[0]); data = f.read(min(size - st[0], 8 << 20))
    st[0] += len(data)
    lines = (st[1] + data).split(b'\n'); st[1] = lines.pop()
    if st[2] and lines: lines = lines[1:]; st[2] = False
    for l in lines:
        if any(k in l for k in KEYS):
            s = slim(l)
            if s: emit(tag, s)
def proc_start(pid):
    try:
        with open('/proc/%d/stat' % pid) as f: s = f.read()
        return s[s.rfind(')') + 2:].split()[19]
    except (OSError, IndexError): return None
metas = {}; main = None; last_s = ''; next_s = 0; next_find = 0; next_hb = 0
try:
    while True:
        now = time.time()
        if main is None and now >= next_find:
            found = glob.glob(root + '/projects/*/' + glob.escape(sid) + '.jsonl')
            main = found[0] if found else None; next_find = now + 2
        if main:
            pump(main, 'm')
            sub = main[:-6] + '/subagents'
            try: names = sorted(os.listdir(sub))
            except OSError: names = []
            for n in names:
                if not n.startswith('agent-'): continue
                p = sub + '/' + n
                if n.endswith('.jsonl'): pump(p, 'a:' + n[6:-6])
                elif n.endswith('.meta.json'):
                    try: mt = os.path.getmtime(p)
                    except OSError: continue
                    if metas.get(p) != mt:
                        try:
                            with open(p) as f: meta = json.load(f)
                        except (OSError, ValueError): continue
                        metas[p] = mt
                        emit('meta:' + n[6:-10], json.dumps({'mtime': mt, 'meta': meta}, separators=(',', ':')))
        if now >= next_s:
            next_s = now + 1; cur = None
            try: names = os.listdir(root + '/sessions')
            except OSError: names = []
            for n in names:
                if not n.endswith('.json'): continue
                try:
                    with open(root + '/sessions/' + n) as f: s = json.load(f)
                except (OSError, ValueError): continue
                if s.get('sessionId') != sid: continue
                ps = proc_start(int(s.get('pid') or 0))
                if ps is not None and (not s.get('procStart') or str(s['procStart']) == ps):
                    cur = json.dumps(s, separators=(',', ':')); break
            if cur != last_s:
                last_s = cur; emit('s', cur or 'null')
        if now >= next_hb:
            next_hb = now + 2; emit('hb', '{}')
        sys.stdout.flush()
        time.sleep(0.5)
except (BrokenPipeError, KeyboardInterrupt):
    pass
finally:
    try: sys.stdout.close()
    except Exception: pass
"""#
}
