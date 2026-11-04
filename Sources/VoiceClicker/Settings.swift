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

    /// Whether to take clicks from a relay over Wi-Fi as well as from a
    /// Spotlight connected to this Mac. Off by default, because it asks for
    /// Local Network access.
    var relayEnabled: Bool {
        get { defaults.bool(forKey: "relayEnabled") }
        set { defaults.set(newValue, forKey: "relayEnabled") }
    }

    /// This Mac's id on the relay, made once.
    var relayMacID: String {
        if let id = defaults.string(forKey: "relayMacID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "relayMacID")
        return id
    }

    /// Apps the clicker drives. With anything else in front, the clicker's
    /// keys pass through untouched so it still works as a presenter.
    var targetBundleIDs: [String] {
        get { defaults.stringArray(forKey: "targetBundleIDs") ?? [Self.claudeDesktopBundleID] }
        set { defaults.set(newValue, forKey: "targetBundleIDs") }
    }
}
