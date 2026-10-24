import CoreGraphics
import Foundation

enum InputMode: String {
    /// Read the Spotlight directly over HID (default, no Logitech software needed).
    case spotlight
    /// React to keystrokes from any keyboard, e.g. ones Logi Options+ sends
    /// after you remap the Spotlight buttons there.
    case keystrokes
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var inputMode: InputMode {
        get { defaults.string(forKey: "inputMode").flatMap(InputMode.init) ?? .spotlight }
        set { defaults.set(newValue.rawValue, forKey: "inputMode") }
    }

    var voiceButton: HIDButton {
        get { decode("voiceButton") ?? .spotlightNext }
        set { encode(newValue, "voiceButton") }
    }

    var submitButton: HIDButton {
        get { decode("submitButton") ?? .spotlightBack }
        set { encode(newValue, "submitButton") }
    }

    var voiceKey: KeyShortcut? {
        get { decode("voiceKey") }
        set { encode(newValue, "voiceKey") }
    }

    var submitKey: KeyShortcut? {
        get { decode("submitKey") }
        set { encode(newValue, "submitKey") }
    }

    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// The shortcut Next sends to start and stop dictation (⌘D by default).
    var dictationShortcut: KeyShortcut {
        get { decode("dictationShortcut") ?? KeyShortcut(keyCode: 2, flags: .maskCommand) }
        set { encode(newValue, "dictationShortcut") }
    }

    /// Apps the clicker drives. With anything else in front, the clicker's
    /// keys pass through untouched so it still works as a presenter.
    var targetBundleIDs: [String] {
        get { defaults.stringArray(forKey: "targetBundleIDs") ?? [Self.claudeDesktopBundleID] }
        set { defaults.set(newValue, forKey: "targetBundleIDs") }
    }

    var exclusiveAccess: Bool {
        get { defaults.object(forKey: "exclusiveAccess") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "exclusiveAccess") }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
