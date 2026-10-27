import AppKit
import Foundation

/// Live CPU, memory and temperature readings for every host. Shared by the Activity
/// tab and the tab strip readout. Samples only while at least one of them is on screen
/// and the window is actually visible.
@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()

    /// Hosts in display order: this Mac first, then the rest as configured.
    @Published private(set) var hosts: [HostActivity] = []

    private var configured: [Host] = []
    private var viewers = 0
    private var detailViewers = 0
    private var mac: MacSampler?
    private var remotes: [String: RemoteSampler] = [:]
    private var observers: [NSObjectProtocol] = []
    private var sampling = false

    /// Reference counted. `detail` viewers (the tab) also want per session load.
    func start(hosts: [Host], detail: Bool = false) {
        configure(hosts)
        viewers += 1
        if detail { detailViewers += 1 }
        if observers.isEmpty { observeWindow() }
        mac?.setWantsSessions(detailViewers > 0)
        update()
        // onAppear can run before the window reports itself visible, and a launch
        // without focus posts none of the notifications above.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop(detail: Bool = false) {
        viewers = max(0, viewers - 1)
        if detail { detailViewers = max(0, detailViewers - 1) }
        mac?.setWantsSessions(detailViewers > 0)
        if viewers == 0 {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
        update()
    }

    func host(_ id: String) -> HostActivity? { hosts.first { $0.hostId == id } }

    private func configure(_ list: [Host]) {
        let ordered = list.filter(\.isLocal) + list.filter { !$0.isLocal }
        guard ordered != configured else { return }
        let wasSampling = sampling
        if wasSampling { pause() }
        configured = ordered
        hosts = ordered.map { h in
            host(h.id) ?? HostActivity(hostId: h.id, name: h.isLocal ? "Mac" : Self.shortName(h), accent: h.accent)
        }
        mac = nil
        remotes = [:]
        for h in ordered {
            if h.isLocal {
                guard mac == nil else { continue }
                let id = h.id
                mac = MacSampler { [weak self] sample, sessions in self?.apply(id, sample, sessions) }
            } else {
                let id = h.id
                remotes[id] = RemoteSampler(host: h) { [weak self] event in
                    switch event {
                    case .sample(let s, let sessions): self?.apply(id, s, sessions)
                    case .failed(let why): self?.fail(id, why)
                    }
                }
            }
        }
        if wasSampling { resume() }
    }

    /// "Linux PC" reads as "PC" in tight spots.
    static func shortName(_ h: Host) -> String {
        h.name.split(separator: " ").last.map(String.init) ?? h.name
    }

    private func apply(_ id: String, _ sample: ActivitySample, _ sessions: [SessionLoad]?) {
        guard sampling, let i = hosts.firstIndex(where: { $0.hostId == id }) else { return }
        var h = hosts[i]
        h.record(sample)
        if let sessions { h.sessions = Array(sessions.sorted { $0.cpu > $1.cpu }.prefix(5)) }
        hosts[i] = h
    }

    private func fail(_ id: String, _ why: String) {
        guard let i = hosts.firstIndex(where: { $0.hostId == id }) else { return }
        hosts[i].status = .unavailable(why)
    }

    // MARK: Visibility

    private func observeWindow() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification,
                                          NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                                          NSApplication.didBecomeActiveNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }

    /// True when some regular window of ours is on screen. A test harness without
    /// windows can force sampling with CROSSAGENT_ACTIVITY_DUMP.
    private var windowVisible: Bool {
        if ProcessInfo.processInfo.environment["CROSSAGENT_ACTIVITY_DUMP"] != nil { return true }
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible) }
    }

    private func update() {
        let want = viewers > 0 && windowVisible
        if want, !sampling { resume() } else if !want, sampling { pause() }
    }

    private func resume() {
        sampling = true
        mac?.start()
        remotes.values.forEach { $0.start() }
    }

    private func pause() {
        sampling = false
        mac?.stop()
        remotes.values.forEach { $0.stop() }
    }
}
