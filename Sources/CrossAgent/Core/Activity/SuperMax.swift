import Foundation

/// Every machine added up as one computer. Pure: built from the monitor's hosts on each
/// update, so the math is testable and nothing new polls.
struct SuperMax: Equatable {
    struct GPU: Equatable {
        var name: String
        var cores: Int?
        var unified: Bool
        var memUsed: UInt64?
        var memTotal: UInt64?
        /// 0...1, lightly smoothed.
        var util: Double?
        var celsius: Double?
    }

    struct Machine: Equatable, Identifiable {
        var id: String
        var name: String
        var accent: String
        var online: Bool
        /// Why it's offline, when it is.
        var note: String?
        var specs: MachineSpecs?
        /// 0...1 across its threads, lightly smoothed.
        var cpu: Double?
        var memUsed: UInt64?
        var memTotal: UInt64
        var gpus: [GPU]
        var diskFree: UInt64?
        var diskTotal: UInt64?
        var peak: TempGroup?

        var threads: Int { specs?.threads ?? 0 }
    }

    struct Peak: Equatable {
        var celsius: Double
        var machine: String
        var temp: TempGroup
    }

    var machines: [Machine] = []
    // Totals over the machines that are online.
    var online = 0
    var cores = 0
    var threads = 0
    var cpu: Double?
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var gpuCount = 0
    var vramUsed: UInt64?
    var vramTotal: UInt64 = 0
    var unifiedTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0
    var peak: Peak?

    /// Samples averaged into the big numbers. Three is 4.5 s: steady, still live.
    static let smoothing = 3

    init(machines: [Machine]) {
        self.machines = machines
        let up = machines.filter(\.online)
        online = up.count
        cores = up.reduce(0) { $0 + ($1.specs?.cores ?? 0) }
        threads = up.reduce(0) { $0 + $1.threads }
        cpu = Self.weightedLoad(up.map { ($0.cpu, $0.threads) })
        memUsed = up.reduce(0) { $0 + ($1.memUsed ?? 0) }
        memTotal = up.reduce(0) { $0 + $1.memTotal }
        let gpus = up.flatMap(\.gpus)
        gpuCount = gpus.count
        let discrete = gpus.filter { !$0.unified }
        vramTotal = discrete.reduce(0) { $0 + ($1.memTotal ?? 0) }
        let used = discrete.compactMap(\.memUsed)
        vramUsed = used.isEmpty ? nil : used.reduce(0, +)
        unifiedTotal = gpus.filter(\.unified).reduce(0) { $0 + ($1.memTotal ?? 0) }
        diskFree = up.reduce(0) { $0 + ($1.diskFree ?? 0) }
        diskTotal = up.reduce(0) { $0 + ($1.diskTotal ?? 0) }
        peak = Self.peak(up.map { ($0.name, $0.peak) })
    }

    init(hosts: [HostActivity]) {
        self.init(machines: hosts.map(Self.machine))
    }

