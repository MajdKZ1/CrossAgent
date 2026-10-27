import AppKit
import CoreServices
import Observation

/// The current theme's colours, parsed once per switch. Palette and Theme read from
/// here. It is @Observable, so any SwiftUI body that reads a Palette colour is tracked
/// and redraws on a switch without losing its state.
@Observable
final class ThemeTokens {
    static let shared = ThemeTokens()

    private(set) var resolved = ResolvedTheme(AppTheme.fallback)

    func update(_ theme: AppTheme) {
        guard theme != resolved.theme else { return }
        resolved = ResolvedTheme(theme)
    }
}

/// An AppTheme with every colour parsed. Optional tokens are filled in here.
struct ResolvedTheme {
    let theme: AppTheme
    let window, surface, raised, border, hairline: NSColor
    let text, muted, faint: NSColor
    let accent, success, warning, danger, broadcast, synced: NSColor
    let chip, chipHover: NSColor
    let background, foreground, cursor, selection, selectionForeground: NSColor
    let ansi: [NSColor]
    let mascotBody, mascotEyes: NSColor
    let hosts: [String: NSColor]

    init(_ t: AppTheme) {
        theme = t
        let c = { (hex: String) in NSColor(hex: hex) }
        window = c(t.ui.window); surface = c(t.ui.surface); raised = c(t.ui.raised)
        border = c(t.ui.border); hairline = c(t.ui.hairline)
        text = c(t.ui.text); muted = c(t.ui.muted); faint = c(t.ui.faint)
        accent = c(t.ui.accent); success = c(t.ui.success); warning = c(t.ui.warning)
        danger = c(t.ui.danger); broadcast = c(t.ui.broadcast)
        synced = c(t.ui.synced ?? t.ui.success)
        chip = t.ui.chip.map(c) ?? c(t.ui.text).withAlphaComponent(0.04)
        chipHover = t.ui.chipHover.map(c) ?? c(t.ui.text).withAlphaComponent(0.08)
        background = c(t.terminal.background); foreground = c(t.terminal.foreground)
        cursor = c(t.terminal.cursor); selection = c(t.terminal.selection)
        selectionForeground = t.terminal.selectionForeground.map(c) ?? .black
        ansi = t.terminal.ansi.map(c)
        mascotBody = c(t.mascot.body); mascotEyes = c(t.mascot.eyes)
        hosts = (t.hosts ?? [:]).mapValues(c)
    }
}

