import AppKit

/// Terminal checks for a pane (default: the focused one, or "index").
///
///     {"cmd":"terminal","out":"/tmp/t.json"}            selection, metrics, buffer, find state
///     {"cmd":"find","text":"foo"}                       opens the find bar and searches
///     {"cmd":"find","step":"older"} / "newer"           next match
///     {"cmd":"find","close":true}
///     {"cmd":"wheel","dy":-40}                          pixel scroll, through the pane's wheel routing
///     {"cmd":"clearPane"}                               same as Cmd+K
extension Automation {
    func handleTerminal(_ name: String, _ cmd: [String: Any]) -> Bool {
        guard ["terminal", "find", "wheel", "clearPane"].contains(name) else { return false }
        let index = cmd["index"] as? Int
        guard let pane = index.map({ app.panes.indices.contains($0) ? app.panes[$0] : nil }) ?? app.focused else { return true }
        let t = pane.terminal
        switch name {
        case "find":
            if cmd["close"] as? Bool == true {
                t.hideFind()
            } else if let step = cmd["step"] as? String {
                t.findStep(older: step != "newer")
            } else {
                t.showFind()
                if let text = cmd["text"] as? String {
                    t.setFindText(text)
                }
            }
        case "wheel":
            guard let win = t.window else { return true }
            let p = t.convert(NSPoint(x: t.bounds.midX, y: t.bounds.midY), to: nil)
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: Int32(cmd["dy"] as? Double ?? 0), wheel2: 0, wheel3: 0),
                  let e = NSEvent(cgEvent: cg) else { return true }
            if !PaneTerminalView.routeWheel(e, in: win, at: p) { t.scrollWheel(with: e) }
        case "clearPane":
            pane.clearScrollback()
        default:
            let snap = t.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))
            let input = t.terminalInputStateSnapshot()
            let full = t.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100_000))
            let obj: [String: Any] = [
                "selection": t.getSelection() ?? "",
                "font": t.font.fontName, "fontSize": t.font.pointSize,
                "cellWidth": t.caretFrame.width, "cellHeight": t.caretFrame.height,
                "lineSpacing": t.lineSpacing,
                "nativeLineHeight": TerminalAppearance.nativeLineHeight(for: t.font),
                "scrollbackRows": max(0, (full?.rows.count ?? 0) - (snap?.rows.count ?? 0)),
                "alternate": input?.isAlternateBuffer ?? false,
                "mouseMode": "\(input.map { "\($0.mouseMode)" } ?? "off")",
                "bracketedPaste": input?.bracketedPasteMode ?? false,
                "tmuxScrolled": t.isTmuxScrolled,
                "topRow": t.terminalContentSnapshot(region: .viewport)?.rows.first?.text ?? "",
                "findVisible": t.isFindVisible, "findText": t.findText, "findCount": t.findCountText,
                "firstResponder": t.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
                "allowMouseReporting": t.allowMouseReporting,
                "selectionColor": "\(t.selectedTextBackgroundColor)",
            ]
            if let out = cmd["out"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out), options: .atomic)
            }
        }
        return true
    }
}
