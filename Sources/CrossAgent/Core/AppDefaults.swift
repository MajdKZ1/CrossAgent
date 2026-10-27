import Foundation

/// The app's UserDefaults. Every read and write goes through here, so a demo run
/// (`DemoMode`) gets a domain of its own and never touches the real one.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if DemoMode.isOn, let demo = UserDefaults(suiteName: DemoMode.defaultsSuite) { return demo }
        #endif
        return .standard
    }()
}
