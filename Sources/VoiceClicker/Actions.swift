import AppKit
import ApplicationServices
import IOKit.hid

enum Actions {
    /// Tag on every event we post, so our own event tap ignores it.
    static let eventMarker: Int64 = 0x5643_4C4B // "VCLK"
    static let returnKey: CGKeyCode = 36

    static func press(_ shortcut: KeyShortcut) {
        press(keyCode: CGKeyCode(shortcut.keyCode), flags: shortcut.flags)
    }

    static func press(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Drives macOS Dictation through the frontmost app's Edit menu
/// ("Start Dictation…" / "Stop Dictation"), via the Accessibility API.
/// This works in Terminal, iTerm2, VS Code, Ghostty and most other Mac apps
/// without needing any keyboard shortcut to be configured.
enum Dictation {
    enum Item {
        case start, stop

        var prefixes: [String] {
            switch self {
            case .start: return ["Start Dictation"]
            case .stop: return ["Stop Dictation"]
            }
        }
    }

    static var frontmostAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
    }

    static func menuItem(_ item: Item) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let menuBar: AXUIElement = element(axApp, kAXMenuBarAttribute) else { return nil }

        // Look in the Edit menu first, where macOS puts the dictation items.
        let all = children(menuBar)
        let barItems = all.filter { title($0) == "Edit" } + all.filter { title($0) != "Edit" }
        for barItem in barItems {
            for menu in children(barItem) {
                for entry in children(menu) {
                    guard let t = title(entry), item.prefixes.contains(where: { t.hasPrefix($0) }) else { continue }
                    if let enabled: Bool = value(entry, kAXEnabledAttribute), !enabled { continue }
                    return entry
                }
            }
        }
        return nil
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func value<T>(_ el: AXUIElement, _ attribute: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        value(el, kAXChildrenAttribute) ?? []
    }

    private static func title(_ el: AXUIElement) -> String? {
        value(el, kAXTitleAttribute)
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openBluetoothSettings() {
        open("x-apple.systempreferences:com.apple.BluetoothSettings")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
