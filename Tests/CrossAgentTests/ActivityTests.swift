import XCTest
@testable import CrossAgent

final class ActivityTests: XCTestCase {
    // MARK: /proc/stat

    func testTicksSplitIowaitIntoIdle() throws {
        // user nice system idle iowait irq softirq steal
        let t = try XCTUnwrap(LinuxSampler.ticks([100, 5, 50, 800, 20, 3, 7, 1]))
        XCTAssertEqual(t.busy, 166)
        XCTAssertEqual(t.idle, 820)
    }

    func testCPUDelta() {
        let a = CPUTicks(busy: 1000, idle: 9000)
        let b = CPUTicks(busy: 1300, idle: 9100)
        XCTAssertEqual(b.usage(since: a)!, 0.75, accuracy: 1e-9)
        XCTAssertNil(a.usage(since: a), "no time passed")
        XCTAssertNil(a.usage(since: b), "counters went backwards")
    }

    func line(cpu: [[Any]], extra: String = "") -> Data {
        let rows = cpu.map { r in "[" + r.map { v in v is String ? "\"\(v)\"" : "\(v)" }.joined(separator: ",") + "]" }
        return Data(#"{"t":1,"cpu":[\#(rows.joined(separator: ","))],"mem":{"MemTotal":32000000,"MemAvailable":24000000,"SwapTotal":8000000,"SwapFree":7000000}\#(extra)}"#.utf8)
    }

    func testAccumulatorComputesTotalAndPerCore() throws {
        var acc = LinuxSampler.Accumulator()
        let first = try XCTUnwrap(LinuxSampler.parse(line(cpu: [
            ["cpu", 100, 0, 100, 1800, 0, 0, 0, 0], ["cpu0", 50, 0, 50, 900, 0, 0, 0, 0], ["cpu1", 50, 0, 50, 900, 0, 0, 0, 0],
        ])))
        let s1 = acc.sample(first)
        XCTAssertNil(s1.cpu, "first line has nothing to compare against")
        XCTAssertTrue(s1.cores.isEmpty)
        // cpu0 fully busy for 100 ticks, cpu1 idle.
        let second = try XCTUnwrap(LinuxSampler.parse(line(cpu: [
            ["cpu", 200, 0, 100, 1900, 0, 0, 0, 0], ["cpu0", 150, 0, 50, 900, 0, 0, 0, 0], ["cpu1", 50, 0, 50, 1000, 0, 0, 0, 0],
        ])))
        let s2 = acc.sample(second)
        XCTAssertEqual(s2.cpu!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s2.cores, [1, 0])
    }

    func testCoresSortNumerically() throws {
        var acc = LinuxSampler.Accumulator()
        let rows: (Int) -> [[Any]] = { k in
            [["cpu", k, 0, 0, 100, 0, 0, 0, 0]] + (0..<12).map { i in ["cpu\(i)", i == 10 ? k : 0, 0, 0, 100, 0, 0, 0, 0] }
        }
        _ = acc.sample(try XCTUnwrap(LinuxSampler.parse(line(cpu: rows(0)))))
        let s = acc.sample(try XCTUnwrap(LinuxSampler.parse(line(cpu: rows(100)))))
        XCTAssertEqual(s.cores.count, 12)
        XCTAssertEqual(s.cores[10], 1, "cpu10 must not sort between cpu1 and cpu2")
        XCTAssertEqual(s.cores[2], 0)
    }

    // MARK: meminfo

    func testMeminfo() {
        let m = LinuxSampler.memory(["MemTotal": 32_000_000, "MemAvailable": 27_500_000, "SwapTotal": 8_388_604, "SwapFree": 8_388_604])
        XCTAssertEqual(m.total, 32_000_000 * 1024)
        XCTAssertEqual(m.used, (32_000_000 - 27_500_000) * 1024)
        XCTAssertEqual(m.swapUsed, 0)
        XCTAssertEqual(m.swapTotal, 8_388_604 * 1024)
        let empty = LinuxSampler.memory([:])
        XCTAssertEqual(empty.used, 0)
    }

    func testPressureFromPSI() {
        XCTAssertEqual(LinuxSampler.pressure(psi: 0, memFraction: 0.99), .normal, "PSI wins when present")
        XCTAssertEqual(LinuxSampler.pressure(psi: 2.5, memFraction: 0.1), .warning)
        XCTAssertEqual(LinuxSampler.pressure(psi: 30, memFraction: 0.1), .critical)
        XCTAssertEqual(LinuxSampler.pressure(psi: nil, memFraction: 0.9), .warning)
    }

    // MARK: hwmon

    // A line as the PC sampler prints it (Ryzen, NVMe, a GeForce on the nvidia driver).
    let pcLine = #"{"t":1793102294.715,"cpu":[["cpu",1,0,1,10,0,0,0,0]],"mem":{"MemTotal":32000000,"MemAvailable":27500000,"SwapTotal":8388604,"SwapFree":8388604},"psi":0.0,"hw":[["nvme","Composite",36850],["nvme","Sensor 1",42850],["nvme","Sensor 2",69850],["nvme","Sensor 3",36850],["k10temp","Tctl",39750],["k10temp","Tccd1",39500]],"gpu":[42.0,6.0],"ses":[["ca-x-pc-1",12.5,104857600,true],["ca-y-pc-1",0.0,2048,false]]}"#

    func testParsesRealLine() throws {
        let raw = try XCTUnwrap(LinuxSampler.parse(Data(pcLine.utf8)))
        XCTAssertEqual(raw.hw.count, 6)
        XCTAssertEqual(raw.gpuTemp, 42)
        XCTAssertEqual(raw.gpuUtil, 6)
        XCTAssertEqual(raw.psi, 0)
        XCTAssertEqual(raw.sessions, [SessionLoad(name: "ca-x-pc-1", cpu: 12.5, rssBytes: 104_857_600, claude: true),
                                      SessionLoad(name: "ca-y-pc-1", cpu: 0, rssBytes: 2048, claude: false)])
        var acc = LinuxSampler.Accumulator()
        let s = acc.sample(raw)
        XCTAssertEqual(s.gpu!, 0.06, accuracy: 1e-9)
        XCTAssertEqual(s.pressureDetail, "stall 0.0%")
    }

    func testHwmonGrouping() throws {
        let raw = try XCTUnwrap(LinuxSampler.parse(Data(pcLine.utf8)))
        let t = LinuxSampler.temps(raw.hw, gpuTemp: raw.gpuTemp)
        XCTAssertEqual(t.map(\.kind), [.cpu, .gpu, .storage])
        XCTAssertEqual(t[0].celsius, 39.75, accuracy: 1e-9)
        XCTAssertEqual(t[0].detail, "CCD1 40°")
        XCTAssertEqual(t[1].celsius, 42)
        XCTAssertEqual(t[2].celsius, 36.85, accuracy: 1e-9)
        XCTAssertEqual(t[2].detail, "hottest 70°")
    }

    func testHwmonAMDGPUAndIntel() {
        let t = LinuxSampler.temps([("coretemp", "Core 0", 50000), ("coretemp", "Package id 0", 55000),
                                    ("amdgpu", "edge", 45000), ("amdgpu", "junction", 60000), ("amdgpu", "mem", 52000),
                                    ("acpitz", "temp1", 27800), ("nvme", "Composite", -273_000)],
                                   gpuTemp: 99)
        XCTAssertEqual(t.map(\.kind), [.cpu, .gpu], "bogus nvme reading is dropped, acpitz ignored")
        XCTAssertEqual(t[0].celsius, 55)
        XCTAssertEqual(t[1].celsius, 45, "hwmon GPU beats nvidia-smi")
        XCTAssertEqual(t[1].detail, "junction 60°")
    }

    func testBrokenLines() {
        XCTAssertNil(LinuxSampler.parse(Data("".utf8)))
        XCTAssertNil(LinuxSampler.parse(Data("Welcome to Ubuntu".utf8)))
        XCTAssertNil(LinuxSampler.parse(Data(#"{"t":1}"#.utf8)))
    }

    func testSamplerCommandIsInlineOverControlMaster() {
        let pc = Host(id: "pc", name: "Linux PC", type: .ssh, target: "pc", accent: "#5fd39a")
        let cmd = LinuxSampler.command(host: pc)
        XCTAssertEqual(cmd.executable, "/usr/bin/ssh")
        XCTAssertTrue(cmd.args.contains("ControlMaster=auto"))
        XCTAssertTrue(cmd.args.last!.contains("python3 -I -u -c"))
        XCTAssertFalse(LinuxSampler.script.contains("\u{2014}"))
    }

    // MARK: Mac

    func testVMStatsMath() {
        // Activity Monitor: app (internal - purgeable) + wired + compressed.
        let used = MacMemory.used(appPages: 700_000, purgeable: 20_000, wired: 150_000, compressed: 50_000, pageSize: 16384)
        XCTAssertEqual(used, (680_000 + 150_000 + 50_000) * 16384)
        XCTAssertEqual(MacMemory.used(appPages: 10, purgeable: 20, wired: 0, compressed: 0, pageSize: 16384), 0)
        XCTAssertEqual(MacMemory.pressure(1), .normal)
        XCTAssertEqual(MacMemory.pressure(2), .warning)
        XCTAssertEqual(MacMemory.pressure(4), .critical)
    }

    func testMacTempGrouping() {
        let readings: [(name: String, celsius: Double)] = [
            ("PMU tdie1", 36), ("PMU tdie2", 40), ("PMU2 tdie1", 38), ("PMU tdev1", -9199),
            ("gas gauge battery", 31), ("gas gauge battery", 31.4), ("NAND CH0 temp", 35),
        ]
        let g = MacTemperatures.group(readings)
        XCTAssertEqual(g.map(\.kind), [.cpu, .storage, .battery])
        XCTAssertEqual(g[0].celsius, 38, accuracy: 1e-9)
        XCTAssertEqual(g[0].detail, "hottest 40°")
        XCTAssertEqual(g[2].celsius, 31.2, accuracy: 1e-9)
    }

    func testPaneParsing() {
        let roots = MacProcesses.parsePanes("ca-a-mac-1\t123\nother\t5\nca-b-mac-1\tx\n")
        XCTAssertEqual(roots, [123: "ca-a-mac-1"])
    }

    func testClusterLayoutCoversEveryCore() throws {
        let layout = MacSampler.clusterLayout()
        try XCTSkipIf(layout.isEmpty, "not Apple Silicon")
        let all = layout.flatMap(\.cores).sorted()
        XCTAssertEqual(all, Array(0..<ProcessInfo.processInfo.processorCount))
    }

    func testSeriesIsBounded() {
        var s = Series()
        for i in 0..<500 { s.append(Double(i)) }
        XCTAssertEqual(s.values.count, Series.capacity)
        XCTAssertEqual(s.values.last, 499)
    }

    // MARK: Sampler lifecycle

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Processes whose command line contains `marker`. `ownChildren` limits it to this test
    /// process's children, since a running CrossAgent has its own samplers.
    static func processes(matching marker: String, ownChildren: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = (ownChildren ? ["-P", "\(getpid())"] : []) + ["-fl", marker]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Regression: stopping used to leave the stdout handler on a pipe at EOF, which then
    /// fired nonstop. Twenty pauses meant twenty spinning handlers.
    @MainActor
    func testStartStopLeaksNoHandlerOrProcess() async throws {
        let marker = "ca-sampler-test-\(UUID().uuidString.prefix(8))"
        let line = #"{"cpu":[["cpu",1,0,1,10,0,0,0,0]],"mem":{}}"#
        let fake = SpawnCommand(executable: "/bin/sh",
                                args: ["-c", "trap 'exit 0' TERM; while :; do echo '\(line)'; sleep 0.05; done", marker])
        let pc = Host(id: "pc", name: "Linux PC", type: .ssh, target: "pc", accent: "#5fd39a")
        var samples = 0
        let sampler = RemoteSampler(host: pc, command: fake) { e in
            if case .sample = e { samples += 1 }
        }
        for _ in 0..<20 {
            sampler.start()
            try await Task.sleep(nanoseconds: 150_000_000)
            sampler.stop()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        sampler.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        sampler.shutdown()
        XCTAssertGreaterThan(samples, 20, "the fake sampler should have streamed")
        XCTAssertEqual(Self.processes(matching: marker), "", "shutdown waits for the process")

        try await Task.sleep(nanoseconds: 500_000_000)
        let before = Self.cpuSeconds()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let used = Self.cpuSeconds() - before
        XCTAssertLessThan(used, 0.2, "CPU while stopped should be flat, got \(used) s over 2 s")
        XCTAssertEqual(Self.processes(matching: marker), "")
    }

    // MARK: Live dump

    /// `CROSSAGENT_ACTIVITY_DUMP=<seconds> swift test --filter ActivityTests/testLiveDump`
    /// prints every sample from both hosts to stderr. Used to compare against top and friends.
    @MainActor
    func testLiveDump() async throws {
        guard let v = ProcessInfo.processInfo.environment["CROSSAGENT_ACTIVITY_DUMP"] else {
            throw XCTSkip("set CROSSAGENT_ACTIVITY_DUMP to run")
        }
        let seconds = Double(v) ?? 10
        let monitor = ActivityMonitor.shared
        monitor.start(hosts: HostStore.load(), detail: true)
        var seen: [String: Date] = [:]
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await Task.sleep(nanoseconds: 200_000_000)
            for h in monitor.hosts {
                guard let s = h.latest, seen[h.hostId] != s.time else {
                    if case .unavailable(let why) = h.status { FileHandle.standardError.write(Data("\(h.name) unavailable: \(why)\n".utf8)) }
                    continue
                }
                seen[h.hostId] = s.time
                FileHandle.standardError.write(Data((Self.describe(h, s) + "\n").utf8))
                FileHandle.standardError.write(Data((Self.describe(SuperMax(hosts: monitor.hosts)) + "\n").utf8))
            }
        }
        monitor.stop(detail: true)
    }

    /// `CROSSAGENT_ACTIVITY_DUMP=1 swift test --filter ActivityTests/testLiveToggle`: pauses and
    /// resumes the real monitor (Mac plus ssh) 20 times, then checks CPU and leftover processes.
    @MainActor
    func testLiveToggle() async throws {
        guard ProcessInfo.processInfo.environment["CROSSAGENT_ACTIVITY_DUMP"] != nil else {
            throw XCTSkip("set CROSSAGENT_ACTIVITY_DUMP to run")
        }
        let monitor = ActivityMonitor.shared
        let hosts = HostStore.load()
        for i in 0..<20 {
            monitor.start(hosts: hosts, detail: i % 2 == 0)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            monitor.stop(detail: i % 2 == 0)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let before = Self.cpuSeconds()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let used = Self.cpuSeconds() - before
        let left = Self.processes(matching: "python3 -I -u -c", ownChildren: true)
        FileHandle.standardError.write(Data("toggle: \(String(format: "%.3f", used)) s CPU over 3 s while stopped; ssh left: \(left.isEmpty ? "none" : left)\n".utf8))
        XCTAssertLessThan(used, 0.2)
        XCTAssertEqual(left, "")
        for h in monitor.hosts { FileHandle.standardError.write(Data("\(h.name): \(h.cpu.values.count) cpu points\n".utf8)) }

        // Quit path: running, then shutdown must leave nothing behind.
        monitor.start(hosts: hosts)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertNotEqual(Self.processes(matching: "python3 -I -u -c", ownChildren: true), "", "sampler should be running")
        monitor.shutdown()
        XCTAssertEqual(Self.processes(matching: "python3 -I -u -c", ownChildren: true), "", "shutdown returns after ssh is gone")
    }

    static func describe(_ m: SuperMax) -> String {
        var parts = ["  super-max \(m.online)/\(m.machines.count) online"]
        parts.append(SuperMaxFormat.coresThreads(m.cores, m.threads))
        parts.append("cpu " + (m.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "--"))
        parts.append(String(format: "mem %.2f/%.2f GiB", Double(m.memUsed) / 1_073_741_824, Double(m.memTotal) / 1_073_741_824))
        parts.append("vram " + (m.vramUsed.map { String($0 / 1_048_576) } ?? "--") + "/\(m.vramTotal / 1_048_576) MiB, unified \(m.unifiedTotal / 1_048_576) MiB, \(m.gpuCount) gpus")
        parts.append("disk \(m.diskFree)/\(m.diskTotal) B free")
        parts.append("peak " + (m.peak.map { "\(String(format: "%.1f", $0.celsius)) \($0.machine) \($0.temp.label)" } ?? "--"))
        for x in m.machines {
            let gpus = x.gpus.map { g in "\(g.name)\(g.cores.map { " \($0)-core" } ?? "") util \(g.util.map { String(format: "%.0f%%", $0 * 100) } ?? "--") mem \(g.memUsed.map { String($0 / 1_048_576) } ?? "--")/\(g.memTotal.map { String($0 / 1_048_576) } ?? "--") MiB" }
            parts.append("\(x.name): \(x.specs.map { "\($0.cpuModel) \($0.cores)c/\($0.threads)t \($0.memInstalled) B" } ?? "no specs"); \(gpus.joined(separator: ", "))")
        }
        return parts.joined(separator: " | ")
    }

    static func describe(_ h: HostActivity, _ s: ActivitySample) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.S"
        var parts = ["[\(f.string(from: s.time))] \(h.name)"]
        parts.append("cpu " + (s.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "--"))
        if !s.clusters.isEmpty { parts.append(s.clusters.map { "\($0.name) \(String(format: "%.1f%%", $0.usage * 100))" }.joined(separator: " ")) }
        parts.append("cores [" + s.cores.map { String(format: "%.0f", $0 * 100) }.joined(separator: " ") + "]")
        parts.append(String(format: "mem %.2f/%.2f GiB", Double(s.memUsed) / 1_073_741_824, Double(s.memTotal) / 1_073_741_824))
        parts.append("pressure \(s.pressure?.label ?? "-") (\(s.pressureDetail ?? "-"))")
        parts.append(String(format: "swap %.0f/%.0f MiB", Double(s.swapUsed) / 1_048_576, Double(s.swapTotal) / 1_048_576))
        parts.append(s.temps.map { "\($0.label) \(String(format: "%.1f", $0.celsius))" + ($0.detail.map { " (\($0))" } ?? "") }.joined(separator: ", "))
        if let g = s.gpu { parts.append(String(format: "gpu %.0f%%", g * 100)) }
        if !h.sessions.isEmpty { parts.append("top " + h.sessions.map { "\($0.name) \(String(format: "%.1f%%", $0.cpu)) \(ActivityFormat.bytes($0.rssBytes))\($0.claude ? " claude" : "")" }.joined(separator: "; ")) }
        return parts.joined(separator: " | ")
    }
}
