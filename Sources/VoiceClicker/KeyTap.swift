import CoreGraphics
import Foundation

/// A session-wide keyboard event tap. The handler returns true to swallow an event.
///
/// Used to record shortcuts, to react to keystrokes in "Logi Options+" mode,
/// and to swallow Spotlight keys when the device could not be opened exclusively.
final class KeyTap {
    typealias Handler = (_ keyCode: CGKeyCode, _ flags: CGEventFlags, _ isDown: Bool, _ isRepeat: Bool) -> Bool

    var handler: Handler?
    private var tap: CFMachPort?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Never act on keys this app posted itself.
        if event.getIntegerValueField(.eventSourceUserData) == Actions.eventMarker {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if handler?(keyCode, event.flags, type == .keyDown, isRepeat) == true {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
