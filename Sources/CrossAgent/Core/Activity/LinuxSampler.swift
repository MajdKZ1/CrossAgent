import Foundation

/// The sampler that runs on a Linux host. Python reads raw counters and prints one
/// JSON line per tick; all the math happens here so it can be tested.
enum LinuxSampler {
    static let interval: TimeInterval = 1.5

    /// Stdlib only, passed inline with `python3 -I -c`, nothing is installed on the host.
    /// Line fields: t, cpu [[name, user, nice, system, idle, iowait, irq, softirq, steal]],
    /// mem {key: kB}, psi (memory some avg10), hw [[chip, label, millidegrees]],
    /// gpu [temp, util], ses [[session, percent of a core, rss bytes, claude]].
    static let script = #"""
import os, sys, time, json, glob, re, shutil, subprocess, threading
iv = float(sys.argv[1]) if len(sys.argv) > 1 else 1.5
hz = os.sysconf('SC_CLK_TCK'); pg = os.sysconf('SC_PAGE_SIZE')
def rd(p):
    try:
        with open(p) as f: return f.read()
    except OSError: return None
def cpu():
    out = []
    for l in (rd('/proc/stat') or '').splitlines():
        if not l.startswith('cpu'): break
        f = l.split(); out.append([f[0]] + [int(x) for x in f[1:9]])
    return out
def mem():
    out = {}
    for l in (rd('/proc/meminfo') or '').splitlines():
        k, _, v = l.partition(':')
        if k in ('MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree'): out[k] = int(v.split()[0])
    return out
def psi():
    m = re.search(r'some avg10=([0-9.]+)', rd('/proc/pressure/memory') or '')
    return float(m.group(1)) if m else None
def hwmon():
    out = []
    for d in sorted(glob.glob('/sys/class/hwmon/hwmon*')):
        n = (rd(d + '/name') or '?').strip()
        for f in sorted(glob.glob(d + '/temp*_input')):
            try: v = int(rd(f))
            except (TypeError, ValueError): continue
            out.append([n, (rd(f[:-6] + '_label') or os.path.basename(f)[:-6]).strip(), v])
    return out
def sensors():
    out = []
    try: j = json.loads(subprocess.run(['sensors', '-j'], capture_output=True, text=True, timeout=3).stdout)
    except Exception: return out
    for chip, v in j.items():
        for label, sub in v.items():
            if not isinstance(sub, dict): continue
            for k, x in sub.items():
                if k.startswith('temp') and k.endswith('_input'): out.append([chip.split('-')[0], label, int(x * 1000)])
    return out
gpu = [None]
def nv():
    try:
        p = subprocess.Popen(['nvidia-smi', '--query-gpu=temperature.gpu,utilization.gpu', '--format=csv,noheader,nounits', '-l', '3'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        for l in p.stdout:
            try: gpu[0] = [float(x) for x in l.split(',')[:2]]
            except ValueError: pass
    except OSError: pass
if shutil.which('nvidia-smi'): threading.Thread(target=nv, daemon=True).start()
prev = None
def ses():
    global prev
    try: o = subprocess.run(['tmux', 'list-panes', '-a', '-F', '#{session_name}\t#{pane_pid}'], capture_output=True, text=True, timeout=2).stdout
    except Exception: o = ''
    roots = {}
    for l in o.splitlines():
        s, _, p = l.partition('\t')
        if s.startswith('ca-') and p.isdigit(): roots[int(p)] = s
    info, kids = {}, {}
    for d in os.listdir('/proc'):
        if not d.isdigit(): continue
        st = rd('/proc/' + d + '/stat')
        if not st: continue
        r = st.rfind(')'); f = st[r + 2:].split()
        pid = int(d); info[pid] = (int(f[11]) + int(f[12]), int(f[21]) * pg, st[st.find('(') + 1:r])
        kids.setdefault(int(f[1]), []).append(pid)
    now = time.monotonic(); last = prev; prev = (now, {p: v[0] for p, v in info.items()})
    if last is None: return None
    dt = now - last[0]; out = {}
    for root, name in roots.items():
        t, rss, cl, stack = 0, 0, False, [root]
        while stack:
            p = stack.pop()
            if p not in info: continue
            ticks, r, comm = info[p]
            t += max(0, ticks - last[1].get(p, 0)); rss += r
            cl = cl or comm == 'claude' or re.match(r'^\d+\.\d+\.\d+$', comm) is not None
            stack.extend(kids.get(p, []))
        a = out.setdefault(name, [name, 0.0, 0, False])
        a[1] += round(t / hz / dt * 100, 1); a[2] += rss; a[3] = a[3] or cl
    return list(out.values())
use_sensors = not hwmon()
n = 0
while True:
    t0 = time.time()
    o = {'t': round(t0, 3), 'cpu': cpu(), 'mem': mem(), 'psi': psi(), 'hw': sensors() if use_sensors else hwmon()}
    if gpu[0]: o['gpu'] = gpu[0]
    if n % 2 == 0:
        s = ses()
        if s is not None: o['ses'] = s
    sys.stdout.write(json.dumps(o, separators=(',', ':')) + '\n'); sys.stdout.flush()
    n += 1
    time.sleep(max(0.2, iv - (time.time() - t0)))
"""#

    static func command(host: Host) -> SpawnCommand {
        CommandBuilder.oneShot(host: host, script: "exec python3 -I -u -c \(CommandBuilder.shellQuote(script)) \(interval)")
    }

    /// One decoded line, before any deltas.
    struct Raw: Equatable {
        var cpu: [String: [UInt64]] = [:]
        var mem: [String: UInt64] = [:]
        var psi: Double?
        var hw: [(chip: String, label: String, milli: Int)] = []
        var gpuTemp: Double?
        var gpuUtil: Double?
        var sessions: [SessionLoad]?

        static func == (a: Raw, b: Raw) -> Bool {
            a.cpu == b.cpu && a.mem == b.mem && a.psi == b.psi && a.gpuTemp == b.gpuTemp && a.gpuUtil == b.gpuUtil
                && a.sessions == b.sessions && a.hw.map { "\($0.chip)|\($0.label)|\($0.milli)" } == b.hw.map { "\($0.chip)|\($0.label)|\($0.milli)" }
        }
    }

    /// Tolerant: a broken or foreign line gives nil.
    static func parse(_ line: Data) -> Raw? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cpuRows = obj["cpu"] as? [[Any]] else { return nil }
        var raw = Raw()
        for row in cpuRows {
            guard let name = row.first as? String else { continue }
            raw.cpu[name] = row.dropFirst().compactMap { ($0 as? NSNumber)?.uint64Value }
        }
        if let mem = obj["mem"] as? [String: Any] {
            for (k, v) in mem { if let n = v as? NSNumber { raw.mem[k] = n.uint64Value } }
        }
        raw.psi = (obj["psi"] as? NSNumber)?.doubleValue
        for row in obj["hw"] as? [[Any]] ?? [] where row.count >= 3 {
            guard let chip = row[0] as? String, let label = row[1] as? String, let v = row[2] as? NSNumber else { continue }
            raw.hw.append((chip, label, v.intValue))
        }
        if let g = obj["gpu"] as? [NSNumber], g.count >= 2 {
            raw.gpuTemp = g[0].doubleValue
            raw.gpuUtil = g[1].doubleValue
        }
        if let rows = obj["ses"] as? [[Any]] {
            raw.sessions = rows.compactMap { r in
                guard r.count >= 4, let name = r[0] as? String, let cpu = r[1] as? NSNumber,
                      let rss = r[2] as? NSNumber else { return nil }
                return SessionLoad(name: name, cpu: cpu.doubleValue, rssBytes: rss.uint64Value, claude: (r[3] as? Bool) ?? false)
            }
        }
        return raw
    }

    /// /proc/stat fields: user nice system idle iowait irq softirq steal.
    /// Idle is idle + iowait, the same split top uses for its "id" and "wa".
    static func ticks(_ f: [UInt64]) -> CPUTicks? {
        guard f.count >= 4 else { return nil }
        let at = { (i: Int) in i < f.count ? f[i] : 0 }
        return CPUTicks(busy: at(0) + at(1) + at(2) + at(5) + at(6) + at(7), idle: at(3) + at(4))
    }

    /// Memory used the way `free` counts it: total minus available.
    static func memory(_ mem: [String: UInt64]) -> (used: UInt64, total: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
        let total = (mem["MemTotal"] ?? 0) * 1024
        let avail = (mem["MemAvailable"] ?? 0) * 1024
        let swapTotal = (mem["SwapTotal"] ?? 0) * 1024
        let swapFree = (mem["SwapFree"] ?? 0) * 1024
        return (total > avail ? total - avail : 0, total, swapTotal > swapFree ? swapTotal - swapFree : 0, swapTotal)
    }

    /// PSI "some avg10" is the share of the last 10 s where something waited on memory.
    static func pressure(psi: Double?, memFraction: Double) -> PressureLevel {
        if let psi { return psi >= 10 ? .critical : (psi >= 1 ? .warning : .normal) }
        return memFraction >= 0.95 ? .critical : (memFraction >= 0.85 ? .warning : .normal)
    }

    /// Picks one tile per kind from hwmon readings. CPU prefers Tctl, then Tdie, then
    /// Intel's package sensor, and lists the CCDs as detail. Storage is the NVMe composite.
    static func temps(_ hw: [(chip: String, label: String, milli: Int)], gpuTemp: Double?) -> [TempGroup] {
        func c(_ m: Int) -> Double { Double(m) / 1000 }
        let valid = hw.filter { $0.milli > -40_000 && $0.milli < 150_000 }
        var out: [TempGroup] = []

        let cpuChips: Set = ["k10temp", "zenpower", "coretemp", "cpu_thermal"]
        let cpu = valid.filter { cpuChips.contains($0.chip) }
        if let main = cpu.first(where: { $0.label == "Tctl" }) ?? cpu.first(where: { $0.label == "Tdie" })
            ?? cpu.first(where: { $0.label.hasPrefix("Package") }) ?? cpu.first {
            let ccds = cpu.filter { $0.label.hasPrefix("Tccd") }
            let detail = ccds.isEmpty ? nil : ccds.map { "\($0.label.replacingOccurrences(of: "Tccd", with: "CCD")) \(ActivityFormat.degrees(c($0.milli)))" }.joined(separator: "  ")
            out.append(TempGroup(kind: .cpu, label: "CPU", celsius: c(main.milli), detail: detail))
        }

        let gpuChips: Set = ["amdgpu", "nouveau", "radeon"]
        let gpu = valid.filter { gpuChips.contains($0.chip) }
        if let main = gpu.first(where: { $0.label == "edge" }) ?? gpu.first {
            let junction = gpu.first { $0.label == "junction" }
            out.append(TempGroup(kind: .gpu, label: "GPU", celsius: c(main.milli),
                                 detail: junction.map { "junction \(ActivityFormat.degrees(c($0.milli)))" }))
        } else if let gpuTemp {
            out.append(TempGroup(kind: .gpu, label: "GPU", celsius: gpuTemp, detail: nil))
        }

        let disks = valid.filter { $0.chip == "nvme" || $0.chip == "drivetemp" }
        if let main = disks.first(where: { $0.label == "Composite" }) ?? disks.first {
            let hottest = disks.map(\.milli).max() ?? main.milli
            out.append(TempGroup(kind: .storage, label: "SSD", celsius: c(main.milli),
                                 detail: hottest > main.milli + 5000 ? "hottest \(ActivityFormat.degrees(c(hottest)))" : nil))
        }
        return out
    }

    /// Turns raw lines into samples. Keeps the previous CPU ticks for the deltas.
    struct Accumulator {
        private var previous: [String: CPUTicks] = [:]

        mutating func sample(_ raw: Raw, at time: Date = Date()) -> ActivitySample {
            var s = ActivitySample(time: time)
            var current: [String: CPUTicks] = [:]
            for (name, fields) in raw.cpu { current[name] = LinuxSampler.ticks(fields) }
            if let now = current["cpu"], let before = previous["cpu"] { s.cpu = now.usage(since: before) }
            let coreNames = current.keys.filter { $0 != "cpu" }.sorted {
                (Int($0.dropFirst(3)) ?? 0) < (Int($1.dropFirst(3)) ?? 0)
            }
            if !previous.isEmpty {
                s.cores = coreNames.map { n in
                    guard let now = current[n], let before = previous[n] else { return 0 }
                    return now.usage(since: before) ?? 0
                }
            }
            previous = current

            let m = LinuxSampler.memory(raw.mem)
            s.memUsed = m.used
            s.memTotal = m.total
            s.swapUsed = m.swapUsed
            s.swapTotal = m.swapTotal
            s.pressure = LinuxSampler.pressure(psi: raw.psi, memFraction: s.memFraction)
            if let psi = raw.psi { s.pressureDetail = String(format: "stall %.1f%%", psi) }
            s.temps = LinuxSampler.temps(raw.hw, gpuTemp: raw.gpuTemp)
            s.gpu = raw.gpuUtil.map { $0 / 100 }
            return s
        }
    }
}
