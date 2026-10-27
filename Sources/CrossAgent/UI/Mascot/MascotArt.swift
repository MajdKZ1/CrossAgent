import AppKit

// Patch, the CrossAgent mascot. A little terminal with a white case, a dark screen
// for a face and a blue to purple cable arching over its head, like the app icon.
// Every pixel is drawn here in code: one character per pixel, mapped to `colors`.

/// One frame: a square grid of palette indices, 0 is clear.
struct MascotPixels: Equatable {
    static let size = 28

    var px = [UInt8](repeating: 0, count: size * size)

    subscript(x: Int, y: Int) -> UInt8 {
        get { inside(x, y) ? px[y * Self.size + x] : 0 }
        set { if inside(x, y), newValue != 0 { px[y * Self.size + x] = newValue } }
    }

    private func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < Self.size && y < Self.size }

    /// Draws a sprite with its top left at (x, y). `.` is see-through, `A` is the arch
    /// gradient picked by column, `O` takes `orb` (an index from `MascotArt.orbBase`).
    mutating func stamp(_ rows: [String], _ x: Int, _ y: Int, orb: UInt8 = 0) {
        for (dy, row) in rows.enumerated() {
            for (dx, ch) in row.enumerated() where ch != "." {
                let c: UInt8
                switch ch {
                case "A": c = MascotArt.arch(x + dx)
                case "O": c = orb
                default: c = MascotArt.index[ch] ?? 0
                }
                self[x + dx, y + dy] = c
            }
        }
    }

    struct Run: Equatable {
        var color: UInt8, x: Int, y: Int, w: Int
    }

    /// Horizontal runs per color, so a frame is a handful of rects.
    func runs() -> [Run] {
        var out: [Run] = []
        for y in 0..<Self.size {
            var x = 0
            while x < Self.size {
                let c = px[y * Self.size + x]
                var end = x + 1
                while end < Self.size, px[y * Self.size + end] == c { end += 1 }
                if c != 0 { out.append(Run(color: c, x: x, y: y, w: end - x)) }
                x = end
            }
        }
        return out
    }
}

enum MascotArt {
    // MARK: Palette

    /// Character, hex. Index in this list + 1 is the palette index.
    static let palette: [(Character, String)] = [
        ("K", "#0c0e14"), // outline
        ("W", "#e9ecf3"), // case
        ("w", "#aeb6c8"), // case shade
        ("L", "#ffffff"), // glint
        ("D", "#1b1f2a"), // screen
        ("E", "#7af0c2"), // eyes, mint like the prompt in the icon
        ("e", "#3f9e7d"), // dim mint: mouth, closed eyes
        ("P", "#ff8fab"), // blush
        ("R", "#ff6b7a"), // error eyes
        ("Y", "#ffd66b"), // sparkles, stars
        ("B", "#8fd3ff"), // sweat drop
        ("Z", "#aab4d4"), // zzz
        ("T", "#d7dce8"), // thinking dot
        ("t", "#596073"), // thinking dot, dim
        ("X", "#f5b041"), // alert mark
        ("1", "#5aa8ff"), // arch, blue end
        ("2", "#6593ff"),
        ("3", "#707cff"),
        ("4", "#7b61ff"), // arch, purple end
    ]

    static let index: [Character: UInt8] = Dictionary(uniqueKeysWithValues: palette.enumerated().map { ($1.0, UInt8($0 + 1)) })
    static let colors: [CGColor] = palette.map { NSColor(hex: $0.1).cgColor }
    static let orbBase: UInt8 = 200

    /// Arch color for a canvas column: four steps from blue to purple.
    static func arch(_ x: Int) -> UInt8 {
        let step = min(3, max(0, (x - (bx + 3)) * 4 / 12))
        return index[Character(String(step + 1))]!
    }

    static func color(_ i: UInt8, orbs: [String]) -> CGColor {
        if i >= orbBase {
            let n = Int(i - orbBase)
            return n < orbs.count ? hostColor(orbs[n]) : colors[Int(index["4"]!) - 1]
        }
        return colors[Int(i) - 1]
    }

    /// Host accents from hosts.json, read once.
    private static let hostAccents: [String: CGColor] = Dictionary(
        HostStore.load().map { ($0.id, NSColor(hex: $0.accent).cgColor) }, uniquingKeysWith: { a, _ in a })

    /// Orb color for a host. Unknown hosts get the arch purple.
    static func hostColor(_ id: String) -> CGColor { hostAccents[id] ?? colors[Int(index["4"]!) - 1] }

