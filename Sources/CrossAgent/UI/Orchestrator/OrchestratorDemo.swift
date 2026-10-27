import AppKit
import SwiftUI

/// Dev only: a window with the orchestrator canvas fed by DemoEvents through the
/// reducer, opened with CROSSAGENT_ORCH_DEMO=1.
///
/// - CROSSAGENT_ORCH_DEMO=idle: six nodes that settle and then sit still.
/// - CROSSAGENT_ORCH_DEMO_NODES=<n>: n nodes at once with data flowing all the time.
/// - CROSSAGENT_ORCH_DEMO_SNAPSHOT=<path>: writes a PNG of the window every 3 s.
///   A `%d` in the path is replaced by a counter. The window opens behind others.
/// - CROSSAGENT_ORCH_DEMO_POSITIONS=<path>: JSON {id: [x, y]} to start from, like a relaunch.
/// - CROSSAGENT_ORCH_DEMO_POINTER=regression with CROSSAGENT_ORCH_DEMO=idle: canvas
///   interaction checks, one PASS or FAIL line each, then a summary line.
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
        let root = DemoRoot(graph: driver.graph, hosts: HostStore.load(), ui: driver.ui)
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
        if let pointer = env["CROSSAGENT_ORCH_DEMO_POINTER"] {
            if pointer == "regression" { driver.runRegression(in: w) } else { driver.runPointerScript(pointer, in: w) }
        }
    }
}

private struct DemoRoot: View {
    @ObservedObject var graph: AgentGraph
    var hosts: [Host]
    /// CROSSAGENT_ORCH_DEMO_POSITIONS=<json file of {id: [x, y]}> starts from saved
    /// positions, like a relaunch.
    @State private var positions: [String: CGPoint] = DemoRoot.savedPositions()

    private static func savedPositions() -> [String: CGPoint] {
        guard let path = ProcessInfo.processInfo.environment["CROSSAGENT_ORCH_DEMO_POSITIONS"],
              let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }
    /// Stands in for the app's detail card: a backdrop and a panel with an AppKit
    /// text view that takes first responder, like the worker terminal does.
    @ObservedObject var ui: DemoUI
    private var detail: String? {
        get { ui.detail }
        nonmutating set { ui.detail = newValue }
    }

    var body: some View {
        ZStack {
            OrchestratorView(graph: graph, hosts: hosts, positions: $positions, actions: OrchestratorActions(
                expand: { id in
                    DemoDriver.log("expand \(id)")
                    ui.expanded.append(id)
                    detail = id
                },
                relay: { DemoDriver.log("relay \($0) -> \($1)") },
                clearFinished: { graph.clearFinished() },
                answer: { id in
                    DemoDriver.log("answer \(id)")
                    graph.nodes[id]?.state = .working
                    graph.nodes[id]?.activity = "Back at it"
                }))
            if let id = detail {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        DemoDriver.log("close detail \(id)")
                        detail = nil
                    }
                DemoDetailText(text: "Detail for \(id)")
                    .frame(width: 420, height: 260)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: detail)
        .frame(minWidth: 500, minHeight: 360)
        .onChange(of: positions) {
            ui.positions = positions
            DemoDriver.log("positions \(DemoDriver.describe(positions))")
        }
    }
}

@MainActor
final class DemoUI: ObservableObject {
    @Published var detail: String?
    /// Mirror of the positions binding, what the app would save.
    var positions: [String: CGPoint] = [:]
    var expanded: [String] = []
}

private struct DemoDetailText: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSTextView {
        let v = NSTextView()
        v.string = text
        v.backgroundColor = Theme.pane
        v.textColor = .white
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {}
}

