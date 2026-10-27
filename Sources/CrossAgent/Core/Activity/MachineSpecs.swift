import Foundation
import IOKit
import os

/// What a machine is, as opposed to what it is doing. Read once per sampler start.
struct MachineSpecs: Equatable, Codable {
    var cpuModel: String
    /// Physical cores and hardware threads (logical CPUs).
    var cores: Int
    var threads: Int
    /// Installed RAM when the host can tell, else the usable total.
    var memInstalled: UInt64
    var gpus: [GPUSpec] = []
}

struct GPUSpec: Equatable, Codable {
    var name: String
    /// GPU cores, where the vendor reports them (Apple does, nvidia-smi doesn't).
    var cores: Int?
    /// Dedicated VRAM, or the shared pool for unified memory.
    var memory: UInt64?
    var unified = false
}

/// One live GPU reading. Nil fields were not readable.
struct GPUReading: Equatable {
    var name: String
    /// 0...1.
    var util: Double?
    var memUsed: UInt64?
    var memTotal: UInt64?
    var celsius: Double?
}

/// Parsers for the tools that describe a machine. Pure, so they're tested on captured output.
enum SpecParsers {
    /// `lscpu` (LC_ALL=C), only the lines we need are required.
    static func lscpu(_ text: String) -> (model: String, cores: Int, threads: Int)? {
        var f: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            f[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let threads = f["CPU(s)"].flatMap({ Int($0) }), threads > 0 else { return nil }
        let perSocket = f["Core(s) per socket"].flatMap { Int($0) }
        let sockets = f["Socket(s)"].flatMap { Int($0) } ?? 1
        let perCore = f["Thread(s) per core"].flatMap { Int($0) }
        let cores = perSocket.map { $0 * sockets } ?? perCore.map { max(1, threads / $0) } ?? threads
        return (f["Model name"] ?? "CPU", cores, threads)
    }

    /// /proc/cpuinfo fallback: physical cores are the distinct (physical id, core id) pairs.
    static func cpuinfo(_ text: String) -> (model: String, cores: Int, threads: Int)? {
        var model: String?, threads = 0, phys = "0"
        var pairs = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces), v = parts[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "processor": threads += 1
            case "model name": if model == nil { model = v }
            case "physical id": phys = v
            case "core id": pairs.insert("\(phys)/\(v)")
            default: break
            }
        }
        guard threads > 0 else { return nil }
        return (model ?? "CPU", pairs.isEmpty ? threads : pairs.count, threads)
    }

    /// One line of `nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu,temperature.gpu
    /// --format=csv,noheader,nounits`. Memory is MiB. "[N/A]" fields become nil. The index is optional.
    static func nvidiaSMI(_ line: String) -> GPUReading? {
        var f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if f.count >= 6, Int(f[0]) != nil { f.removeFirst() }
        guard f.count >= 5 else { return nil }
        let nums = f.suffix(4).map { Double($0) }
        let name = f.dropLast(4).joined(separator: ",")
        guard !name.isEmpty else { return nil }
        let mib = { (v: Double?) in v.map { UInt64($0 * 1_048_576) } }
        return GPUReading(name: name, util: nums[2].map { $0 / 100 }, memUsed: mib(nums[1]), memTotal: mib(nums[0]),
                          celsius: nums[3])
    }

    /// GPU name and core count from `system_profiler -json SPDisplaysDataType`.
    static func systemProfilerJSON(_ data: Data) -> [GPUSpec] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["SPDisplaysDataType"] as? [[String: Any]] else { return [] }
        return items.compactMap { i in
            guard let name = (i["sppci_model"] as? String) ?? (i["_name"] as? String) else { return nil }
            let cores = (i["sppci_cores"] as? String).flatMap { Int($0) } ?? (i["sppci_cores"] as? Int)
            return GPUSpec(name: name, cores: cores)
        }
    }

    /// Same from the plain text form ("Chipset Model: Apple Silicon", "Total Number of Cores: 10").
    static func systemProfilerText(_ text: String) -> [GPUSpec] {
        var out: [GPUSpec] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Chipset Model:") {
                out.append(GPUSpec(name: t.dropFirst("Chipset Model:".count).trimmingCharacters(in: .whitespaces)))
            } else if t.hasPrefix("Total Number of Cores:"), !out.isEmpty {
                out[out.count - 1].cores = Int(t.dropFirst("Total Number of Cores:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    /// Installed RAM from memory hotplug blocks (hex block size times the block count). Only
    /// trusted when it lands between the usable total and a quarter above it.
    static func installedMemory(blockSizeHex: String?, blocks: Int, usable: UInt64) -> UInt64 {
        guard let hex = blockSizeHex?.trimmingCharacters(in: .whitespacesAndNewlines),
              let size = UInt64(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16), blocks > 0 else { return usable }
        let total = size * UInt64(blocks)
        return total >= usable && Double(total) <= Double(usable) * 1.25 ? total : usable
    }
}

/// This Mac's specs: sysctl plus the GPU from the IORegistry. system_profiler only runs
/// (once, in the background) if the registry has no core count.
enum MacSpecs {
    private static let profiled = OSAllocatedUnfairLock<[GPUSpec]?>(initialState: nil)
    private static let profiling = OSAllocatedUnfairLock(initialState: false)

    static func read() -> MachineSpecs {
        let mem = MacSampler.sysctlUInt64("hw.memsize") ?? 0
        var gpus = acceleratorSpecs().map { g in
            var g = g
            g.memory = mem
            g.unified = true
            return g
        }
        if gpus.isEmpty || gpus.contains(where: { $0.cores == nil }) {
            if let p = profiled.withLock({ $0 }) {
                gpus = p.map { GPUSpec(name: $0.name, cores: $0.cores, memory: mem, unified: true) }
            } else {
                profileOnce()
            }
        }
        return MachineSpecs(cpuModel: MacSampler.sysctlString("machdep.cpu.brand_string") ?? "Mac",
                            cores: MacSampler.sysctlInt("hw.physicalcpu") ?? 0,
                            threads: MacSampler.sysctlInt("hw.logicalcpu") ?? 0,
                            memInstalled: mem, gpus: gpus)
    }

    private static func acceleratorSpecs() -> [GPUSpec] {
        var out: [GPUSpec] = []
        forEachAccelerator { entry in
            let model = IORegistryEntryCreateCFProperty(entry, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            let name = (model as? String) ?? (model as? Data).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let cores = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            if let name { out.append(GPUSpec(name: name, cores: cores?.intValue)) }
        }
        return out
    }

    static func forEachAccelerator(_ body: (io_registry_entry_t) -> Void) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while case let entry = IOIteratorNext(iter), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    /// GPU busy share and GPU memory in use, from the accelerator's PerformanceStatistics.
    /// No root and no process spawn.
    static func gpuReading(name: String) -> GPUReading? {
        var reading: GPUReading?
        forEachAccelerator { entry in
            guard reading == nil,
                  let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { return }
            reading = GPUReading(name: name,
                                 util: (stats["Device Utilization %"] as? NSNumber).map { min(1, $0.doubleValue / 100) },
                                 memUsed: (stats["In use system memory"] as? NSNumber)?.uint64Value)
        }
        return reading
    }

    private static func profileOnce() {
        guard profiling.withLock({ busy in defer { busy = true }; return !busy }) else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["-json", "SPDisplaysDataType"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            profiled.withLock { $0 = SpecParsers.systemProfilerJSON(data) }
        }
    }

    /// Free space as Finder counts it (purgeable included) and the volume size, for `/`.
    static func disk() -> (free: UInt64, total: UInt64)? {
        var url = URL(fileURLWithPath: "/")
        url.removeAllCachedResourceValues()
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
        return (UInt64(max(0, free)), UInt64(total))
    }
}
