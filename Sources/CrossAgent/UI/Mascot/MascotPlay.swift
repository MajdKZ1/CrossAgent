import Foundation

/// Picks what Puff does when clicked. Never the same trick twice in a row, and the
/// faster you click the bigger it gets: a streak raises the intensity and, from the
/// third click on, chains two tricks.
struct MascotPlay {
    enum Trick: CaseIterable, Equatable {
        /// Squash flat and spring back.
        case squish
        /// A full turn with a little hop.
        case spin
        /// Jelly wobble, width and height out of phase.
        case jelly
        /// Eyes shut, then pop open looking somewhere.
        case peekaboo
        /// Bounce off the edges of its spot.
        case ricochet
    }

    struct Move: Equatable {
        var tricks: [Trick]
        /// 1 for a single click, up to 1.9 for a fast streak.
        var intensity: Double
    }

    /// Clicks closer together than this keep the streak going.
    static let streakGap: TimeInterval = 1.3

    private(set) var streak = 0
    private(set) var last: Trick?
    private var lastAt: TimeInterval = -.infinity

    mutating func click<R: RandomNumberGenerator>(at time: TimeInterval, using rng: inout R) -> Move {
        streak = time - lastAt < Self.streakGap ? streak + 1 : 1
        lastAt = time
        var tricks = [pick(avoiding: last, &rng)]
        if streak >= 3 { tricks.append(pick(avoiding: tricks[0], &rng)) }
        last = tricks.last
        return Move(tricks: tricks, intensity: 1 + 0.3 * Double(min(streak - 1, 3)))
    }

    private func pick<R: RandomNumberGenerator>(avoiding: Trick?, _ rng: inout R) -> Trick {
        Trick.allCases.filter { $0 != avoiding }.randomElement(using: &rng)!
    }
}

/// Small seedable generator, so tests and the gallery are repeatable.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
