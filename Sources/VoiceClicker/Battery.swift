import Foundation
import IOKit
import IOKit.hid
import os

private let log = Logger(subsystem: "com.codehex.VoiceClicker", category: "battery")

struct BatteryStatus: Equatable {
    let percent: Int
    let charging: Bool
    /// Where the level came from, for the Advanced menu and the logs.
    let source: String
}

/// Reads the Spotlight's battery level.
///
/// macOS publishes a Bluetooth device's battery level as "BatteryPercent" in
/// the I/O Registry, so that is tried first. Otherwise the level is asked for
/// over Logitech's HID++ protocol on the clicker's vendor interface.
final class SpotlightBattery {
    var onChange: (() -> Void)?
    private(set) var status: BatteryStatus?

    /// Devices the keyboard side opened, checked for a registry level.
    private var registryDevices: [IOHIDDevice] = []
    private var hidpp: [HIDPPBattery] = []

    /// Whether the device has a Logitech HID++ interface.
    static func hasHIDPP(_ device: IOHIDDevice) -> Bool {
        // 0xFF43/0x0202 over Bluetooth LE, 0xFF00/0x0002 on the USB receiver.
        IOHIDDeviceConformsTo(device, 0xFF43, 0x0202) || IOHIDDeviceConformsTo(device, 0xFF00, 0x0002)
    }

    func attachRegistry(_ device: IOHIDDevice) {
        guard !registryDevices.contains(where: { CFEqual($0, device) }) else { return }
        registryDevices.append(device)
        refresh()
    }

    func attachHIDPP(_ device: IOHIDDevice, bluetooth: Bool) {
        guard !hidpp.contains(where: { CFEqual($0.device, device) }) else { return }
        let battery = HIDPPBattery(device: device, deviceIndex: bluetooth ? 0xFF : 0x01)
        guard battery.open() else { return }
        battery.onStatus = { [weak self] _ in self?.update() }
        hidpp.append(battery)
        battery.request()
    }

    func detach(_ device: IOHIDDevice) {
        registryDevices.removeAll { CFEqual($0, device) }
        hidpp.filter { CFEqual($0.device, device) }.forEach { $0.close() }
        hidpp.removeAll { CFEqual($0.device, device) }
        update()
    }

    func reset() {
        registryDevices.removeAll()
        hidpp.forEach { $0.close() }
        hidpp.removeAll()
        update()
    }

    /// Asks for a fresh level. Cheap enough to call every minute.
    func refresh() {
        hidpp.forEach { $0.request() }
        update()
    }

    private func update() {
        let new = registryStatus() ?? hidpp.lazy.compactMap(\.status).first
        guard new != status else { return }
        status = new
        if let new {
            log.info("Battery \(new.percent)%\(new.charging ? ", charging" : "", privacy: .public) from \(new.source, privacy: .public)")
        } else {
            log.info("Battery level unknown")
        }
        onChange?()
    }

    private func registryStatus() -> BatteryStatus? {
        for device in registryDevices {
            let service = IOHIDDeviceGetService(device)
            guard service != IO_OBJECT_NULL else { continue }
            // The property sits on the device's own node or near it.
            for options in [kIORegistryIterateRecursively, kIORegistryIterateRecursively | kIORegistryIterateParents] {
                if let percent = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "BatteryPercent" as CFString,
                                                                 kCFAllocatorDefault, IOOptionBits(options)) as? Int,
                   (0...100).contains(percent) {
                    return BatteryStatus(percent: percent, charging: false, source: "Bluetooth battery service")
                }
            }
        }
        return nil
    }
}

/// Talks HID++ 2.0 to one Spotlight interface, using the Unified Battery
/// feature (0x1004) if the clicker has it and Battery Status (0x1000) if not.
private final class HIDPPBattery {
    let device: IOHIDDevice
    let deviceIndex: UInt8
    var onStatus: ((BatteryStatus) -> Void)?
    private(set) var status: BatteryStatus?

