import SwiftUI

/// Tiny line chart with a soft fill. One Canvas, no per point views.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    /// Fixed range, e.g. 0...1 for usage. Nil scales to the data with some headroom.
    var range: ClosedRange<Double>?
    var capacity = Series.capacity

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let r = range ?? Self.autoRange(values)
            let span = max(r.upperBound - r.lowerBound, .ulpOfOne)
            let step = size.width / CGFloat(max(capacity - 1, 1))
            let x0 = size.width - CGFloat(values.count - 1) * step
            func point(_ i: Int) -> CGPoint {
                let v = (min(max(values[i], r.lowerBound), r.upperBound) - r.lowerBound) / span
                return CGPoint(x: x0 + CGFloat(i) * step, y: size.height - 1 - CGFloat(v) * (size.height - 2))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: x0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
    }

    /// Data range padded so a flat line sits in the middle instead of the floor.
    static func autoRange(_ v: [Double]) -> ClosedRange<Double> {
        let lo = v.min() ?? 0, hi = v.max() ?? 1
        let pad = max((hi - lo) * 0.2, 2)
        return (lo - pad)...(hi + pad)
    }
}

enum ActivityColor {
    /// Calm, warning, danger.
    static func level(_ i: Int) -> Color {
        switch i {
        case 0: Palette.success
        case 1: Palette.warning
        default: Palette.danger
        }
    }
}
