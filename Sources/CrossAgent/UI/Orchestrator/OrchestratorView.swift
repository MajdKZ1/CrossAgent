import AppKit
import SwiftUI

/// What the canvas asks the app to do. Wired up by whoever hosts the canvas.
struct OrchestratorActions {
    var expand: (String) -> Void = { _ in }
    var relay: (_ from: String, _ to: String) -> Void = { _, _ in }
    var clearFinished: () -> Void = {}
    var answer: (String) -> Void = { _ in }
}

/// The orchestrator canvas: the orchestrator in the middle, its agents hanging off it
/// on cables. Cables and particles are one Canvas; cards are SwiftUI views on top. One
/// TimelineView drives both and pauses whenever nothing moves.
struct OrchestratorView: View {
    @ObservedObject var graph: AgentGraph
    var hosts: [Host]
    /// Where the user dragged nodes, canvas coordinates with the orchestrator at (0,0).
    @Binding var positions: [String: CGPoint]
    var actions = OrchestratorActions()

    @StateObject private var scene = OrchestratorScene()
    @State private var hovered: String?
    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var grab: CGSize?
    @State private var relayFrom: String?

    private static let space = "orchestrator-canvas"

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !scene.running || !scene.visible)) { _ in
                let frame = scene.frame(now: Date(), size: size)
                content(frame, size: size)
            }
            .frame(width: size.width, height: size.height)
            .background(
                CanvasInput(onScroll: { e, p in scroll(e, at: p, size: size) },
                            onVisible: { v in DispatchQueue.main.async { scene.setVisible(v) } })
            )
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.space)
            .gesture(panGesture)
            .simultaneousGesture(magnifyGesture(size))
            .onTapGesture(count: 2) { scene.recenter() }
        }
        .background(Palette.window)
        .clipped()
        .overlay(alignment: .bottomLeading) { clearButton }
        .environment(\.answerAction, actions.answer)
        .onAppear {
            scene.setVisible(true)
            sync()
        }
        .onDisappear { scene.setVisible(false) }
        .onChange(of: graph.nodes) { sync() }
        .onChange(of: graph.finished) { sync() }
        .onChange(of: positions) { sync() }
    }

    private func sync() {
        scene.sync(nodes: graph.nodes, finished: graph.finished, positions: positions)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ f: SceneFrame, size: CGSize) -> some View {
        let cam = f.camera
        let accents = Dictionary(hosts.map { ($0.id, Palette.accent($0)) }, uniquingKeysWith: { a, _ in a })
        ZStack {
            Canvas(rendersAsynchronously: false) { ctx, _ in
                CableRenderer.draw(&ctx, frame: f, size: size, accents: accents)
            }
            .allowsHitTesting(false)

            ForEach(f.nodes) { v in
                nodeView(v, accent: accents[v.node.hostId] ?? Palette.muted, target: f.dropTarget == v.id)
                    .scaleEffect(v.scale * cam.zoom)
                    .opacity(v.opacity)
                    .position(CableRenderer.screen(v.position, cam: cam, size: size))
                    .allowsHitTesting(!v.leaving)
            }

            if let orch = graph.orchestrator {
                orchestratorView(orch, accent: accents[orch.hostId] ?? Palette.muted,
                                 target: f.dropTarget == orch.id)
                    .scaleEffect(cam.zoom)
                    .position(CableRenderer.screen(.zero, cam: cam, size: size))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func model(_ node: AgentNode, accent: Color, style: NodeStyle, target: Bool) -> NodeCardModel {
        NodeCardModel(node: node, hostLabel: HostBadge.label(hosts.first { $0.id == node.hostId }, id: node.hostId),
                      accent: accent, style: style, target: target, hovered: hovered == node.id)
    }

    private func nodeView(_ v: NodeVisual, accent: Color, target: Bool) -> some View {
        NodeCard(model: model(v.node, accent: accent, style: v.style, target: target))
            .equatable()
            .overlay(alignment: .trailing) {
                if (hovered == v.id || relayFrom == v.id) && !v.leaving {
                    RelayHandle(accent: accent)
                        .offset(x: 9.5)
                        .gesture(relayGesture(v.id))
                }
            }
            .onHover { hover(v.id, $0) }
            .onTapGesture { actions.expand(v.id) }
            .gesture(nodeGesture(v.id))
    }

    private func orchestratorView(_ orch: AgentNode, accent: Color, target: Bool) -> some View {
        NodeCard(model: model(orch, accent: accent, style: .live, target: target))
            .equatable()
            .overlay(alignment: .top) {
                MascotView(graph: graph)
                    .alignmentGuide(.top) { $0[.bottom] - 3 }
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                if hovered == orch.id || relayFrom == orch.id {
                    RelayHandle(accent: accent)
                        .offset(x: 9.5)
                        .gesture(relayGesture(orch.id))
                }
            }
            .onHover { hover(orch.id, $0) }
            .onTapGesture { actions.expand(orch.id) }
            .gesture(optionRelayOnly(orch.id))
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    @ViewBuilder private var clearButton: some View {
        if !graph.finished.isEmpty {
            Button {
                actions.clearFinished()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("Clear finished")
                    Text("\(graph.finished.count)").foregroundStyle(Palette.muted)
                }
            }
            .buttonStyle(ChromeButtonStyle())
            .padding(12)
            .transition(.opacity)
        }
    }

    // MARK: - Gestures

    private func canvasPoint(_ p: CGPoint, size: CGSize) -> CGPoint {
        let cam = scene.camera
        return CGPoint(x: (p.x - size.width / 2 - cam.pan.width) / cam.zoom,
                       y: (p.y - size.height / 2 - cam.pan.height) / cam.zoom)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let start = panStart ?? scene.camera.pan
                if panStart == nil { panStart = start }
                scene.camera.pan = CGSize(width: start.width + v.translation.width,
                                          height: start.height + v.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private func magnifyGesture(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let start = zoomStart ?? scene.camera.zoom
                if zoomStart == nil { zoomStart = start }
                let factor = start * v.magnification / scene.camera.zoom
                scene.zoom(by: factor, anchor: v.startLocation, viewSize: size)
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func scroll(_ e: NSEvent, at p: CGPoint, size: CGSize) {
        let scale: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        if e.modifierFlags.contains(.command) {
            scene.zoom(by: exp(e.scrollingDeltaY * scale * 0.008), anchor: p, viewSize: size)
        } else {
            scene.camera.pan.width += e.scrollingDeltaX * scale
            scene.camera.pan.height += e.scrollingDeltaY * scale
        }
    }

    /// Drags a node around (pins it there), or with Option held draws a relay cable.
    private func nodeGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let size = currentSize
                let p = canvasPoint(v.location, size: size)
                if grab == nil && relayFrom == nil {
                    if NSEvent.modifierFlags.contains(.option) {
                        relayFrom = id
                    } else {
                        let start = canvasPoint(v.startLocation, size: size)
                        let at = scene.position(of: id) ?? start
                        grab = CGSize(width: at.x - start.x, height: at.y - start.y)
                    }
                }
                if relayFrom != nil {
                    scene.relayDrag(from: id, to: p)
                } else if let g = grab {
                    scene.drag(id, to: CGPoint(x: p.x + g.width, y: p.y + g.height))
                }
            }
            .onEnded { _ in
                if relayFrom != nil {
                    finishRelay()
                } else {
                    if let p = scene.position(of: id), scene.dragging == id { positions[id] = p }
                    scene.endDrag()
                }
                grab = nil
            }
    }

    /// The orchestrator stays put; dragging it pans, Option dragging relays.
    private func optionRelayOnly(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if relayFrom == nil && panStart == nil && NSEvent.modifierFlags.contains(.option) { relayFrom = id }
                if relayFrom != nil {
                    scene.relayDrag(from: id, to: canvasPoint(v.location, size: currentSize))
                } else {
                    let start = panStart ?? scene.camera.pan
                    if panStart == nil { panStart = start }
                    scene.camera.pan = CGSize(width: start.width + v.translation.width,
                                              height: start.height + v.translation.height)
                }
            }
            .onEnded { _ in
                if relayFrom != nil { finishRelay() }
                panStart = nil
            }
    }

    private func relayGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { v in
                relayFrom = id
                scene.relayDrag(from: id, to: canvasPoint(v.location, size: currentSize))
            }
            .onEnded { _ in finishRelay() }
    }

    private func finishRelay() {
        relayFrom = nil
        if let r = scene.endRelay() { actions.relay(r.from, r.to) }
    }

    private var currentSize: CGSize { scene.viewSize }
}
