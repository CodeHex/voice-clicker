import Foundation
import IOKit.hid
import os

private let log = Logger(subsystem: "com.codehex.VoiceClicker", category: "hid")

// IOReturn codes are function-like C macros, which Swift does not import.
private let ioReturnError = IOReturn(bitPattern: 0xE00002BC)
private let ioReturnNotPermitted = IOReturn(bitPattern: 0xE00002E2)

/// Reads button presses straight from the Logitech Spotlight's HID interfaces.
///
/// When possible the device is opened with exclusive ("seize") access, so the
/// arrow keys it sends never reach the frontmost app. If that fails (for
/// example because another app holds it), the device is opened shared and the
/// app falls back to swallowing the matching key events with an event tap.
final class SpotlightHID {
    static let logitechVendorID = 0x046D
    /// 0xC53E: Spotlight USB receiver. 0xB503: Spotlight over Bluetooth.
    static let spotlightProductIDs: Set<Int> = [0xC53E, 0xB503]

    struct Device {
        let device: IOHIDDevice
        let name: String
        let seized: Bool
    }

    var onButton: ((HIDButton, Bool) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private(set) var devices: [Device] = []
    private(set) var isRunning = false
    private(set) var lastError: String?
    private var manager: IOHIDManager?
    private var seize = true

    var isConnected: Bool { !devices.isEmpty }
    var allSeized: Bool { devices.allSatisfy(\.seized) }

    func start(seize: Bool) {
        stop()
        self.seize = seize
        lastError = nil
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Match every Logitech device, then filter in the callback, so that
        // other Logitech keyboards and mice are never opened.
        let matching: [String: Any] = [kIOHIDVendorIDKey: Self.logitechVendorID]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<SpotlightHID>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<SpotlightHID>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        isRunning = true
    }

    func stop() {
        for d in devices {
            IOHIDDeviceUnscheduleFromRunLoop(d.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(d.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices.removeAll()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        isRunning = false
        onDevicesChanged?()
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let productID = intProperty(device, kIOHIDProductIDKey) ?? 0
        let product = stringProperty(device, kIOHIDProductKey) ?? "Logitech device"
        guard Self.spotlightProductIDs.contains(productID) || product.localizedCaseInsensitiveContains("spotlight") else {
            return
        }
        // The receiver exposes several interfaces (keyboard, mouse, vendor
        // HID++). Only take the ones that carry button presses, and leave the
        // HID++ interface alone so Logi Options+ can still talk to it.
        let isKeyboard = IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard))
        let isConsumer = IOHIDDeviceConformsTo(device, UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_ConsumerControl))
        guard isKeyboard || isConsumer else { return }
        guard !devices.contains(where: { CFEqual($0.device, device) }) else { return }

        var seized = false
        var result = ioReturnError
        if seize {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            seized = result == kIOReturnSuccess
            if !seized {
                log.warning("Exclusive open of \(product, privacy: .public) failed: \(String(format: "0x%08X", result), privacy: .public)")
            }
        }
        if !seized {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            lastError = result == ioReturnNotPermitted
                ? "Input Monitoring permission needed"
                : String(format: "Could not open %@ (0x%08X)", product, result)
            log.error("Open of \(product, privacy: .public) failed: \(String(format: "0x%08X", result), privacy: .public)")
            onDevicesChanged?()
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<SpotlightHID>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let transport = stringProperty(device, kIOHIDTransportKey) ?? "?"
        devices.append(Device(device: device, name: "\(product) (\(transport))", seized: seized))
        lastError = nil
        log.info("Opened \(product, privacy: .public) via \(transport, privacy: .public), exclusive: \(seized)")
        onDevicesChanged?()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let before = devices.count
        devices.removeAll { CFEqual($0.device, device) }
        if devices.count != before { onDevicesChanged?() }
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        switch page {
        case HIDButton.keyboardPage:
            // 0x00-0x03 are "no event"/error codes; 0xE0+ are modifiers.
            guard (0x04...0xDF).contains(usage) else { return }
        case HIDButton.consumerPage:
            guard usage != 0 else { return }
        default:
            return
        }
        onButton?(HIDButton(page: page, usage: usage), pressed)
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
