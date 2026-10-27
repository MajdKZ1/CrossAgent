import CoreGraphics

/// One eye: a dark rounded bar. Design units, y down.
struct MascotEye: Equatable {
    var center: CGPoint
    var size: CGSize
    /// Degrees, positive leans the top to the right.
    var tilt: CGFloat
    /// Corner radius as a share of half the short side. 1 is a full pill.
    var round: CGFloat = 0.62

    var cornerRadius: CGFloat { round * min(size.width, size.height) / 2 }

    func with(_ change: (inout MascotEye) -> Void) -> MascotEye {
        var e = self
        change(&e)
        return e
    }
}

/// Where everything rests for a mood. Loops and tricks move around this.
struct MascotPose: Equatable {
    var shape: MascotBodyShape = .squircle
    var left = MascotPose.restLeft
    var right = MascotPose.restRight
    /// Where the eyes look, as an offset from rest.
    var gaze: CGPoint = .zero
    /// Closed ^ ^ eyes instead of the bars.
    var happy = false
    var thought = false
    var alert = false
    var zzz = false

    /// The reference face: two tall bars leaning a little, set high and right of centre,
    /// the right one a touch smaller and lower.
    static let restLeft = MascotEye(center: CGPoint(x: 43.5, y: 51.5), size: CGSize(width: 5.9, height: 14.6), tilt: -9)
    static let restRight = MascotEye(center: CGPoint(x: 64.5, y: 52.6), size: CGSize(width: 5.4, height: 13.6), tilt: -9)

    /// Middle of both eyes at rest. Gaze and the blink pivot around here.
    static var eyeLine: CGPoint {
        CGPoint(x: (restLeft.center.x + restRight.center.x) / 2, y: (restLeft.center.y + restRight.center.y) / 2)
    }

    static func of(_ mood: MascotMood) -> MascotPose {
        var p = MascotPose()
        switch mood {
        case .idle:
            break
        case .thinking:
            p.shape = .cloud
            p.thought = true
            p.gaze = CGPoint(x: 3, y: -3.2)
            p.left = restLeft.with { $0.size.height *= 0.86; $0.tilt = -14 }
            p.right = restRight.with { $0.size.height *= 0.86; $0.tilt = -14 }
        case .working:
            p.shape = .puffy
            p.gaze = CGPoint(x: 0, y: 1.5)
            // Narrowed and a bit wider: focused.
            p.left = restLeft.with { $0.size = CGSize(width: 7.6, height: 4.6); $0.tilt = 9; $0.round = 0.9; $0.center.y += 2 }
            p.right = restRight.with { $0.size = CGSize(width: 7, height: 4.4); $0.tilt = -9; $0.round = 0.9; $0.center.y += 2 }
        case .bobbing:
            p.shape = .puffy
            p.gaze = CGPoint(x: 2.4, y: -2.2)
        case .juggling:
            p.shape = .puffy
            p.left = restLeft.with { $0.size.height += 1 }
            p.right = restRight.with { $0.size.height += 1 }
        case .needsInput:
            p.alert = true
            p.gaze = CGPoint(x: 0, y: -1)
            p.left = restLeft.with { $0.size = CGSize(width: 8.2, height: 17); $0.tilt = 0; $0.round = 1; $0.center.y -= 1 }
            p.right = restRight.with { $0.size = CGSize(width: 7.6, height: 16); $0.tilt = 0; $0.round = 1; $0.center.y -= 1 }
        case .done:
            p.happy = true
        case .error:
            p.left = restLeft.with { $0.size = CGSize(width: 6.6, height: 12.5); $0.tilt = 14; $0.round = 0.6 }
            p.right = restRight.with { $0.size = CGSize(width: 5.6, height: 8.4); $0.tilt = -22; $0.round = 0.6; $0.center.y += 2 }
        case .sleeping:
            p.shape = .round
            p.zzz = true
            p.left = restLeft.with { $0.size = CGSize(width: 8, height: 1.9); $0.tilt = 0; $0.round = 1; $0.center.y += 5 }
            p.right = restRight.with { $0.size = CGSize(width: 7.4, height: 1.9); $0.tilt = 0; $0.round = 1; $0.center.y += 5 }
        }
        return p
    }
}