    // MARK: Sprites

    /// Where the body sprite's top left sits on the 28 x 28 canvas.
    static let bx = 5, by = 11

    static let body = [
        "......AAAAAA......",
        "....AAAAAAAAAA....",
        "...AAA......AAA...",
        "...AA........AA...",
        "..KKKKKKKKKKKKKK..",
        ".KWLLWWWWWWWWWWWK.",
        ".KWWDDDDDDDDDDWWK.",
        ".KWDDDDDDDDDDDDWK.",
        ".KWDDDDDDDDDDDDWK.",
        ".KWDDDDDDDDDDDDWK.",
        ".KWDDDDDDDDDDDDWK.",
        ".KWWDDDDDDDDDDWWK.",
        ".KWWWWWWWWWWWWWWK.",
        ".KwWWWWWWWWWWWWwK.",
        "..KwwwwwwwwwwwwK..",
        "...KKKKKKKKKKKK...",
        "....KKK....KKK....",
    ]

    /// Faces sit on the screen, 12 x 6, top left at body (3, 6).
    enum Face: CaseIterable {
        case open, blink, up, focus, happy, wide, dizzy, asleep

        var rows: [String] {
            switch self {
            case .open: [
                "............",
                "..LE....LE..",
                "..EE....EE..",
                "..EE....EE..",
                ".PP......PP.",
                ".....ee.....",
            ]
            case .blink: [
                "............",
                "............",
                "............",
                "..EE....EE..",
                ".PP......PP.",
                ".....ee.....",
            ]
            case .up: [
                "...EL....EL.",
                "...EE....EE.",
                "............",
                "............",
                ".PP.....PP..",
                "......ee....",
            ]
            case .focus: [
                "............",
                "..EE....EE..",
                "..EE....EE..",
                "............",
                "............",
                "............",
            ]
            case .happy: [
                "............",
                "...E....E...",
                "..E.E..E.E..",
                "............",
                ".PP.e..e.PP.",
                ".....ee.....",
            ]
            case .wide: [
                "..LE....LE..",
                "..EE....EE..",
                "..EE....EE..",
                "............",
                ".PP..ee..PP.",
                ".....ee.....",
            ]
            case .dizzy: [
                "............",
                ".R.R....R.R.",
                "..R......R..",
                ".R.R....R.R.",
                ".....ee.....",
                "....e..e....",
            ]
            case .asleep: [
                "............",
                "............",
                "............",
                ".eee....eee.",
                ".PP......PP.",
                ".....ee.....",
            ]
            }
        }
    }

    static let hand = [
        ".KK.",
        "KWWK",
        "KWWK",
        ".KK.",
    ]

    static let orb = [
        ".OO.",
        "OLOO",
        "OOOO",
        ".OO.",
    ]

    static let bang = ["XX", "XX", "XX", "XX", "..", "XX"]
    static let zBig = ["ZZZZZ", "...Z.", "..Z..", ".Z...", "ZZZZZ"]
    static let zSmall = ["ZZZZ", "..Z.", ".Z..", "ZZZZ"]
    static let sparkSmall = [".Y.", "YLY", ".Y."]
    static let sparkBig = ["..Y..", "..Y..", "YYLYY", "..Y..", "..Y.."]
    static let star = [".Y.", "YYY", ".Y."]
    static let drop = [".B.", ".B.", "BBB", "BLB", ".B."]

    // MARK: Animation

    /// Frames and how long each one shows. Loops.
    struct Script: Equatable {
        var frames: [Double]

        var total: Double { frames.reduce(0, +) }

        /// Start of each frame as a fraction of the loop, then 1. One more than frames,
        /// as Core Animation wants for discrete keyframes.
        var keyTimes: [Double] {
            var t = 0.0
            return [0] + frames.map { t += $0; return t / total }
        }

        static func fps(_ fps: Double, _ count: Int) -> Script { Script(frames: Array(repeating: 1 / fps, count: count)) }

        /// Frame shown `t` seconds into the loop, and seconds until the next frame.
        func frame(at t: Double) -> (index: Int, remaining: Double) {
            // A hair of slack so a tick landing a rounding error early still flips the frame.
            let slack = 1e-6
            var p = (t + slack).truncatingRemainder(dividingBy: total)
            if p < 0 { p += total }
            for (i, d) in frames.enumerated() {
                if p < d { return (i, d - p + slack) }
                p -= d
            }
            return (0, frames[0])
        }
    }