    /// Load weighted by thread count: busy logical CPUs over all logical CPUs. Machines
    /// without a reading yet don't count, so one slow host doesn't drag the total to 0.
    static func weightedLoad(_ parts: [(load: Double?, threads: Int)]) -> Double? {
        let known = parts.compactMap { p in p.load.map { ($0, Double(max(p.threads, 1))) } }
        let weight = known.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return nil }
        return known.reduce(0) { $0 + $1.0 * $1.1 } / weight
    }

    /// Hottest CPU, GPU or SSD reading across machines. Battery is left out on purpose:
    /// it runs cool and isn't what "how hot is it working" means.
    static func peak(_ parts: [(machine: String, peak: TempGroup?)]) -> Peak? {
        parts.compactMap { p in p.peak.map { Peak(celsius: $0.celsius, machine: p.machine, temp: $0) } }
            .max { $0.celsius < $1.celsius }
    }

    static func hottest(_ temps: [TempGroup]) -> TempGroup? {
        temps.filter { $0.kind != .battery }.max { $0.celsius < $1.celsius }
    }

    static func machine(_ h: HostActivity) -> Machine {
        let s = h.latest
        let online = h.status == .live && s != nil
        var note: String?
        if case .unavailable(let why) = h.status { note = why } else if !online { note = "connecting" }
        let specs = h.specs
        // Live GPUs carry names from nvidia-smi or IOKit. Specs fill in cores and unified.
        let live = s?.gpus ?? []
        let gpuSpecs = specs?.gpus ?? []
        let count = max(live.count, gpuSpecs.count)
        let smoothedUtil = h.gpu.recentMean(smoothing)
        let gpus: [GPU] = (0..<count).map { i in
            let r = i < live.count ? live[i] : nil
            let sp = i < gpuSpecs.count ? gpuSpecs[i] : nil
            // The host series is the mean over GPUs, so only smooth when there is one.
            let util = online ? (count == 1 && r?.util != nil ? smoothedUtil : r?.util) : nil
            return GPU(name: r?.name ?? sp?.name ?? "GPU", cores: sp?.cores, unified: sp?.unified ?? false,
                       memUsed: online ? r?.memUsed : nil, memTotal: r?.memTotal ?? sp?.memory,
                       util: util, celsius: online ? r?.celsius : nil)
        }
        let memTotal = max(specs?.memInstalled ?? 0, s?.memTotal ?? 0)
        return Machine(id: h.hostId, name: h.name, accent: h.accent, online: online, note: online ? nil : note,
                       specs: specs, cpu: online && s?.cpu != nil ? h.cpu.recentMean(smoothing) : nil,
                       memUsed: online ? s?.memUsed : nil, memTotal: memTotal, gpus: gpus,
                       diskFree: online ? s?.diskFree : nil, diskTotal: s?.diskTotal,
                       peak: online ? hottest(s?.temps ?? []) : nil)
    }
}

/// Number formats for the Super-Max card. Rounded so the big numbers hold still.
enum SuperMaxFormat {
    static let gib: Double = 1_073_741_824

    /// "16c / 24t", or "16c/24t" for tight spots.
    static func coresThreads(_ cores: Int, _ threads: Int, compact: Bool = false) -> String {
        compact ? "\(cores)c/\(threads)t" : "\(cores)c / \(threads)t"
    }

    /// GiB with no decimals from 10 up, one below. "31", "7.4".
    static func gibNumber(_ b: UInt64) -> String {
        let g = Double(b) / gib
        return g >= 10 || g == g.rounded() ? String(format: "%.0f", g) : String(format: "%.1f", g)
    }

    /// "30 / 64 GB". RAM in binary units, like Activity Monitor and `free -h`.
    static func memPair(_ used: UInt64, _ total: UInt64, compact: Bool = false) -> String {
        "\(gibNumber(used))\(compact ? "/" : " / ")\(gibNumber(total)) GB"
    }

    /// Storage in decimal units, like Finder and the label on the drive. "512 GB", "1.50 TB".
    static func storage(_ b: UInt64) -> String {
        let gb = Double(b) / 1e9
        return gb >= 1000 ? String(format: "%.2f TB", gb / 1000) : String(format: "%.0f GB", gb)
    }

    /// "AMD Ryzen 8-Core Processor" reads as "Ryzen".
    static func cpuName(_ model: String) -> String {
        var s = model.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
        s = s.replacingOccurrences(of: #"\s*\d+-Core Processor"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*(CPU )?@.*$"#, with: "", options: .regularExpression)
        for prefix in ["AMD ", "Intel "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        s = s.replacingOccurrences(of: " Processor", with: "")
        return s.split(separator: " ").joined(separator: " ")
    }

    /// "NVIDIA GeForce GPU" reads as "GeForce GPU".
    static func gpuName(_ name: String) -> String {
        name.hasPrefix("NVIDIA ") ? String(name.dropFirst(7)) : name
    }

    static func percent(_ f: Double?) -> String { f.map { String(format: "%.0f%%", ($0 * 100).rounded()) } ?? "--" }
}
