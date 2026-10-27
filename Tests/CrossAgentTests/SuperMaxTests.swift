import XCTest
@testable import CrossAgent

final class SuperMaxTests: XCTestCase {
    static let gib: UInt64 = 1_073_741_824

    // MARK: Parsers, on output captured from the real machines

    func testLscpu() throws {
        let text = """
        CPU(s):                                  16
        Model name:                              AMD Ryzen 8-Core Processor
        Thread(s) per core:                      2
        Core(s) per socket:                      8
        Socket(s):                               1
        """
        let c = try XCTUnwrap(SpecParsers.lscpu(text))
        XCTAssertEqual(c.model, "AMD Ryzen 8-Core Processor")
        XCTAssertEqual(c.cores, 8)
        XCTAssertEqual(c.threads, 16)
    }

    func testLscpuTwoSocketsAndMissingCoreLine() throws {
        let two = try XCTUnwrap(SpecParsers.lscpu("CPU(s): 64\nCore(s) per socket: 16\nSocket(s): 2\nModel name: Xeon"))
        XCTAssertEqual(two.cores, 32)
        let noCores = try XCTUnwrap(SpecParsers.lscpu("CPU(s): 8\nThread(s) per core: 2"))
        XCTAssertEqual(noCores.cores, 4)
        XCTAssertNil(SpecParsers.lscpu("lscpu: command not found"))
    }

    func testCpuinfoCountsDistinctCores() throws {
        // Two cores with two threads each.
        let text = (0..<4).map { i in
            "processor\t: \(i)\nmodel name\t: AMD Ryzen 8-Core Processor\nphysical id\t: 0\ncore id\t\t: \(i / 2)\n"
        }.joined(separator: "\n")
        let c = try XCTUnwrap(SpecParsers.cpuinfo(text))
        XCTAssertEqual(c.threads, 4)
        XCTAssertEqual(c.cores, 2)
        XCTAssertEqual(c.model, "AMD Ryzen 8-Core Processor")
        // A Raspberry Pi style cpuinfo has no core ids: one core per processor.
        XCTAssertEqual(SpecParsers.cpuinfo("processor : 0\nprocessor : 1\n")?.cores, 2)
    }

    func testNvidiaSMI() throws {
        let g = try XCTUnwrap(SpecParsers.nvidiaSMI("0, NVIDIA GeForce GPU, 8188, 1146, 16, 43"))
        XCTAssertEqual(g.name, "NVIDIA GeForce GPU")
        XCTAssertEqual(g.memTotal, 8188 * 1_048_576)
        XCTAssertEqual(g.memUsed, 1146 * 1_048_576)
        XCTAssertEqual(g.util!, 0.16, accuracy: 1e-9)
        XCTAssertEqual(g.celsius, 43)
        // Without the index, and with fields the card doesn't support.
        let na = try XCTUnwrap(SpecParsers.nvidiaSMI("Tesla K80, 11441, 0, [N/A], [N/A]"))
        XCTAssertEqual(na.name, "Tesla K80")
        XCTAssertNil(na.util)
        XCTAssertNil(na.celsius)
        XCTAssertNil(SpecParsers.nvidiaSMI("NVIDIA-SMI has failed"))
    }

    func testSystemProfiler() {
        let json = #"{"SPDisplaysDataType":[{"_name":"Apple Silicon","spdisplays_mtlgpufamilysupport":"spdisplays_metal4","sppci_cores":"10","sppci_model":"Apple Silicon","sppci_device_type":"spdisplays_gpu"}]}"#
        XCTAssertEqual(SpecParsers.systemProfilerJSON(Data(json.utf8)), [GPUSpec(name: "Apple Silicon", cores: 10)])
        let text = """
        Graphics/Displays:

            Apple Silicon:

              Chipset Model: Apple Silicon
              Type: GPU
              Bus: Built-In
              Total Number of Cores: 10
              Vendor: Apple (0x106b)
        """
        XCTAssertEqual(SpecParsers.systemProfilerText(text), [GPUSpec(name: "Apple Silicon", cores: 10)])
    }

    func testInstalledMemoryFromBlocks() {
        let usable: UInt64 = 31_736_492 * 1024
        // The PC: 256 blocks of 128 MiB.
        XCTAssertEqual(SpecParsers.installedMemory(blockSizeHex: "8000000", blocks: 256, usable: usable), 32 * Self.gib)
        XCTAssertEqual(SpecParsers.installedMemory(blockSizeHex: nil, blocks: 0, usable: usable), usable)
        XCTAssertEqual(SpecParsers.installedMemory(blockSizeHex: "8000000", blocks: 1024, usable: usable), usable,
                       "four times the usable total is not believable")
    }

