import AppKit
import SwiftUI

/// Dev only: a window with the orchestrator canvas fed by DemoEvents through the
/// reducer, opened with CROSSAGENT_ORCH_DEMO=1.
///
/// - CROSSAGENT_ORCH_DEMO=idle: six nodes that settle and then sit still.
/// - CROSSAGENT_ORCH_DEMO_NODES=<n>: n nodes at once with data flowing all the time.
/// - CROSSAGENT_ORCH_DEMO_SNAPSHOT=<path>: writes a PNG of the window every 3 s.
///   A `%d` in the path is replaced by a counter. The window opens behind others.
/// - CROSSAGENT_ORCH_DEMO_POINTER=<path>: JSON array of pointer automation commands,
///   each with an optional "wait" in seconds before it. {"log":"label"} prints the
///   camera and node positions; {"snapshot":"path"} writes a PNG.
enum OrchestratorDemo {
    private static var window: NSWindow?
    private static var driver: DemoDriver?

    @MainActor static func openIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["CROSSAGENT_ORCH_DEMO"], mode != "0" else { return }
        let driver = DemoDriver()
        let root = DemoRoot(graph: driver.graph, hosts: HostStore.load())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Orchestrator demo"
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.window
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: root)
        w.center()
        let snapshot = env["CROSSAGENT_ORCH_DEMO_SNAPSHOT"]
        // Automated runs stay behind other windows.
        if snapshot != nil || env["CROSSAGENT_ORCH_DEMO_POINTER"] != nil { w.orderBack(nil) } else { w.makeKeyAndOrderFront(nil) }
        window = w
        self.driver = driver

        if let n = env["CROSSAGENT_ORCH_DEMO_NODES"].flatMap(Int.init), n > 0 {
            driver.startCrowd(n)
        } else if mode == "idle" {
            driver.startIdle()
        } else {
            driver.startScript()
        }
        if let snapshot { driver.startSnapshots(of: w, to: snapshot) }
        if let pointer = env["CROSSAGENT_ORCH_DEMO_POINTER"] { driver.runPointerScript(pointer, in: w) }
    }
}

private struct DemoRoot: View {
    @ObservedObject var graph: AgentGraph
    var hosts: [Host]
    @State private var positions: [String: CGPoint] = [:]

    var body: some View {
        OrchestratorView(graph: graph, hosts: hosts, positions: $positions, actions: OrchestratorActions(
            expand: { DemoDriver.log("expand \($0)") },
            relay: { DemoDriver.log("relay \($0) -> \($1)") },
            clearFinished: { graph.clearFinished() },
            answer: { id in
                DemoDriver.log("answer \(id)")
                graph.nodes[id]?.state = .working
                graph.nodes[id]?.activity = "Back at it"
            }))
            .frame(minWidth: 500, minHeight: 360)
            .onChange(of: positions) { DemoDriver.log("positions \(DemoDriver.describe(positions))") }
    }
}