    private static let longReport: UInt8 = 0x11
    private static let reportLength = 20
    /// Our software ID, so replies to us can be told from the device's own events.
    private static let softwareID: UInt8 = 0x0A
    private static let features: [UInt16] = [0x1004, 0x1000]

    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var isOpen = false
    /// The feature being looked up, an index into `features`.
    private var lookup = 0
    private var feature: (id: UInt16, index: UInt8)?
    private var unsupported = false
    /// When the pending feature lookup went out. Replies don't say which
    /// feature they answer, so only one lookup is in flight at a time.
    private var lookupSentAt: Date?

    init(device: IOHIDDevice, deviceIndex: UInt8) {
        self.device = device
        self.deviceIndex = deviceIndex
    }

    deinit { buffer.deallocate() }

    func open() -> Bool {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log.warning("Could not open the HID++ interface: \(String(format: "0x%08X", result), privacy: .public)")
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            Unmanaged<HIDPPBattery>.fromOpaque(context).takeUnretainedValue()
                .received(reportID: reportID, UnsafeBufferPointer(start: report, count: length))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        isOpen = true
        return true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func request() {
        guard isOpen, !unsupported else { return }
        if let feature {
            // Unified Battery: function 1, GetStatus. Battery Status: function 0.
            send(featureIndex: feature.index, function: feature.id == 0x1004 ? 1 : 0)
        } else {
            // Root feature (index 0), function 0: look up a feature's index.
            if let sent = lookupSentAt, Date().timeIntervalSince(sent) < 5 { return }
            lookupSentAt = Date()
            let id = Self.features[lookup]
            send(featureIndex: 0, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)])
        }
    }

    private func send(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = Self.longReport
        report[1] = deviceIndex
        report[2] = featureIndex
        report[3] = function << 4 | Self.softwareID
        for (i, p) in params.enumerated() { report[4 + i] = p }
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReport), report, report.count)
        if result != kIOReturnSuccess {
            log.warning("HID++ request failed: \(String(format: "0x%08X", result), privacy: .public)")
        }
    }

    private func received(reportID: UInt32, _ bytes: UnsafeBufferPointer<UInt8>) {
        // The buffer starts with the report ID.
        guard reportID == Self.longReport, bytes.count >= 7, bytes[0] == Self.longReport,
              bytes[1] == deviceIndex else { return }
        let featureIndex = bytes[2]
        let function = bytes[3] >> 4
        let softwareID = bytes[3] & 0x0F
        let params = Array(bytes[4...])

        if featureIndex == 0xFF || featureIndex == 0x8F {
            // An error, usually because the clicker is asleep. Try again on the next refresh.
            lookupSentAt = nil
            log.info("HID++ error \(params.count > 1 ? params[1] : 0) from the Spotlight")
            return
        }

        if featureIndex == 0, function == 0, softwareID == Self.softwareID, feature == nil, lookupSentAt != nil {
            lookupSentAt = nil
            let id = Self.features[lookup]
            if params[0] != 0 {
                feature = (id, params[0])
                log.info("Spotlight has HID++ feature \(String(format: "0x%04X", id), privacy: .public) at index \(params[0])")
                request()
            } else if lookup + 1 < Self.features.count {
                lookup += 1
                request()
            } else {
                unsupported = true
                log.info("Spotlight has no HID++ battery feature")
            }
            return
        }

        guard let feature, featureIndex == feature.index else { return }
        let percent: Int
        let charging: Bool
        if feature.id == 0x1004 {
            // A GetStatus reply (function 1) or a status event (software ID 0):
            // state of charge, level flags, charging status.
            guard function == 1 || softwareID == 0 else { return }
            percent = Int(params[0])
            charging = params[2] == 1 || params[2] == 2
        } else {
            // Discharge level, next level, status (0 means discharging).
            percent = Int(params[0])
            charging = params[2] != 0
        }
        guard (1...100).contains(percent) else { return }
        log.info("HID++ \(String(format: "0x%04X", feature.id), privacy: .public) reply: \(params.prefix(4).map { String($0) }.joined(separator: " "), privacy: .public)")
        let new = BatteryStatus(percent: percent, charging: charging,
                                source: String(format: "HID++ 0x%04X", feature.id))
        guard new != status else { return }
        status = new
        onStatus?(new)
    }
}
