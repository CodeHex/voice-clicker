import CoreGraphics
import Foundation

/// The two Spotlight buttons the app uses. Out of the box (no Logitech
/// software), Next sends Right Arrow and Back sends Left Arrow.
enum SpotlightButton {
    case next, back

    /// Maps a HID keyboard usage from the Spotlight to a button.
    init?(usage: UInt32) {
        switch usage {
        case 0x4F: self = .next
        case 0x50: self = .back
        default: return nil
        }
    }

    /// The virtual key code macOS produces for this button.
    var keyCode: CGKeyCode { self == .next ? 124 : 123 }
}

/// A key plus modifiers, as seen by (or sent to) the window server.
struct KeyShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt64

    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
    static let commandD = KeyShortcut(keyCode: 2, flags: .maskCommand)

    init(keyCode: CGKeyCode, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = flags.intersection(Self.relevantModifiers).rawValue
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    var name: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        36: "Return", 53: "Escape", 48: "Tab", 49: "Space",
        47: "Period", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        116: "Page Up", 121: "Page Down", 124: "Right Arrow", 123: "Left Arrow",
        125: "Down Arrow", 126: "Up Arrow",
    ]
}