/// Feeds the demo window: DemoEvents through the reducer, or a fixed scene for perf runs.
@MainActor
private final class DemoDriver {
    let graph = AgentGraph(orchestratorHost: "mac")
    private var timers: [Timer] = []
    private var snapshotCount = 0

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("orch demo: \(s)\n".utf8))
    }

    private func every(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    // MARK: - Graph edits

    private func add(_ id: String, _ kind: AgentKind, _ host: String, _ state: AgentState, _ activity: String,
                     name: String? = nil) {
        let now = Date()
        graph.nodes[id] = AgentNode(id: id, name: name ?? id, kind: kind, hostId: host, state: state,
                                    activity: activity, tmuxSession: kind == .worker ? "ca-demo-\(host)-\(id)" : nil,
                                    prompt: kind == .subagent ? "Look into \(id) and report back" : nil,
                                    startedAt: now, updatedAt: now, flow: .toNode, flowAt: now)
    }

    private func set(_ id: String, _ state: AgentState, _ activity: String? = nil) {
        guard graph.nodes[id] != nil else { return }
        graph.nodes[id]?.state = state
        if let activity { graph.nodes[id]?.activity = activity }
        graph.nodes[id]?.updatedAt = Date()
    }

    private func flow(_ id: String, _ dir: CableFlow) {
        guard graph.nodes[id] != nil else { return }
        graph.nodes[id]?.flow = dir
        graph.nodes[id]?.flowAt = Date()
    }

    private func reset() {
        let keep = graph.nodes[AgentGraph.orchestratorID]
        graph.nodes = keep.map { [AgentGraph.orchestratorID: $0] } ?? [:]
        graph.finished = []
    }

    // MARK: - Modes

    /// Plays DemoEvents through the real reducer, then starts over.
    func startScript() {
        var start = Date()
        var steps: [(delay: TimeInterval, event: AgentEvent)] = []
        var next = 0
        var end: TimeInterval = 0
        func load() {
            steps = DemoEvents.script(slug: "demo", start: start).enumerated()
                .sorted { ($0.element.delay, $0.offset) < ($1.element.delay, $1.offset) }.map(\.element)
            next = 0
            end = (steps.last?.delay ?? 0) + 10
        }
        load()
        every(0.1) { [unowned self] in
            let t = Date().timeIntervalSince(start)
            while next < steps.count, steps[next].delay <= t {
                self.graph.apply(steps[next].event)
                next += 1
            }
            if t > end {
                self.reset()
                start = Date()
                load()
            }
        }
        every(3) { [unowned self] in self.graph.tick(now: Date()) }
    }

    /// Six nodes in every kind of state, then nothing changes.
    func startIdle() {
        let o = AgentGraph.orchestratorID
        set(o, .idle, "Waiting for you")
        add("explore", .subagent, "mac", .thinking, "Reading Sources/", name: "Explore")
        add("build", .worker, "pc", .working, "swift build")
        add("lint", .worker, "mac", .idle, "Idle")
        add("review", .subagent, "mac", .needsInput("Ship the API change?"), "", name: "code-review")
        add("bench", .worker, "pc", .waiting(["build"]), "")
        add("deploy", .worker, "pc", .error("ssh: connect to host pc port 22: timed out"), "")
    }

    /// `n` nodes at once, with data moving on some cable all the time.
    func startCrowd(_ n: Int) {
        set(AgentGraph.orchestratorID, .working, "Coordinating \(n) agents")
        let states: [AgentState] = [.working, .thinking, .working, .idle, .waiting(["w1"]), .working]
        for i in 0..<n {
            let host = i % 2 == 0 ? "mac" : "pc"
            add("w\(i + 1)", i % 3 == 0 ? .subagent : .worker, host, states[i % states.count], "task \(i + 1): make check")
        }
        every(0.15) { [unowned self] in self.randomFlow() }
    }

    private func randomFlow() {
        let live = graph.others.filter { $0.state != .done }
        guard let node = live.randomElement() else { return }
        flow(node.id, Bool.random() ? .toNode : .toOrchestrator)
    }

    // MARK: - Pointer script

    func runPointerScript(_ path: String, in window: NSWindow) {
        guard let data = FileManager.default.contents(atPath: path),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Self.log("pointer script unreadable: \(path)")
            return
        }
        Self.log("pointer script: \(steps.count) steps")
        var at: TimeInterval = 0
        for step in steps {
            at += (step["wait"] as? NSNumber)?.doubleValue ?? 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                if let label = step["log"] as? String {
                    Self.logState(label, window)
                } else if let out = step["snapshot"] as? String {
                    Self.snapshot(window, to: out)
                } else if let name = step["cmd"] as? String {
                    Self.log("pointer \(name)")
                    _ = PointerAutomation.handle(name, step)
                }
            }
        }
    }

    private static func logState(_ label: String, _ window: NSWindow) {
        guard let stage = PointerAutomation.stage(in: window.contentView) else {
            log("state \(label): no canvas in window")
            return
        }
        let cam = stage.scene.camera
        let nodes = Dictionary(stage.scene.lastFrame.map { ($0.id, $0.position) }, uniquingKeysWith: { a, _ in a })
        log(String(format: "state %@ pan=(%.1f, %.1f) zoom=%.3f nodes %@", label, cam.pan.width, cam.pan.height,
                   cam.zoom, describe(nodes)))
    }

    static func describe(_ points: [String: CGPoint]) -> String {
        points.keys.sorted().map { String(format: "%@=(%.0f, %.0f)", $0, points[$0]!.x, points[$0]!.y) }
            .joined(separator: " ")
    }

    // MARK: - Snapshots

    func startSnapshots(of window: NSWindow, to path: String) {
        every(3) { [unowned self] in
            self.snapshotCount += 1
            let out = path.contains("%d") ? path.replacingOccurrences(of: "%d", with: "\(self.snapshotCount)") : path
            Self.snapshot(window, to: out)
        }
    }

    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView, let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: cached)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        Theme.window.setFill()
        view.bounds.fill()
        cached.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