    static func script(_ mood: MascotMood) -> Script {
        switch mood {
        // Breathing, with a blink every few breaths. About one redraw a second.
        case .idle: Script(frames: [1.2, 1.2, 1.2, 1.2, 0.9, 0.14, 0.3, 1.2])
        case .thinking: .fps(3, 4)
        case .working: .fps(8, 8)
        case .bobbing: .fps(6, 8)
        case .juggling: .fps(12, 24)
        case .needsInput: .fps(8, 8)
        case .done: .fps(10, 15)
        case .error: .fps(6, 8)
        case .sleeping: .fps(2, 8)
        }
    }

    // MARK: Frames

    private struct Key: Hashable {
        var mood: MascotMood
        /// Device pixels per sprite pixel.
        var px: Int
    }

    @MainActor private static var images: [Key: [CGImage]] = [:]

    /// Every frame of a mood as images, `px` device pixels per sprite pixel. Drawn once
    /// and kept; there are only a few dozen moods and scales, so the cache only resets
    /// as a safety net. Orb colors are fixed per host, so the mood is the whole key.
    @MainActor static func images(_ mood: MascotMood, px: Int) -> [CGImage] {
        let key = Key(mood: mood, px: max(1, px))
        if let hit = images[key] { return hit }
        if images.count > 200 { images = [:] }
        let made = (0..<script(mood).frames.count).compactMap { image(frame(mood, $0), orbs: orbs(mood), px: key.px) }
        images[key] = made
        return made
    }

    /// One frame as a bitmap with hard pixel edges.
    static func image(_ pixels: MascotPixels, orbs: [String], px: Int) -> CGImage? {
        let side = MascotPixels.size * px
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(false)
        let p = CGFloat(px)
        for r in pixels.runs() {
            ctx.setFillColor(color(r.color, orbs: orbs))
            // Bitmap rows count up from the bottom.
            ctx.fill(CGRect(x: CGFloat(r.x) * p, y: CGFloat(MascotPixels.size - 1 - r.y) * p, width: CGFloat(r.w) * p, height: p))
        }
        return ctx.makeImage()
    }

    /// Orb host ids for a mood, in palette order from `orbBase`.
    static func orbs(_ mood: MascotMood) -> [String] {
        switch mood {
        case .bobbing(let host): [host]
        case .juggling(let hosts): Array(hosts.prefix(MascotMood.maxOrbs))
        default: []
        }
    }

