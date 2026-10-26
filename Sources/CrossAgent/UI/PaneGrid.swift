import SwiftUI

/// All panes in an auto grid. Every pane stays in the hierarchy (keyed by id) even
/// when one is maximized, so terminal views are never torn down by a relayout.
struct PaneGrid: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let maxIndex = app.panes.firstIndex { $0.id == app.maximizedID }
        GridLayout(maximized: maxIndex, gap: Palette.gap) {
            ForEach(app.panes) { pane in
                let hidden = app.maximizedID != nil && app.maximizedID != pane.id
                PaneView(pane: pane, focused: pane.id == app.focusedID, hidden: hidden)
                    .zIndex(app.maximizedID == pane.id ? 1 : 0)
            }
        }
    }
}

/// 1 full, 2 side by side, 3-4 as 2x2, 5-6 as 3x2, 7-8 as 4x2, 9 as 3x3, then 4 wide.
/// A short last row stretches to fill the width.
struct GridLayout: Layout {
    var maximized: Int?
    var gap: CGFloat

    static func shape(for n: Int) -> (cols: Int, rows: Int) {
        let cols: Int
        switch n {
        case ...1: cols = 1
        case 2...4: cols = 2
        case 5...6: cols = 3
        case 7...8: cols = 4
        case 9: cols = 3
        default: cols = 4
        }
        return (cols, max(1, Int((Double(n) / Double(cols)).rounded(.up))))
    }

    static func frames(count n: Int, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        guard n > 0 else { return [] }
        let (cols, rows) = shape(for: n)
        let h = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var out: [CGRect] = []
        for row in 0..<rows {
            let inRow = min(cols, n - row * cols)
            let w = (bounds.width - gap * CGFloat(inRow - 1)) / CGFloat(inRow)
            for col in 0..<inRow {
                out.append(CGRect(x: bounds.minX + CGFloat(col) * (w + gap),
                                  y: bounds.minY + CGFloat(row) * (h + gap),
                                  width: w, height: h).integral)
            }
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(count: subviews.count, in: bounds, gap: gap)
        for (i, sub) in subviews.enumerated() {
            // Hidden panes keep their grid frame so their terminals keep their size.
            let rect = (i == maximized) ? bounds : frames[i]
            sub.place(at: rect.origin, proposal: ProposedViewSize(rect.size))
        }
    }
}
