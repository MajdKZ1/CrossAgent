#if DEBUG
import Foundation

/// Made up readings for a demo run, in place of MacSampler and RemoteSampler: generic
/// specs and smoothly drifting load with the odd burst, so sparklines look alive.
/// Nothing on either machine is read.
@MainActor
final class DemoSampler {
    private let local: Bool
    private let onSample: @MainActor (ActivitySample, [SessionLoad]?) -> Void
    private var timer: Timer?
    private var t = Double.random(in: 0..<100)
    private var burst = 0.0
    private var wantSessions = false

    init(local: Bool, onSample: @escaping @MainActor (ActivitySample, [SessionLoad]?) -> Void) {
        self.local = local
        self.onSample = onSample
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: MacSampler.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setWantsSessions(_ on: Bool) { wantSessions = on }

    private static let gb: UInt64 = 1 << 30

    var specs: MachineSpecs {
        local
            ? MachineSpecs(cpuModel: "Apple Silicon", cores: 12, threads: 12, memInstalled: 36 * Self.gb,
                           gpus: [GPUSpec(name: "Apple Silicon GPU", memory: 36 * Self.gb, unified: true)])
            : MachineSpecs(cpuModel: "AMD Ryzen 8-Core Processor", cores: 8, threads: 16, memInstalled: 64 * Self.gb,
                           gpus: [GPUSpec(name: "NVIDIA GeForce GPU", memory: 12 * Self.gb)])
    }

    /// 0...1, a slow wave plus a faster ripple, offset per machine.
    private func wave(_ base: Double, _ amp: Double, _ period: Double, phase: Double = 0) -> Double {
        base + amp * sin((t + phase) / period) + amp * 0.4 * sin((t + phase) / (period * 0.37))
    }

    private func tick() {
        t += 1
        if burst < 0.02, Int.random(in: 0..<14) == 0 { burst = Double.random(in: 0.25...0.5) }
        burst *= 0.82
        let threads = local ? 12 : 16
        let cpu = min(0.97, max(0.03, wave(local ? 0.22 : 0.3, 0.08, 7, phase: local ? 0 : 3) + burst
                                    + Double.random(in: -0.02...0.02)))
        let cores = (0..<threads).map { i -> Double in
            let tilt = local && i >= 8 ? 0.6 : 1.0
            return min(1, max(0, cpu * tilt + 0.12 * sin(t / 3 + Double(i)) + Double.random(in: -0.05...0.05)))
        }

        var s = ActivitySample()
        s.cpu = cpu
        s.cores = cores
        s.specs = specs
        let memTotal = (local ? 36 : 64) * Self.gb
        let memFraction = wave(local ? 0.62 : 0.31, 0.03, 23) + burst * 0.1
        s.memTotal = memTotal
        s.memUsed = UInt64(Double(memTotal) * min(0.95, memFraction))
        s.pressure = .normal
        let gpuUtil = min(1, max(0, wave(local ? 0.12 : 0.34, 0.08, 11, phase: 5) + burst * 0.8))
        if local {
            s.clusters = [
                CoreCluster(name: "Performance", cores: Array(0..<8), usage: cores[0..<8].reduce(0, +) / 8),
                CoreCluster(name: "Efficiency", cores: Array(8..<12), usage: cores[8..<12].reduce(0, +) / 4),
            ]
            s.pressureDetail = "\(Int((1 - memFraction) * 100))% free"
            s.swapUsed = 1 * Self.gb + Self.gb / 4
            s.swapTotal = 2 * Self.gb
            let soc = 46 + cpu * 30
            s.temps = [
                TempGroup(kind: .cpu, label: "SoC", celsius: soc, detail: "hottest \(ActivityFormat.degrees(soc + 6))"),
                TempGroup(kind: .gpu, label: "GPU", celsius: 41 + gpuUtil * 25, detail: nil),
                TempGroup(kind: .storage, label: "SSD", celsius: 37 + cpu * 4, detail: nil),
            ]
            s.gpus = [GPUReading(name: "Apple Silicon GPU", util: gpuUtil, memUsed: 3 * Self.gb + UInt64(gpuUtil * 2e9),
                                 memTotal: memTotal)]
            s.diskTotal = 1_000_000_000_000
            s.diskFree = 400_000_000_000
        } else {
            s.pressureDetail = String(format: "stall %.1f%%", burst * 2)
            s.swapTotal = 8 * Self.gb
            let gpuTemp = 44 + gpuUtil * 30
            s.temps = [
                TempGroup(kind: .cpu, label: "CPU", celsius: 50 + cpu * 32, detail: nil),
                TempGroup(kind: .gpu, label: "GPU", celsius: gpuTemp, detail: nil),
                TempGroup(kind: .storage, label: "SSD", celsius: 40 + cpu * 5, detail: nil),
            ]
            s.gpus = [GPUReading(name: "NVIDIA GeForce GPU", util: gpuUtil,
                                 memUsed: 2 * Self.gb + UInt64(gpuUtil * 6e9), memTotal: 12 * Self.gb, celsius: gpuTemp)]
            s.diskTotal = 2_000_000_000_000
            s.diskFree = 1_200_000_000_000
        }
        s.gpu = gpuUtil
        onSample(s, wantSessions ? sessions(cpu: cpu) : nil)
    }

    /// The scripted demo sessions (scripts/demo/sessions.sh) for this machine.
    private func sessions(cpu: Double) -> [SessionLoad] {
        let names: [(String, Double, UInt64, Bool)] = local
            ? [("ca-demo-mac-build", 2.4, 900, false), ("ca-demo-mac-1", 0.6, 420, true), ("ca-site-mac-3", 0.3, 310, false)]
            : [("ca-demo-pc-bench", 3.1, 1600, false), ("ca-demo-pc-tests", 1.2, 700, false), ("ca-api-pc-2", 0.2, 180, false)]
        return names.enumerated().map { i, n in
            let load = n.1 * 100 * cpu * (0.8 + 0.3 * sin(t / 4 + Double(i)))
            return SessionLoad(name: n.0, cpu: max(0.5, load), rssBytes: n.2 << 20, claude: n.3)
        }
    }
}
#endif
