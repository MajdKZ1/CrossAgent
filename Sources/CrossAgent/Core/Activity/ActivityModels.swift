import Foundation

// Plain data and pure math for the activity monitor. Samplers fill these in,
// ActivityMonitor keeps the history, the views only read.

/// Busy and idle ticks of one CPU (or all of them). Usage is the busy share of a delta.
struct CPUTicks: Equatable {
    var busy: UInt64
    var idle: UInt64

    /// 0...1 over the time since `previous`. Nil when nothing passed or counters went backwards.
    func usage(since previous: CPUTicks) -> Double? {
        guard busy >= previous.busy, idle >= previous.idle else { return nil }
        let b = Double(busy - previous.busy), i = Double(idle - previous.idle)
        guard b + i > 0 else { return nil }
        return min(1, max(0, b / (b + i)))
    }
}

/// A group of cores, e.g. the Super and Efficiency clusters on Apple Silicon.
struct CoreCluster: Equatable {
    var name: String
    /// Indices into `ActivitySample.cores`.
    var cores: [Int]
    var usage: Double
}

enum PressureLevel: Int, Comparable {
    case normal, warning, critical

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .normal: "normal"
        case .warning: "elevated"
        case .critical: "critical"
        }
    }
}

enum TempKind: String, CaseIterable, Hashable {
    case cpu, gpu, storage, battery

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .storage: "SSD"
        case .battery: "Battery"
        }
    }

    /// Where the colour turns warning and danger, in degrees C.
    var thresholds: (Double, Double) {
        switch self {
        case .cpu, .gpu: (70, 85)
        case .storage: (55, 70)
        case .battery: (35, 45)
        }
    }
}

/// One temperature tile: a representative value plus an optional second detail.
struct TempGroup: Equatable, Hashable {
    var kind: TempKind
    var label: String
    var celsius: Double
    var detail: String?
}

/// Per tmux session load: the pane's whole process tree.
struct SessionLoad: Equatable, Identifiable {
    var name: String
    /// Percent of one core, like top (can go over 100).
    var cpu: Double
    var rssBytes: UInt64
    var claude: Bool

    var id: String { name }
}

/// One reading of a host. Nil fields were not available.
struct ActivitySample: Equatable {
    var time = Date()
    /// 0...1 across all cores.
    var cpu: Double?
    var cores: [Double] = []
    var clusters: [CoreCluster] = []
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var pressure: PressureLevel?
    /// Short human detail for the pressure, e.g. "73% free" or "stall 0.4%".
    var pressureDetail: String?
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var temps: [TempGroup] = []
    /// 0...1, when the host reports a GPU.
    var gpu: Double?
    /// Every GPU the host reports, with whatever it could read live.
    var gpus: [GPUReading] = []
    /// Main drive, bytes. Free is what the user can actually use.
    var diskFree: UInt64?
    var diskTotal: UInt64?
    /// Static specs, attached by the sampler once it knows them.
    var specs: MachineSpecs?

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
    var cpuTemp: TempGroup? { temps.first { $0.kind == .cpu } }
}

/// Fixed size history for sparklines. About 3 minutes at 1.5 s.
struct Series: Equatable {
    static let capacity = 120
    private(set) var values: [Double] = []
    /// Bumps on every append, so views can skip redrawing an unchanged series cheaply.
    private(set) var version = 0

    mutating func append(_ v: Double) {
        version &+= 1
        values.append(v)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    /// Mean of the last `n` values, a light smoothing for big numbers that shouldn't flicker.
    func recentMean(_ n: Int) -> Double? {
        let tail = values.suffix(max(1, n))
        return tail.isEmpty ? nil : tail.reduce(0, +) / Double(tail.count)
    }
}

/// Everything the views need for one host.
struct HostActivity: Equatable, Identifiable {
    enum Status: Equatable { case starting, live, unavailable(String) }

    var hostId: String
    var name: String
    var accent: String
    var status: Status = .starting
    var latest: ActivitySample?
    var cpu = Series()
    var mem = Series()
    var swap = Series()
    var gpu = Series()
    var temps: [TempKind: Series] = [:]
    var sessions: [SessionLoad] = []
    /// Kept after the host goes offline, so its half still says what it is.
    var specs: MachineSpecs?

    var id: String { hostId }

    mutating func record(_ s: ActivitySample) {
        latest = s
        status = .live
        if let sp = s.specs, sp != specs { specs = sp }
        if let c = s.cpu { cpu.append(c) }
        mem.append(s.memFraction)
        swap.append(Double(s.swapUsed))
        if let g = s.gpu { gpu.append(g) }
        for t in s.temps { temps[t.kind, default: Series()].append(t.celsius) }
    }
}

/// Load to colour step: 0 calm, 1 warning, 2 danger.
enum LoadLevel {
    static func of(_ value: Double, warn: Double, danger: Double) -> Int {
        value >= danger ? 2 : (value >= warn ? 1 : 0)
    }

    static func cpu(_ fraction: Double) -> Int { of(fraction, warn: 0.5, danger: 0.8) }
    static func mem(_ fraction: Double) -> Int { of(fraction, warn: 0.75, danger: 0.9) }
    static func temp(_ t: TempGroup) -> Int { of(t.celsius, warn: t.kind.thresholds.0, danger: t.kind.thresholds.1) }
}

enum ActivityFormat {
    /// "12.3 GB" style, binary units like Activity Monitor.
    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    static func gb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }
    static func percent(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }
    static func degrees(_ c: Double) -> String { String(format: "%.0f°", c) }
}
