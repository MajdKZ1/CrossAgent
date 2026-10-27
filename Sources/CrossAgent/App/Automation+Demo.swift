#if DEBUG
import AppKit

/// Demo commands for README recordings. Stories need DemoMode (CROSSAGENT_DEMO=1).
///
///     {"cmd":"demoStory","name":"hero"}                     the hero canvas story, about 18 s, see DemoStory
///     {"cmd":"demoStory","name":"hero","loop":true}         over and over, clearing back to the lone orchestrator
///     {"cmd":"demoStory","name":"hero","autoAllow":false}   the approval waits for a click on Allow
///     {"cmd":"demoStory","name":"open"}                     a few agents with full cards, settled in 3 s
///     {"cmd":"demoStory","name":"reset"}                    back to the lone orchestrator
///     {"cmd":"puff","mood":"juggling"}                      every Puff in that mood ("auto" goes back to the graph's)
///     {"cmd":"puff","trick":true}                           a trick, like a click ("trick":"spin" picks one)
///     {"cmd":"puff","closeup":true,"scale":4,"out":"/tmp/p.json"}
///                                                           Puff big in its own window, following the canvas;
///                                                           out gets {"windowNumber": n}. "closeup":false closes it
extension Automation {
    func handleDemo(_ name: String, _ cmd: [String: Any]) -> Bool {
        switch name {
        case "demoStory":
            guard let story = cmd["name"] as? String else { return true }
            if app.mode != .orchestrator, story != "reset" { app.open(.orchestrator) }
            app.playStory(story, loop: cmd["loop"] as? Bool ?? false, autoAllow: cmd["autoAllow"] as? Bool ?? true)
        case "puff":
            if let m = cmd["mood"] as? String { MascotDemo.mood = m == "auto" ? nil : MascotDemo.mood(named: m) }
            if let on = cmd["closeup"] as? Bool {
                if on {
                    let scale = (cmd["scale"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 4
                    let w = MascotDemo.showCloseUp(graph: app.orch?.shown, scale: scale)
                    if let out = cmd["out"] as? String {
                        let data = (try? JSONSerialization.data(withJSONObject: ["windowNumber": w.windowNumber])) ?? Data()
                        try? data.write(to: URL(fileURLWithPath: out), options: .atomic)
                    }
                } else {
                    MascotDemo.hideCloseUp()
                }
            }
            if let t = cmd["trick"] {
                // Once the close-up (if any) is on screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MascotDemo.trick(t as? String) }
            }
        default:
            return false
        }
        return true
    }
}
#endif
