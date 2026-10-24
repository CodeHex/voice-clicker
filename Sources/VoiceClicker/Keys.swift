import CoreGraphics
import Foundation

/// A button on the clicker, identified by the HID usage it reports.
struct HIDButton: Codable, Equatable {
    let page: UInt32
    let usage: UInt32

    static let keyboardPage: UInt32 = 0x07
    static let consumerPage: UInt32 = 0x0C

    // Out of the box (no Logitech software), Spotlight's Next button sends
    // Right Arrow and its Back button sends Left Arrow.
    static let spotlightNext = HIDButton(page: keyboardPage, usage: 0x4F)
    static let spotlightBack = HIDButton(page: keyboardPage, usage: 0x50)

    var name: String {
        if page == Self.keyboardPage, let entry = Self.keyboardUsages[usage] {
            return entry.name
        }
        if page == Self.keyboardPage {
            return String(format: "Key 0x%02X", usage)
        }
        if page == Self.consumerPage {
            return String(format: "Media key 0x%02X", usage)
        }
        return String(format: "Usage %02X:%02X", page, usage)
    }

    /// The macOS virtual key code the system produces for this button, if known.
    /// Used to swallow the key when the device could not be opened exclusively.
    var keyCode: CGKeyCode? {
        guard page == Self.keyboardPage else { return nil }
        return Self.keyboardUsages[usage]?.keyCode
    }

    private static let keyboardUsages: [UInt32: (name: String, keyCode: CGKeyCode)] = [
        0x04: ("A", 0), 0x05: ("B", 11), 0x28: ("Return", 36), 0x29: ("Escape", 53),
        0x2B: ("Tab", 48), 0x2C: ("Space", 49), 0x37: ("Period", 47),
        0x3A: ("F1", 122), 0x3B: ("F2", 120), 0x3C: ("F3", 99), 0x3D: ("F4", 118),
        0x3E: ("F5", 96), 0x3F: ("F6", 97), 0x40: ("F7", 98), 0x41: ("F8", 100),
        0x42: ("F9", 101), 0x43: ("F10", 109), 0x44: ("F11", 103), 0x45: ("F12", 111),
        0x4B: ("Page Up", 116), 0x4E: ("Page Down", 121),
        0x4F: ("Right Arrow", 124), 0x50: ("Left Arrow", 123),
        0x51: ("Down Arrow", 125), 0x52: ("Up Arrow", 126),
        0x68: ("F13", 105), 0x69: ("F14", 107), 0x6A: ("F15", 113), 0x6B: ("F16", 106),
        0x6C: ("F17", 64), 0x6D: ("F18", 79), 0x6E: ("F19", 80),
    ]
}

/// A key plus modifiers, as seen by (or sent to) the window server.
struct KeyShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt64

    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

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
