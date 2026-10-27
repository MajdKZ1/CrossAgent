#if DEBUG
import AppKit

/// Pointer commands, run by `SyntheticPointer`. Window coordinates, origin bottom left, like `click`.
///
///     {"cmd":"drag","x":200,"y":300,"toX":400,"toY":300,"steps":12,"mods":["option"]}
///     {"cmd":"scroll","x":550,"y":375,"dx":0,"dy":-40,"mods":["cmd"]}
///     {"cmd":"magnify","x":550,"y":375,"amount":0.25}
///     {"cmd":"dblclick","x":100,"y":100}
///     {"cmd":"tap","node":"w1"}
///     {"cmd":"drag","node":"w1","dx":-100,"dy":50}
///     {"cmd":"hittest","node":"w1","out":"/tmp/hit.txt"}
///
/// See `SyntheticPointer` for "node", "dx","dy" and "window".
extension Automation {
    func handlePointer(_ name: String, _ cmd: [String: Any]) -> Bool {
        SyntheticPointer.handle(name, cmd)
    }
}
#endif
