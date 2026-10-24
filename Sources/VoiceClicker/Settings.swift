import Foundation

final class Settings {
    static let shared = Settings()
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// The shortcut Next sends to start and stop dictation (⌘D by default).
    var dictationShortcut: KeyShortcut {
        get {
            defaults.data(forKey: "dictationShortcut")
                .flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) } ?? .commandD
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "dictationShortcut") }
    }

    /// Apps the clicker drives. With anything else in front, the clicker's
    /// keys pass through untouched so it still works as a presenter.
    var targetBundleIDs: [String] {
        get { defaults.stringArray(forKey: "targetBundleIDs") ?? [Self.claudeDesktopBundleID] }
        set { defaults.set(newValue, forKey: "targetBundleIDs") }
    }
}
