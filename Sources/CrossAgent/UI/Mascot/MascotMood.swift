import Foundation

/// One busy agent floating around the mascot as a small orb in its host colour.
struct MascotOrb: Equatable, Hashable {
    /// Node id, handed to `onOpenAgent` when the orb is clicked.
    var id: String
    var host: String
}

/// What Puff is doing right now, worked out from the agent graph.
enum MascotMood: Equatable, Hashable {
    case idle
    case thinking
    case working
    /// Exactly one subagent or worker busy.
    case bobbing(orb: MascotOrb)
    /// Two or more busy. One orb per agent, oldest first, at most 5.
    case juggling(orbs: [MascotOrb])
    case needsInput
    case done
    case error
    case sleeping

    static let doneFor: TimeInterval = 3
    /// A finished node that failed only counts as an error this long.
    static let errorFor: TimeInterval = 20
    static let sleepAfter: TimeInterval = 60
    static let maxOrbs = 5

    /// Pure: same nodes and time in, same mood out. Highest priority first.
    static func from(orchestrator: AgentNode?, others: [AgentNode], now: Date) -> MascotMood {
        let all = (orchestrator.map { [$0] } ?? []) + others
        if all.contains(where: { $0.isFreshError(now) }) { return .error }
        if all.contains(where: { if case .needsInput = $0.state { return true }; return false }) { return .needsInput }
        if let t = lastFinish(all), now >= t, now.timeIntervalSince(t) < doneFor { return .done }

        let active = others.filter(\.isBusy).sorted { $0.startedAt < $1.startedAt }
        let orbs = active.prefix(maxOrbs).map { MascotOrb(id: $0.id, host: $0.hostId) }
        if orbs.count >= 2 { return .juggling(orbs: orbs) }
        if let one = orbs.first { return .bobbing(orb: one) }

        switch orchestrator?.state {
        case .working: return .working
        case .thinking, .waiting: return .thinking
        default: break
        }
        if let last = all.map(\.lastTouched).max(), now.timeIntervalSince(last) >= sleepAfter { return .sleeping }
        return .idle
    }

    @MainActor static func from(_ graph: AgentGraph, now: Date) -> MascotMood {
        from(orchestrator: graph.orchestrator, others: graph.others, now: now)
    }

    var orbs: [MascotOrb] {
        switch self {
        case .bobbing(let o): [o]
        case .juggling(let o): o
        default: []
        }
    }

    /// When the latest node finished. Start of the done celebration.
    static func lastFinish(_ nodes: [AgentNode]) -> Date? {
        nodes.compactMap { n -> Date? in
            if let f = n.finishedAt { return f }
            if case .done = n.state { return n.updatedAt }
            return nil
        }.max()
    }

    /// The next moment the mood can change with no new events: the done
    /// celebration running out, or the idle timer tipping into sleep.
    static func nextChange(orchestrator: AgentNode?, others: [AgentNode], after now: Date) -> Date? {
        let all = (orchestrator.map { [$0] } ?? []) + others
        var candidates: [Date] = []
        if let t = lastFinish(all) {
            candidates.append(t)
            candidates.append(t.addingTimeInterval(doneFor))
        }
        if let last = all.map(\.lastTouched).max() { candidates.append(last.addingTimeInterval(sleepAfter)) }
        for n in all where n.finishedAt != nil {
            if case .error = n.state { candidates.append(n.lastTouched.addingTimeInterval(errorFor)) }
        }
        return candidates.filter { $0 > now }.min()
    }
}

private extension AgentNode {
    var isBusy: Bool {
        switch state {
        case .thinking, .working, .waiting: return true
        default: return false
        }
    }

    var lastTouched: Date { max(updatedAt, finishedAt ?? .distantPast) }

    /// In error and still running, or finished with an error in the last `errorFor` seconds.
    func isFreshError(_ now: Date) -> Bool {
        guard case .error = state else { return false }
        return finishedAt == nil || now.timeIntervalSince(lastTouched) < MascotMood.errorFor
    }
}