/// Feeds the demo window: DemoEvents through the reducer, or a fixed scene for perf runs.
@MainActor
private final class DemoDriver {
    let graph = AgentGraph(orchestratorHost: "mac")
    let ui = DemoUI()
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
                } else if let name = step["spawn"] as? String {
                    self.add(name, .subagent, "mac", .working, "Spawned mid gesture")
                    Self.log("spawned \(name)")
                } else if let open = step["detail"] {
                    // Opens or closes the stand in detail card without a click, like the
                    // app's expand and closeDetail automation commands.
                    self.ui.detail = open as? String
                    Self.log("detail \(self.ui.detail ?? "closed")")
                } else if let xy = step["hittest"] as? [Double], let content = window.contentView {
                    var v = content.hitTest(content.convert(NSPoint(x: xy[0], y: xy[1]), from: nil))
                    var chain: [String] = []
                    while let view = v, chain.count < 6 { chain.append("\(type(of: view))"); v = view.superview }
                    Self.log("hittest \(xy): " + chain.joined(separator: " < "))
                } else if let out = step["snapshot"] as? String {
                    Self.snapshot(window, to: out)
                } else if let name = step["cmd"] as? String {
                    // Always this window: the main window may show a canvas too.
                    var cmd = step
                    cmd["window"] = cmd["window"] ?? window.title
                    _ = PointerAutomation.handle(name, cmd)
                }
            }
        }
    }

    // MARK: - Regression

    /// Pointer checks against the idle scene. Each step runs after the previous one
    /// has had time to land and settle.
    func runRegression(in window: NSWindow) {
        // Looked up when the checks run: SwiftUI builds the canvas after this returns.
        var stage: CanvasStage { PointerAutomation.stage(in: window.contentView)! }
        let title = window.title
        var failures = 0
        var at: TimeInterval = 5
        func step(_ wait: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            at += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { body() }
        }
        func pointer(_ cmd: [String: Any]) {
            var c = cmd
            c["window"] = title
            _ = PointerAutomation.handle(c["cmd"] as? String ?? "", c)
        }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            Self.log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
        }
        func near(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.x - b.x) < 1.5 && abs(a.y - b.y) < 1.5
        }
        func pos(_ id: String) -> CGPoint? { stage.scene.currentPositions()[id] }
        func moved(_ p: CGPoint?, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint? { p.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        var mark: [String: CGPoint] = [:]

        step(0) {
            let all = ["bench", "build", "deploy", "explore", "lint", "review"]
            check("settled layout is published", all.allSatisfy { near(self.ui.positions[$0], pos($0)) },
                  Self.describe(self.ui.positions))
            mark = stage.scene.currentPositions()
            pointer(["cmd": "drag", "node": "build", "dx": -100, "dy": 50, "steps": 12])
        }
        step(1.2) {
            let want = moved(mark["build"], -100, -50)
            check("node drag pins and saves the spot", near(pos("build"), want) && near(self.ui.positions["build"], want),
                  "at \(Self.describe(["build": pos("build") ?? .zero])) saved \(Self.describe(["build": self.ui.positions["build"] ?? .zero]))")
            mark = stage.scene.currentPositions()
            pointer(["cmd": "drag", "node": "review", "dx": 70, "dy": 30, "steps": 1])
        }
        step(1.0) {
            let want = moved(mark["review"], 70, -30)
            check("one step drag saves the final spot", near(self.ui.positions["review"], want) && near(pos("review"), want))
            self.ui.detail = "build"
        }
        step(0.8) { self.ui.detail = nil }
        step(0.6) {
            mark = stage.scene.currentPositions()
            pointer(["cmd": "drag", "node": "build", "dx": 40, "dy": 0, "steps": 10])
        }
        step(1.2) {
            check("card drags after its detail closed", near(pos("build"), moved(mark["build"], 40, 0)))
            self.ui.expanded = []
            pointer(["cmd": "tap", "node": "build"])
        }
        step(0.6) {
            check("card taps after its detail closed", self.ui.expanded == ["build"])
            self.ui.detail = nil
        }
        step(0.6) {
            mark = stage.scene.currentPositions()
            pointer(["cmd": "drag", "node": "lint", "dx": -30, "dy": 0, "steps": 8, "noUp": true])
        }
        step(0.8) {
            // Explore isn't pinned, so the layout may have nudged it while lint moved.
            mark["explore"] = pos("explore")
            pointer(["cmd": "drag", "node": "explore", "dx": 0, "dy": -40, "steps": 8])
        }
        step(1.2) {
            check("drag after a lost mouseUp moves the right node",
                  near(pos("explore"), moved(mark["explore"], 0, 40)) && near(pos("lint"), moved(mark["lint"], -30, 0)),
                  "before " + Self.describe(mark.filter { ["explore", "lint"].contains($0.key) })
                    + " after " + Self.describe(stage.scene.currentPositions().filter { ["explore", "lint"].contains($0.key) }))
            mark = stage.scene.currentPositions()
            pointer(["cmd": "drag", "node": "lint", "dx": 0, "dy": 30, "steps": 8])
        }
        step(1.2) {
            check("card with the lost mouseUp drags again", near(pos("lint"), moved(mark["lint"], 0, -30)),
                  "lint before \(Self.describe(["lint": mark["lint"] ?? .zero])) after \(Self.describe(["lint": pos("lint") ?? .zero]))")
            self.ui.expanded = []
            pointer(["cmd": "tap", "node": "lint"])
        }
        step(0.6) {
            check("card with the lost mouseUp taps again", self.ui.expanded == ["lint"])
            self.ui.detail = nil
            pointer(["cmd": "drag", "x": 80, "y": 80, "toX": 140, "toY": 120, "steps": 10])
        }
        step(0.8) {
            check("drag on empty space pans", stage.scene.camera.pan == CGSize(width: 60, height: -40))
            pointer(["cmd": "dblclick", "x": 80, "y": 80])
        }
        step(0.8) {
            check("double click recenters", stage.scene.camera == Camera())
            pointer(["cmd": "scroll", "x": 800, "y": 500, "dx": 0, "dy": 50, "mods": ["cmd"]])
        }
        step(0.6) {
            let cam = stage.scene.camera
            check("cmd scroll zooms around the pointer",
                  abs(cam.zoom - 1.492) < 0.01 && abs(cam.pan.width + 123) < 1 && abs(cam.pan.height - 61.5) < 1,
                  "pan \(cam.pan) zoom \(cam.zoom)")
            Self.log(failures == 0 ? "regression: all passed" : "regression: \(failures) failed")
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
