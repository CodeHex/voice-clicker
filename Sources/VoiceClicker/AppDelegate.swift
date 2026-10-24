import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.codehex.VoiceClicker", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let hid = SpotlightHID()
    private let keyTap = KeyTap()
    private var statusItem: NSStatusItem!
    /// True while waiting for the user to press a new dictation shortcut.
    private var recordingShortcut = false
    private var dictatingSince: Date?
    /// The app only knows what it sent, so stop showing the dictating dot
    /// after two minutes in case dictation ended on its own.
    private var dictating: Bool {
        get { dictatingSince.map { Date().timeIntervalSince($0) < 120 } ?? false }
        set { dictatingSince = newValue ? Date() : nil }
    }
    private var flash: SpotlightButton?
    private var flashGeneration = 0
    private var lastAction = "None yet"
    private var hadInputMonitoring = Permissions.inputMonitoring
    private var loggedStatus = ""

    // When the Spotlight can't be opened exclusively, its keys also reach the
    // system, so we swallow them in the event tap while (or just after) the
    // HID callback reports the button.
    private var heldKeyCodes: Set<CGKeyCode> = []
    private var swallowUntil: [CGKeyCode: Date] = [:]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A fixed width, so swapping icons never makes the menu bar relayout.
        statusItem = NSStatusBar.system.statusItem(withLength: Self.iconSize.width + 6)
        // Remember where the icon was ⌘-dragged to in the menu bar.
        statusItem.autosaveName = "VoiceClicker"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hid.onButton = { [weak self] button, pressed, seized in
            self?.hidButton(button, pressed: pressed, seized: seized)
        }
        hid.onDevicesChanged = { [weak self] in self?.refreshIcon() }
        keyTap.handler = { [weak self] code, flags, isDown, isRepeat in
            self?.keyEvent(code, flags: flags, isDown: isDown, isRepeat: isRepeat) ?? false
        }

        if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
        if !Permissions.accessibility { Permissions.requestAccessibility() }

        startServices()
        // Permissions are granted in System Settings while we run; pick them up.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.startServices()
        }
        refreshIcon()
    }

    private func startServices() {
        if Permissions.accessibility { keyTap.start() }

        let inputMonitoring = Permissions.inputMonitoring
        let gainedInputMonitoring = inputMonitoring && !hadInputMonitoring
        hadInputMonitoring = inputMonitoring

        if !hid.isRunning || gainedInputMonitoring { hid.start() }
        refreshIcon()
    }

    // MARK: - Input

    private func hidButton(_ button: SpotlightButton, pressed: Bool, seized: Bool) {
        let acting = settings.enabled && isTargetFrontmost
        let code = button.keyCode
        if seized {
            // Exclusive access hides the clicker's keys from the system, so
            // pass them on ourselves when the clicker isn't acting.
            if pressed && !acting { Actions.press(keyCode: code) }
        } else if pressed && acting {
            heldKeyCodes.insert(code)
            swallowUntil[code] = Date().addingTimeInterval(0.3)
        } else if !pressed, heldKeyCodes.remove(code) != nil {
            // Swallow the release of any press we swallowed.
            swallowUntil[code] = Date().addingTimeInterval(0.3)
        }
        guard pressed, acting else { return }
        switch button {
        case .next: triggerVoice()
        case .back: triggerSubmit()
        }
    }

    /// Returns true to swallow the key event.
    private func keyEvent(_ code: CGKeyCode, flags: CGEventFlags, isDown: Bool, isRepeat: Bool) -> Bool {
        if heldKeyCodes.contains(code) { return true }
        if let until = swallowUntil[code], until > Date() { return true }

        if recordingShortcut {
            if isDown && !isRepeat {
                let shortcut = KeyShortcut(keyCode: code, flags: flags)
                settings.dictationShortcut = shortcut
                recordingShortcut = false
                lastAction = "Dictation shortcut set to \(shortcut.name)"
                refreshIcon()
            }
            return true
        }
        return false
    }

    // MARK: - Actions

    /// Whether the clicker should act: one of the target apps is in front.
    private var isTargetFrontmost: Bool {
        guard let id = Actions.frontmostBundleID else { return false }
        return settings.targetBundleIDs.contains(id)
    }

    /// Sends the dictation shortcut, which starts dictation or stops it.
    private func triggerVoice() {
        let shortcut = settings.dictationShortcut
        Actions.press(shortcut)
        dictating.toggle()
        lastAction = "Sent \(shortcut.name) (\(dictating ? "start" : "stop")) to \(Actions.frontmostAppName)"
        refreshIcon()
    }

    /// Presses Enter, exactly like the key on the keyboard.
    private func triggerSubmit() {
        showFlash(.back)
        dictating = false
        Actions.press(keyCode: Actions.returnKey)
        lastAction = "Sent Enter to \(Actions.frontmostAppName)"
        refreshIcon()
    }

    // MARK: - Status icon

    private var isReady: Bool {
        settings.enabled && Permissions.accessibility && hid.isConnected
    }

    private func showFlash(_ kind: SpotlightButton) {
        flash = kind
        flashGeneration += 1
        let generation = flashGeneration
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.flash = nil
            self.refreshIcon()
        }
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        var symbol = "av.remote"
        var tint: NSColor?
        var listeningDot = false
        switch flash {
        case .next?:
            listeningDot = dictating
        case .back?:
            symbol = "return"
            tint = .systemGreen
        case nil where recordingShortcut:
            symbol = "hand.point.up.left.fill"
            tint = .systemBlue
        case nil:
            listeningDot = isReady && dictating
        }
        button.image = Self.icon(symbol, listeningDot: listeningDot)
        button.contentTintColor = tint
        // Dimmed when off, disconnected or missing a permission.
        button.appearsDisabled = !isReady && flash == nil && !recordingShortcut
        let status = statusLine
        button.toolTip = "Voice Clicker: \(status)"
        if status != loggedStatus {
            loggedStatus = status
            log.info("Status: \(status, privacy: .public) (accessibility: \(Permissions.accessibility), input monitoring: \(Permissions.inputMonitoring))")
        }
    }

    private static let iconSize = NSSize(width: 22, height: 18)

    /// The menu bar image, with a small red dot while dictating. Every state
    /// is drawn on the same canvas so the icon never changes size.
    private static func icon(_ symbol: String, listeningDot: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = (NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice Clicker")
            ?? NSImage(systemSymbolName: "av.remote", accessibilityDescription: "Voice Clicker"))?
            .withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let glyphRect = NSRect(x: (rect.width - base.size.width) / 2, y: (rect.height - base.size.height) / 2,
                                   width: base.size.width, height: base.size.height)
            guard listeningDot else {
                base.draw(in: glyphRect)
                return true
            }
            // A template image can't carry colour, so tint the glyph to the
            // menu bar's text colour ourselves and add the red dot.
            let glyph = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: glyphRect)
            let d: CGFloat = 7
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width - d, y: rect.height - d, width: d, height: d)).fill()
            return true
        }
        image.isTemplate = !listeningDot
        image.accessibilityDescription = "Voice Clicker"
        return image
    }

    private var statusLine: String {
        if !settings.enabled { return "Off" }
        if recordingShortcut { return "Press the dictation shortcut…" }
        if !Permissions.accessibility { return "Needs Accessibility permission" }
        if !Permissions.inputMonitoring { return "Needs Input Monitoring permission" }
        if let device = hid.devices.first {
            return "On, \(device.name)\(hid.allSeized ? "" : ", shared access")"
        }
        return hid.lastError ?? "On, waiting for Spotlight (press a button to wake it)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(isReady ? "Voice Clicker is running" : "Voice Clicker: \(statusLine)"))
        if !Permissions.accessibility {
            menu.addItem(item("Grant Accessibility…", #selector(grantAccessibility)))
        }
        if !Permissions.inputMonitoring {
            menu.addItem(item("Grant Input Monitoring…", #selector(grantInputMonitoring)))
        }
        if recordingShortcut {
            menu.addItem(item("Cancel Recording", #selector(cancelRecording)))
        }
        menu.addItem(.separator())
        menu.addItem(item(settings.enabled ? "Turn Off" : "Turn On", #selector(toggleEnabled)))

        // Everything else stays out of the way unless Option is held.
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(submenu("Advanced", advancedMenu()))
        }

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func advancedMenu() -> NSMenu {
        let advanced = NSMenu()
        advanced.addItem(disabled(statusLine))
        advanced.addItem(disabled("Last action: \(lastAction)"))
        advanced.addItem(.separator())

        let shortcut = NSMenu()
        shortcut.addItem(disabled("Next sends: \(settings.dictationShortcut.name)"))
        shortcut.addItem(item("Record Dictation Shortcut…", #selector(recordShortcut)))
        shortcut.addItem(item("Reset to ⌘D", #selector(resetShortcut)))
        advanced.addItem(submenu("Dictation Shortcut", shortcut))

        let apps = NSMenu()
        apps.addItem(disabled("Only active in:"))
        for id in settings.targetBundleIDs {
            let i = item(appName(for: id), #selector(removeTargetApp(_:)), on: true)
            i.representedObject = id
            i.toolTip = "\(id). Click to remove."
            apps.addItem(i)
        }
        apps.addItem(.separator())
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier,
           id != Bundle.main.bundleIdentifier, !settings.targetBundleIDs.contains(id) {
            let i = item("Add \(front.localizedName ?? id)", #selector(addTargetApp(_:)))
            i.representedObject = id
            apps.addItem(i)
        }
        apps.addItem(item("Reset to Claude Desktop", #selector(resetTargetApps)))
        advanced.addItem(submenu("Apps", apps))
        advanced.addItem(item("Open Bluetooth Settings…", #selector(openBluetooth)))
        return advanced
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        refreshIcon()
    }

    @objc private func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func grantInputMonitoring() {
        Permissions.requestInputMonitoring()
        Permissions.openInputMonitoringSettings()
    }

    @objc private func recordShortcut() {
        recordingShortcut = true
        refreshIcon()
    }

    @objc private func cancelRecording() {
        recordingShortcut = false
        refreshIcon()
    }

    @objc private func resetShortcut() {
        settings.dictationShortcut = .commandD
    }

    @objc private func addTargetApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.targetBundleIDs.append(id)
    }

    @objc private func removeTargetApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.targetBundleIDs.removeAll { $0 == id }
    }

    @objc private func resetTargetApps() {
        settings.targetBundleIDs = [Settings.claudeDesktopBundleID]
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    @objc private func openBluetooth() {
        Permissions.openBluetoothSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastAction = "Launch at Login failed: \(error.localizedDescription)"
        }
    }

    @objc private func quit() {
        hid.stop()
        NSApp.terminate(nil)
    }
}
