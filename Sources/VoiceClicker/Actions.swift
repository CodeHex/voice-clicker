import AppKit
import ApplicationServices
import IOKit.hid

enum Actions {
    /// Tag on every event we post, so our own event tap ignores it.
    static let eventMarker: Int64 = 0x5643_4C4B // "VCLK"
    static let returnKey: CGKeyCode = 36

    static var frontmostAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
    }

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
