import Foundation

/// Reads Apple Silicon temperature sensors through the private IOHIDEventSystemClient
/// API, which needs no root. Symbols are looked up at runtime so a missing one just
/// means no temperatures instead of a crash or a link error.
final class MacTemperatures {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private static let temperatureEvent: Int64 = 15 // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)

    private let copyEvent: CopyEventFn
    private let floatValue: FloatValueFn
    private let client: AnyObject
    /// Sensors we care about with their product names, found once.
    private let sensors: [(name: String, service: AnyObject)]

    init?() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let floatValue = sym("IOHIDEventGetFloatValue", FloatValueFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Vendor page 0xff00, usage 5: the temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        self.client = client
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        sensors = services.compactMap { s in
            guard let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  MacTemperatures.wanted(name) else { return nil }
            return (name, s)
        }
    }

    var isEmpty: Bool { sensors.isEmpty }

    static func wanted(_ name: String) -> Bool {
        name.contains("tdie") || name.contains("ACC") || name.contains("SOC") || name.contains("battery")
            || name.hasPrefix("NAND") || name.contains("GPU")
    }

    /// Current readings, name and degrees C.
    func read() -> [(name: String, celsius: Double)] {
        sensors.compactMap { s in
            guard let e = copyEvent(s.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return (s.name, floatValue(e, Self.temperatureField))
        }
    }

    /// Groups raw readings into tiles. On M5 the die sensors are "PMU tdieN" and "PMU2 tdieN"
    /// (no pACC/eACC names any more); older chips name clusters "pACC MTR Temp Sensor" etc.
    /// CPU is the average of the die sensors with the hottest one as detail.
    static func group(_ readings: [(name: String, celsius: Double)]) -> [TempGroup] {
        let valid = readings.filter { $0.celsius > -20 && $0.celsius < 130 }
        var out: [TempGroup] = []
        var die = valid.filter { $0.name.contains("tdie") }
        if die.isEmpty { die = valid.filter { $0.name.contains("ACC") || $0.name.contains("SOC") } }
        if !die.isEmpty {
            let avg = die.map(\.celsius).reduce(0, +) / Double(die.count)
            let hot = die.map(\.celsius).max() ?? avg
            out.append(TempGroup(kind: .cpu, label: "SoC", celsius: avg, detail: "hottest \(ActivityFormat.degrees(hot))"))
        }
        let gpu = valid.filter { $0.name.contains("GPU") }
        if !gpu.isEmpty {
            out.append(TempGroup(kind: .gpu, label: "GPU", celsius: gpu.map(\.celsius).max() ?? 0, detail: nil))
        }
        let nand = valid.filter { $0.name.hasPrefix("NAND") }
        if !nand.isEmpty {
            out.append(TempGroup(kind: .storage, label: "SSD", celsius: nand.map(\.celsius).max() ?? 0, detail: nil))
        }
        let battery = valid.filter { $0.name.contains("battery") }
        if !battery.isEmpty {
            out.append(TempGroup(kind: .battery, label: "Battery",
                                 celsius: battery.map(\.celsius).reduce(0, +) / Double(battery.count), detail: nil))
        }
        return out
    }
}