/// Built in themes from the app's resources plus the user's own from
/// ~/.config/crossagent/themes/*.json, watched so edits apply live.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let defaultsKey = "theme.v1"
    static let defaultName = "Default"

    @Published private(set) var current: AppTheme
    /// Built ins first, then user themes by name. A user theme with a built in's name replaces it.
    @Published private(set) var all: [AppTheme]
    /// One line per user theme file that could not be loaded, ready for a toast.
    @Published private(set) var problems: [String] = []

    /// The name the user picked, even if that theme is gone right now.
    private var selected: String
    private var builtIns: [AppTheme]
    private var stream: FSEventStreamRef?
    private var reloadPending = false

    nonisolated static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/crossagent/themes", isDirectory: true)
    }

    init(builtIns: [AppTheme]? = nil, userFolder: URL? = ThemeStore.userFolder, watch: Bool = true) {
        let base = builtIns ?? Self.loadBuiltIns()
        self.builtIns = base
        selected = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? Self.defaultName
        current = base.first ?? .fallback
        all = base
        folder = userFolder
        ThemeTokens.shared.update(current)
        reload()
        if watch { startWatching() }
    }

    private let folder: URL?

    func select(name: String) {
        selected = name
        UserDefaults.standard.set(name, forKey: Self.defaultsKey)
        reload()
    }

    /// Rereads the user folder and reapplies the selection if anything changed.
    func reload() {
        var themes = builtIns
        var found: [String] = []
        if let folder {
            let loaded = Self.loadUserThemes(in: folder, base: builtIns.first ?? .fallback)
            for theme in loaded.themes {
                if let i = themes.firstIndex(where: { $0.name == theme.name }) { themes[i] = theme } else { themes.append(theme) }
            }
            found = loaded.problems
        }
        if themes != all { all = themes }
        if found != problems { problems = found }
        let next = themes.first { $0.name == selected } ?? themes.first { $0.name == Self.defaultName } ?? themes.first ?? .fallback
        guard next != current else { return }
        let oldWindow = Theme.window
        current = next
        ThemeTokens.shared.update(next)
        Theme.applyToAll(replacingWindow: oldWindow)
        NotificationCenter.default.post(name: .crossAgentThemeChanged, object: next)
    }

    /// Creates the user themes folder if needed and shows it in Finder.
    static func revealFolder() {
        let url = userFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Loading

    /// The bundled theme files, Default first. Same lookup as the app icon; never Bundle.module.
    nonisolated static func loadBuiltIns() -> [AppTheme] {
        var bundles = [Bundle.main]
        let name = "CrossAgent_CrossAgent.bundle"
        if let exe = Bundle.main.executableURL, let b = Bundle(url: exe.deletingLastPathComponent().appendingPathComponent(name)) {
            bundles.append(b)
        }
        if let res = Bundle.main.resourceURL, let b = Bundle(url: res.appendingPathComponent(name)) { bundles.append(b) }
        let themes = ["default", "mono"].compactMap { file -> AppTheme? in
            let url = bundles.lazy.compactMap { $0.url(forResource: file, withExtension: "json", subdirectory: "Themes") }.first
            return url.flatMap { try? decode(Data(contentsOf: $0), base: nil) }
        }
        return themes.isEmpty ? [.fallback] : themes
    }

    /// Every *.json in the folder, sorted by file name. Missing tokens come from `base`,
    /// so a user theme can override just a few colours. Bad files are skipped.
    nonisolated static func loadUserThemes(in folder: URL, base: AppTheme) -> (themes: [AppTheme], problems: [String]) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var themes: [AppTheme] = []
        var problems: [String] = []
        for file in files {
            do {
                var theme = try decode(Data(contentsOf: file), base: base,
                                       fallbackName: file.deletingPathExtension().lastPathComponent)
                theme.name = theme.name.trimmingCharacters(in: .whitespaces)
                themes.removeAll { $0.name == theme.name }
                themes.append(theme)
            } catch {
                problems.append("Theme \(file.lastPathComponent): \(describe(error))")
            }
        }
        return (themes, problems)
    }

    struct Invalid: Error { let reason: String }

    /// Decodes and validates a theme. With a `base`, the JSON is merged over it first.
    nonisolated static func decode(_ data: Data, base: AppTheme?, fallbackName: String? = nil) throws -> AppTheme {
        var object = try JSONSerialization.jsonObject(with: data)
        guard var dict = object as? [String: Any] else { throw Invalid(reason: "not a JSON object") }
        if dict["name"] == nil, let fallbackName { dict["name"] = fallbackName }
        if let base, let baseDict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] {
            var under = baseDict
            under["hosts"] = nil
            object = merge(under, dict)
        } else {
            object = dict
        }
        let theme = try JSONDecoder().decode(AppTheme.self, from: JSONSerialization.data(withJSONObject: object))
        try validate(theme)
        return theme
    }

    nonisolated static func validate(_ t: AppTheme) throws {
        if t.name.trimmingCharacters(in: .whitespaces).isEmpty { throw Invalid(reason: "name is empty") }
        if t.terminal.ansi.count != 16 { throw Invalid(reason: "ansi needs 16 colours, found \(t.terminal.ansi.count)") }
        let u = t.ui
        let named: [(String, String?)] = [
            ("window", u.window), ("surface", u.surface), ("raised", u.raised), ("border", u.border),
            ("hairline", u.hairline), ("text", u.text), ("muted", u.muted), ("faint", u.faint),
            ("accent", u.accent), ("success", u.success), ("warning", u.warning), ("danger", u.danger),
            ("broadcast", u.broadcast), ("synced", u.synced), ("chip", u.chip), ("chipHover", u.chipHover),
            ("terminal.background", t.terminal.background), ("terminal.foreground", t.terminal.foreground),
            ("terminal.cursor", t.terminal.cursor), ("terminal.selection", t.terminal.selection),
            ("terminal.selectionForeground", t.terminal.selectionForeground),
            ("mascot.body", t.mascot.body), ("mascot.eyes", t.mascot.eyes),
        ] + t.terminal.ansi.enumerated().map { ("ansi[\($0.offset)]", $0.element) }
            + (t.hosts ?? [:]).sorted { $0.key < $1.key }.map { ("hosts.\($0.key)", $0.value) }
        for (key, value) in named {
            if let value, !isHex(value) { throw Invalid(reason: "\(key) \"\(value)\" is not #rrggbb or #rrggbbaa") }
        }
    }

    nonisolated static func isHex(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let digits = s.dropFirst()
        return (digits.count == 6 || digits.count == 8) && digits.allSatisfy(\.isHexDigit)
    }

    nonisolated private static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let a = base[k] as? [String: Any], let b = v as? [String: Any] { out[k] = merge(a, b) } else { out[k] = v }
        }
        return out
    }

    nonisolated private static func describe(_ error: Error) -> String {
        switch error {
        case let e as Invalid: return e.reason
        case DecodingError.keyNotFound(let key, let ctx):
            return "missing \((ctx.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return "wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case is DecodingError: return "not a valid theme"
        default: return "not valid JSON"
        }
    }

    // MARK: Watching

    /// FSEvents on the nearest existing folder above the themes folder, so creating the
    /// folder, adding a file or saving one in place all trigger a reload.
    private func startWatching() {
        guard let folder else { return }
        var watched = folder
        while !FileManager.default.fileExists(atPath: watched.path), watched.pathComponents.count > 1 {
            watched.deleteLastPathComponent()
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            guard list.prefix(count).contains(where: { $0.contains("/themes") }) else { return }
            let store = Unmanaged<ThemeStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.scheduleReload() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [watched.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    /// Editors often save in a few steps, so wait a beat and reload once.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                self?.reload()
            }
        }
    }
}

extension AppTheme {
    /// Used only if the bundled theme files are missing. Matches default.json.
    static let fallback = AppTheme(
        name: "Default",
        ui: UI(window: "#0b0c0f", surface: "#0f1115", raised: "#14171c", border: "#ffffff12", hairline: "#ffffff0d",
               text: "#d7dae0", muted: "#8a909c", faint: "#5b616c", accent: "#6ea8fe", success: "#5fd39a",
               warning: "#f5b041", danger: "#f07178", broadcast: "#ff9f6e", synced: "#8fd694",
               chip: "#ffffff0a", chipHover: "#ffffff14"),
        terminal: Terminal(background: "#0f1115", foreground: "#d7dae0", cursor: "#9aa4b2", selection: "#00a6b2",
                           selectionForeground: "#000000",
                           ansi: ["#000000", "#c23621", "#25bc24", "#adad27", "#492ee1", "#d338d3", "#33bbc8", "#cbcccd",
                                  "#818383", "#fc391f", "#31e722", "#eaec23", "#5833ff", "#f935f8", "#14f0f0", "#e9ebeb"]),
        mascot: Mascot(body: "#b3dcff", eyes: "#0b1218"),
        hosts: nil)
}