    /// Draws one frame of a mood.
    static func frame(_ mood: MascotMood, _ i: Int) -> MascotPixels {
        var f = Pose()
        switch mood {
        case .idle:
            // 0 up, 1 down, 5 blink. Matches `script(.idle)`.
            f.squash = [false, true, false, true, false, false, false, true][i % 8]
            f.face = i == 5 ? .blink : .open

        case .thinking:
            f.face = .up
            f.right = (16, 8)
            for d in 0..<3 {
                let lit = d == i % 4 - 1
                f.extras.append(([lit ? "TT" : "tt", lit ? "TT" : "tt"], 19 + d * 3, lit ? 5 : 6, 0))
            }

        case .working:
            f.face = .focus
            // Busy hands, and code typing itself out across the bottom of the screen.
            f.left = (-2, i % 2 == 0 ? 10 : 9)
            f.right = (16, i % 2 == 0 ? 9 : 10)
            let k = i % 8
            let lines = ["eee.eeee", "ee.eee"]
            let first = k < 4 ? 2 * (k + 1) : 8
            let second = k < 4 ? 0 : min(6, 2 * (k - 3))
            f.code = [String(lines[0].prefix(first)), String(lines[1].prefix(second))]
            f.cursor = k != 7

        case .bobbing:
            let lift = [0, -1, -2, -2, -1, 0, 0, 0][i % 8]
            f.dy = lift
            f.squash = i % 8 == 6
            f.face = .happy
            f.left = (-2, 10 + (i % 4 < 2 ? 0 : -1))
            f.right = (16, 10 + (i % 4 < 2 ? -1 : 0))
            let float = [0, 0, -1, -1, -1, 0, 0, 0][i % 8]
            f.extras.append((orb, 22, 9 + float, MascotArt.orbBase))

        case .juggling(let hosts):
            f.face = .up
            let n = min(hosts.count, MascotMood.maxOrbs)
            let pos = i % 24
            f.left = (-2, pos % 12 < 6 ? 8 : 9)
            f.right = (16, pos % 12 < 6 ? 9 : 8)
            for k in 0..<n {
                // Shower pattern: up over the head left to right, then back along the hands.
                let s = (Double(pos) / 24 + Double(k) / Double(n)).truncatingRemainder(dividingBy: 1)
                let (x, y): (Int, Int)
                if s < 0.8 {
                    let u = s / 0.8
                    x = Int((1 + u * 22).rounded())
                    y = Int((17 * pow(2 * u - 1, 2)).rounded())
                } else {
                    // Passed back behind the body; only seen while in a hand.
                    let u = (s - 0.8) / 0.2
                    guard u < 0.15 || u > 0.85 else { continue }
                    x = u < 0.5 ? 23 : 1
                    y = 18
                }
                f.extras.append((orb, x, y, MascotArt.orbBase + UInt8(k)))
            }

        case .needsInput:
            let hop = [0, -2, -3, -3, -2, 0, 0, 0][i % 8]
            f.dy = hop
            f.squash = i % 8 == 6
            f.face = .wide
            f.right = i % 4 < 2 ? (16, 5) : (17, 3)
            f.extras.append((bang, 3, 3 + hop + (i % 8 == 7 ? 1 : 0), 0))

        case .done:
            let jump = [0, 0, -3, -5, -6, -5, -3, 0, 0, 0, 0, 0, 0, 0, 0][i % 15]
            f.dy = jump
            f.squash = i % 15 == 0 || i % 15 == 7
            f.face = .happy
            let up = jump < 0 || i % 15 > 7
            f.left = up ? (-2, 4) : (-2, 10)
            f.right = up ? (16, 4) : (16, 10)
            let sparks: [(Int, Int, Bool)] = [(2, 6, true), (23, 3, false), (24, 14, true), (1, 16, false), (12, 1, true)]
            for (n, s) in sparks.enumerated() where i % 15 >= 2 + n && i % 15 < 9 + n {
                let big = (i + n) % 3 == 0 && s.2
                f.extras.append((big ? sparkBig : sparkSmall, s.0 - (big ? 1 : 0), s.1 - (big ? 1 : 0), 0))
            }

        case .error:
            f.face = .dizzy
            // Three stars circling over the head.
            for k in 0..<3 {
                let a = (Double(i % 8) / 8 + Double(k) / 3) * 2 * .pi
                f.extras.append((star, 13 + Int((cos(a) * 9).rounded()), 8 + Int((sin(a) * 2.5).rounded()), 0))
            }
            f.extras.append((drop, 23, 13 + (i % 8) / 3, 0))

        case .sleeping:
            f.face = .asleep
            f.squash = i % 8 >= 4
            // Two z's drifting up and growing, half a loop apart.
            let path: [(Int, Int)] = [(20, 10), (20, 8), (21, 6), (21, 5), (22, 3), (22, 2), (23, 1), (23, 0)]
            for phase in [i % 8, (i + 4) % 8] {
                let (x, y) = path[phase]
                f.extras.append((phase < 4 ? zSmall : zBig, x, y, 0))
            }
        }
        return f.draw()
    }

    /// The parts of a frame before it becomes pixels. Positions are in body coordinates
    /// except `extras`, which are canvas coordinates.
    private struct Pose {
        var dy = 0
        /// Head sinks one pixel into the chin, for breathing and landing.
        var squash = false
        var face: Face = .open
        var left = (-2, 10)
        var right = (16, 10)
        /// Lines of text on the lower screen, typed so far. A cursor follows the last one.
        var code: [String] = []
        var cursor = true
        var extras: [([String], Int, Int, UInt8)] = []

        func draw() -> MascotPixels {
            var p = MascotPixels()
            let head = dy + (squash ? 1 : 0)
            for (r, row) in body.enumerated() {
                if squash && r == 13 { continue }
                p.stamp([row], bx, by + r + (r < 13 ? head : dy))
            }
            p.stamp(face.rows, bx + 3, by + 6 + head)
            if !code.isEmpty {
                var rows = code
                let last = rows.lastIndex { !$0.isEmpty } ?? 0
                if cursor { rows[last] += "E" }
                p.stamp(rows, bx + 5, by + 10 + head)
            }
            p.stamp(hand, bx + left.0, by + left.1 + head)
            p.stamp(hand, bx + right.0, by + right.1 + head)
            for (sprite, x, y, orb) in extras {
                p.stamp(sprite, x, y, orb: orb)
            }
            return p
        }
    }
}
