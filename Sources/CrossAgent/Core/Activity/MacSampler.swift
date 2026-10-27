import Darwin
import Foundation
import IOKit

/// Samples this Mac on a background queue: CPU ticks, memory, swap, pressure,
/// temperatures and, when asked, per tmux session load. Results arrive on the main actor.
final class MacSampler: @unchecked Sendable {
    static let interval: TimeInterval = 1.5

    private let onSample: @MainActor (ActivitySample, [SessionLoad]?) -> Void
    private let queue = DispatchQueue(label: "crossagent.activity.mac", qos: .utility)

    // Everything below is only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var previousCores: [CPUTicks] = []
    private var previousProcs: (time: UInt64, cpu: [pid_t: UInt64])?
    private var tick = 0
    private var wantSessions = false
    private lazy var temperatures = MacTemperatures()
    private lazy var clusters = Self.clusterLayout()

    init(onSample: @escaping @MainActor (ActivitySample, [SessionLoad]?) -> Void) {
        self.onSample = onSample
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(150))
            t.setEventHandler { [weak self] in self?.sampleNow() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            previousCores = []
            previousProcs = nil
        }
    }

    /// Session load needs a tmux call and a process walk, so it only runs while someone shows it.
    func setWantsSessions(_ on: Bool) {
        queue.async { [self] in
            wantSessions = on
            if !on { previousProcs = nil }
        }
    }

    private func sampleNow() {
        var s = ActivitySample()
        if let cores = Self.coreTicks() {
            if previousCores.count == cores.count {
                s.cores = zip(cores, previousCores).map { $0.usage(since: $1) ?? 0 }
                s.cpu = Self.sum(cores).usage(since: Self.sum(previousCores))
                s.clusters = clusters.map { c in
                    let now = Self.sum(c.cores.filter { $0 < cores.count }.map { cores[$0] })
                    let before = Self.sum(c.cores.filter { $0 < cores.count }.map { previousCores[$0] })
                    return CoreCluster(name: c.name, cores: c.cores, usage: now.usage(since: before) ?? 0)
                }
            }
            previousCores = cores
        }
        if let vm = Self.vmStats() {
            s.memUsed = MacMemory.used(vm, pageSize: UInt64(vm_kernel_page_size))
        }
        s.memTotal = Self.sysctlUInt64("hw.memsize") ?? 0
        if let level = Self.sysctlInt("kern.memorystatus_vm_pressure_level") {
            s.pressure = MacMemory.pressure(level)
        }
        if let free = Self.sysctlInt("kern.memorystatus_level") { s.pressureDetail = "\(free)% free" }
        if let swap = Self.swapUsage() {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }
        if let temps = temperatures { s.temps = MacTemperatures.group(temps.read()) }

        var sessions: [SessionLoad]?
        if wantSessions, tick % 2 == 0 { sessions = sampleSessions() }
        tick += 1

        let deliver = onSample
        DispatchQueue.main.async { [s, sessions] in MainActor.assumeIsolated { deliver(s, sessions) } }
    }

    // MARK: CPU

    private static func sum(_ t: [CPUTicks]) -> CPUTicks {
        t.reduce(CPUTicks(busy: 0, idle: 0)) { CPUTicks(busy: $0.busy + $1.busy, idle: $0.idle + $1.idle) }
    }

    static func coreTicks() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(count)).map { i in
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            return CPUTicks(busy: user + system + nice, idle: idle)
        }
    }

    /// Which logical CPUs belong to which cluster. The IORegistry marks each CPU with
    /// "cluster-type" E or P. On M5 that is cpu0-5 Efficiency, cpu6-9 Super: efficiency
    /// cores come first, so the fallback from the sysctl counts assumes that order too.
    static func clusterLayout() -> [(name: String, cores: [Int])] {
        let levels = (0..<(sysctlInt("hw.nperflevels") ?? 0)).map { i in
            (name: sysctlString("hw.perflevel\(i).name") ?? (i == 0 ? "Performance" : "Efficiency"),
             count: sysctlInt("hw.perflevel\(i).logicalcpu") ?? 0)
        }
        guard levels.count >= 2 else { return [] }
        let pName = levels[0].name, eName = levels[1].name
        var p: [Int] = [], e: [Int] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"), &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            while case let entry = IOIteratorNext(iter), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let type = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Data,
                      let id = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? NSNumber else { continue }
                if type.first == UInt8(ascii: "P") { p.append(id.intValue) } else if type.first == UInt8(ascii: "E") { e.append(id.intValue) }
            }
        }
        if p.isEmpty || e.isEmpty {
            e = Array(0..<levels[1].count)
            p = Array(levels[1].count..<(levels[1].count + levels[0].count))
        }
        return [(pName, p.sorted()), (eName, e.sorted())]
    }

    // MARK: Memory

    static func vmStats() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return r == KERN_SUCCESS ? stats : nil
    }

    static func swapUsage() -> xsw_usage? {
        var u = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &u, &size, nil, 0) == 0 ? u : nil
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: Sessions

    static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// `ca-*` session name for each pane pid.
    static func paneRoots() -> [pid_t: String] {
        guard let tmux = tmuxPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return MacProcesses.parsePanes(String(decoding: data, as: UTF8.self))
    }

    private func sampleSessions() -> [SessionLoad]? {
        let roots = Self.paneRoots()
        let now = mach_absolute_time()
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticksToNs = Double(tb.numer) / Double(tb.denom)
        let elapsedNs = previousProcs.map { Double(now - $0.time) * ticksToNs } ?? 0
        let result = MacProcesses.loads(roots: roots, procs: MacProcesses.snapshot(), previous: previousProcs?.cpu ?? [:],
                                        elapsedNs: elapsedNs, ticksToNs: ticksToNs)
        let first = previousProcs == nil
        previousProcs = (now, result.cpuTimes)
        return first ? nil : result.sessions
    }
}

