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

    /// The key bound to `voice:pushToTalk` in Claude Code (Space unless rebound).
    /// With `/voice tap`, one press starts recording and the next stops it.
    var claudeVoiceKey: KeyShortcut {
        get { decode("claudeVoiceKey") ?? KeyShortcut(keyCode: 49, flags: []) }
        set { encode(newValue, "claudeVoiceKey") }
    }

    var stopRecordingBeforeSubmit: Bool {
        get { defaults.object(forKey: "stopRecordingBeforeSubmit") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stopRecordingBeforeSubmit") }
    }

    /// Seconds to wait after stopping a recording before pressing Return, so
    /// the transcript lands in the prompt.
    var submitDelay: Double {
        get { defaults.object(forKey: "submitDelay") as? Double ?? 1.0 }
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