    func testSamplerLineCarriesSpecsGPUAndDisk() throws {
        let line = #"{"t":1,"cpu":[["cpu",1,0,1,10,0,0,0,0]],"mem":{"MemTotal":32000000,"MemAvailable":27250000,"SwapTotal":8388604,"SwapFree":8388604},"psi":0.0,"hw":[["k10temp","Tctl",39750]],"df":[700000000000,220000000000],"nv":["0, NVIDIA GeForce GPU, 8188, 1146, 16, 43"],"spec":{"lscpu":"CPU(s): 16\nModel name: AMD Ryzen 8-Core Processor\nThread(s) per core: 2\nCore(s) per socket: 8\nSocket(s): 1","mblk":["8000000",256]}}"#
        let raw = try XCTUnwrap(LinuxSampler.parse(Data(line.utf8)))
        XCTAssertEqual(raw.gpuTemp, 43)
        XCTAssertEqual(raw.gpuUtil, 16)
        var acc = LinuxSampler.Accumulator()
        let s = acc.sample(raw)
        XCTAssertEqual(s.diskTotal, 700_000_000_000)
        XCTAssertEqual(s.diskFree, 220_000_000_000)
        XCTAssertEqual(s.gpu!, 0.16, accuracy: 1e-9)
        XCTAssertEqual(s.temps.first { $0.kind == .gpu }?.celsius, 43)
        let specs = try XCTUnwrap(s.specs)
        XCTAssertEqual(specs.cores, 8)
        XCTAssertEqual(specs.threads, 16)
        XCTAssertEqual(specs.memInstalled, 32 * Self.gib)
        XCTAssertEqual(specs.gpus, [GPUSpec(name: "NVIDIA GeForce GPU", memory: 8188 * 1_048_576)])

        // Later lines have no spec, the accumulator keeps it.
        let next = try XCTUnwrap(LinuxSampler.parse(Data(#"{"t":2,"cpu":[["cpu",2,0,1,11,0,0,0,0]],"mem":{"MemTotal":32000000}}"#.utf8)))
        XCTAssertEqual(acc.sample(next).specs, specs)
    }

    // MARK: Combining

    static let macSpecs = MachineSpecs(cpuModel: "Apple Silicon", cores: 10, threads: 10, memInstalled: 32 * gib,
                                       gpus: [GPUSpec(name: "Apple Silicon", cores: 10, memory: 32 * gib, unified: true)])
    static let pcSpecs = MachineSpecs(cpuModel: "AMD Ryzen 8-Core Processor", cores: 8, threads: 16,
                                      memInstalled: 32 * gib, gpus: [GPUSpec(name: "NVIDIA GeForce GPU", memory: 8 * gib)])

    func host(_ id: String, _ specs: MachineSpecs, cpu: Double, memUsed: UInt64, memTotal: UInt64,
              gpu: GPUReading, disk: (UInt64, UInt64), temps: [TempGroup]) -> HostActivity {
        var h = HostActivity(hostId: id, name: id == "mac" ? "Mac" : "PC", accent: "#6ea8fe")
        var s = ActivitySample(cpu: cpu, memUsed: memUsed, memTotal: memTotal, temps: temps, gpu: gpu.util)
        s.gpus = [gpu]
        s.diskFree = disk.0
        s.diskTotal = disk.1
        s.specs = specs
        h.record(s)
        return h
    }

    var mac: HostActivity {
        host("mac", Self.macSpecs, cpu: 0.10, memUsed: 14 * Self.gib, memTotal: 32 * Self.gib,
             gpu: GPUReading(name: "Apple Silicon", util: 0.05, memUsed: Self.gib, memTotal: 32 * Self.gib),
             disk: (685_000_000_000, 1_000_000_000_000),
             temps: [TempGroup(kind: .cpu, label: "SoC", celsius: 48), TempGroup(kind: .battery, label: "Battery", celsius: 90)])
    }

    var pc: HostActivity {
        host("pc", Self.pcSpecs, cpu: 0.40, memUsed: 4 * Self.gib, memTotal: 31_736_492 * 1024,
             gpu: GPUReading(name: "NVIDIA GeForce GPU", util: 0.16, memUsed: Self.gib, memTotal: 8 * Self.gib, celsius: 43),
             disk: (220_000_000_000, 700_000_000_000),
             temps: [TempGroup(kind: .cpu, label: "CPU", celsius: 61.5), TempGroup(kind: .gpu, label: "GPU", celsius: 43)])
    }

    func testTotals() {
        let m = SuperMax(hosts: [mac, pc])
        XCTAssertEqual(m.online, 2)
        XCTAssertEqual(m.cores, 18)
        XCTAssertEqual(m.threads, 26)
        XCTAssertEqual(m.memUsed, 18 * Self.gib)
        XCTAssertEqual(m.memTotal, 64 * Self.gib, "installed RAM, not the smaller usable figure")
        XCTAssertEqual(m.diskFree, 685_000_000_000 + 220_000_000_000)
        XCTAssertEqual(m.diskTotal, 1_000_000_000_000 + 700_000_000_000)
        XCTAssertEqual(SuperMaxFormat.coresThreads(m.cores, m.threads, compact: true), "18c/26t")
        XCTAssertEqual(SuperMaxFormat.memPair(m.memUsed, m.memTotal, compact: true), "18/64 GB")
        XCTAssertEqual(SuperMaxFormat.storage(m.diskTotal), "1.70 TB")
    }

    func testCPULoadIsWeightedByThreads() {
        let m = SuperMax(hosts: [mac, pc])
        // (0.10 * 10 + 0.40 * 16) / 26
        XCTAssertEqual(m.cpu!, 7.4 / 26, accuracy: 1e-9)
        XCTAssertEqual(SuperMax.weightedLoad([(nil, 10), (0.5, 16)])!, 0.5, accuracy: 1e-9, "no reading yet doesn't count as 0")
        XCTAssertNil(SuperMax.weightedLoad([(nil, 10)]))
    }

    func testCPULoadIsLightlySmoothed() {
        var h = mac
        for v in [0.2, 0.3] {
            var s = h.latest!
            s.cpu = v
            h.record(s)
        }
        // Mean of the last three: 0.1, 0.2, 0.3.
        XCTAssertEqual(SuperMax(hosts: [h]).cpu!, 0.2, accuracy: 1e-9)
    }

    func testGPUCombine() {
        let m = SuperMax(hosts: [mac, pc])
        XCTAssertEqual(m.gpuCount, 2)
        XCTAssertEqual(m.vramTotal, 8 * Self.gib, "only discrete VRAM adds up")
        XCTAssertEqual(m.vramUsed, Self.gib)
        XCTAssertEqual(m.unifiedTotal, 32 * Self.gib)
        let macGPU = m.machines[0].gpus[0]
        XCTAssertTrue(macGPU.unified)
        XCTAssertEqual(macGPU.cores, 10)
        XCTAssertEqual(macGPU.util!, 0.05, accuracy: 1e-9)
        XCTAssertFalse(m.machines[1].gpus[0].unified)
    }

    func testPeakTempPicksHottestAndSkipsBattery() throws {
        let p = try XCTUnwrap(SuperMax(hosts: [mac, pc]).peak)
        XCTAssertEqual(p.celsius, 61.5)
        XCTAssertEqual(p.machine, "PC")
        XCTAssertEqual(p.temp.label, "CPU")
        XCTAssertNil(SuperMax.peak([("Mac", nil)]))
    }

    func testOfflineMachineDropsOutOfTotalsButKeepsSpecs() {
        var p = pc
        p.status = .unavailable("can't reach the host")
        let m = SuperMax(hosts: [mac, p])
        XCTAssertEqual(m.online, 1)
        XCTAssertEqual(m.threads, 10)
        XCTAssertEqual(m.memTotal, 32 * Self.gib)
        XCTAssertEqual(m.vramTotal, 0)
        XCTAssertEqual(m.cpu!, 0.10, accuracy: 1e-9)
        let off = m.machines[1]
        XCTAssertFalse(off.online)
        XCTAssertEqual(off.note, "can't reach the host")
        XCTAssertEqual(off.specs, Self.pcSpecs)
        XCTAssertNil(off.cpu)
        XCTAssertNil(off.gpus[0].util)
    }

    func testFormats() {
        XCTAssertEqual(SuperMaxFormat.cpuName("AMD Ryzen 8-Core Processor"), "Ryzen")
        XCTAssertEqual(SuperMaxFormat.cpuName("Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz"), "Core i7-9700K")
        XCTAssertEqual(SuperMaxFormat.cpuName("Apple Silicon"), "Apple Silicon")
        XCTAssertEqual(SuperMaxFormat.gpuName("NVIDIA GeForce GPU"), "GeForce GPU")
        XCTAssertEqual(SuperMaxFormat.gibNumber(7 * Self.gib / 2), "3.5")
        XCTAssertEqual(SuperMaxFormat.gibNumber(Self.gib * 31 + Self.gib / 3), "31")
        XCTAssertEqual(SuperMaxFormat.storage(905_000_000_000), "905 GB")
        XCTAssertEqual(SuperMaxFormat.percent(0.2349), "23%")
        XCTAssertEqual(SuperMaxFormat.percent(nil), "--")
    }
}