/// Activity Monitor's "Memory Used": app memory + wired + compressed.
enum MacMemory {
    static func used(_ vm: vm_statistics64, pageSize: UInt64) -> UInt64 {
        used(appPages: UInt64(vm.internal_page_count), purgeable: UInt64(vm.purgeable_count),
             wired: UInt64(vm.wire_count), compressed: UInt64(vm.compressor_page_count), pageSize: pageSize)
    }

    static func used(appPages: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64) -> UInt64 {
        let app = appPages > purgeable ? appPages - purgeable : 0
        return (app + wired + compressed) * pageSize
    }

    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    static func pressure(_ level: Int) -> PressureLevel {
        level >= 4 ? .critical : (level >= 2 ? .warning : .normal)
    }
}

/// Process tree walk for per session load, via libproc (no `ps` spawn).
enum MacProcesses {
    struct Proc {
        var ppid: pid_t
        var comm: String
        /// Mach absolute time units, user + system. Filled in by `loads` for pane trees only.
        var cpuTime: UInt64 = 0
        var rss: UInt64 = 0
    }

    static func parsePanes(_ text: String) -> [pid_t: String] {
        var roots: [pid_t: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, parts[0].hasPrefix("ca-"), let pid = pid_t(parts[1]) else { continue }
            roots[pid] = String(parts[0])
        }
        return roots
    }

    static func snapshot() -> [pid_t: Proc] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [:] }
        var out: [pid_t: Proc] = [:]
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            let comm = withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            out[pid] = Proc(ppid: pid_t(bsd.pbi_ppid), comm: comm)
        }
        return out
    }

    /// Fills in CPU time and memory, but only for processes under a pane: task info
    /// for every process on the Mac would be wasted work.
    static func loads(roots: [pid_t: String], procs: [pid_t: Proc], previous: [pid_t: UInt64],
                      elapsedNs: Double, ticksToNs: Double) -> (sessions: [SessionLoad], cpuTimes: [pid_t: UInt64]) {
        var cpuTimes: [pid_t: UInt64] = [:]
        var kids: [pid_t: [pid_t]] = [:]
        for (pid, p) in procs { kids[p.ppid, default: []].append(pid) }
        var out: [String: SessionLoad] = [:]
        for (root, name) in roots {
            var load = out[name] ?? SessionLoad(name: name, cpu: 0, rssBytes: 0, claude: false)
            var stack = [root]
            while let pid = stack.popLast() {
                guard var p = procs[pid], cpuTimes[pid] == nil else { continue }
                var ti = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                    p.cpuTime = ti.pti_total_user + ti.pti_total_system
                    p.rss = ti.pti_resident_size
                }
                cpuTimes[pid] = p.cpuTime
                let before = previous[pid] ?? 0
                if elapsedNs > 0, p.cpuTime > before {
                    load.cpu += Double(p.cpuTime - before) * ticksToNs / elapsedNs * 100
                }
                load.rssBytes += p.rss
                load.claude = load.claude || SessionDetector.isClaudeCodeProcess(p.comm)
                stack.append(contentsOf: kids[pid] ?? [])
            }
            out[name] = load
        }
        return (Array(out.values), cpuTimes)
    }
}
