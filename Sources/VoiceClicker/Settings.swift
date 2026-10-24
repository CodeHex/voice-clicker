import Foundation

enum InputMode: String {
    /// Read the Spotlight directly over HID (default, no Logitech software needed).
    case spotlight
    /// React to keystrokes from any keyboard, e.g. ones Logi Options+ sends
    /// after you remap the Spotlight buttons there.
    case keystrokes
}

enum VoiceMethod: String {
    /// Press "Start Dictation" / "Stop Dictation" in the frontmost app's Edit menu.
    case dictationMenu
    /// Press a recorded keyboard shortcut (your Dictation shortcut, or one for
    /// a tool such as Superwhisper or Wispr Flow).
    case shortcut
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

    var voiceMethod: VoiceMethod {
        get { defaults.string(forKey: "voiceMethod").flatMap(VoiceMethod.init) ?? .dictationMenu }
        set { defaults.set(newValue.rawValue, forKey: "voiceMethod") }
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

    var voiceShortcut: KeyShortcut? {
        get { decode("voiceShortcut") }
        set { encode(newValue, "voiceShortcut") }
    }

    var stopDictationBeforeSubmit: Bool {
        get { defaults.object(forKey: "stopDictationBeforeSubmit") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stopDictationBeforeSubmit") }
    }

    /// Seconds to wait after stopping dictation before pressing Return, so the
    /// last words land in the prompt.
    var submitDelay: Double {
        get { defaults.object(forKey: "submitDelay") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "submitDelay") }
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
