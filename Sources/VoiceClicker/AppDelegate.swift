import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.codehex.VoiceClicker", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Learning {
        case none, voiceButton, submitButton, voiceKey
    }

    private enum Flash {
        case voice, submit
    }

    private let settings = Settings.shared
    private let hid = SpotlightHID()
    private let keyTap = KeyTap()
    private var statusItem: NSStatusItem!
    private var learning = Learning.none
    private var dictatingSince: Date?
    /// Claude Code ends a recording on its own after two minutes, so don't
    /// believe we're still dictating after that.
    private var dictating: Bool {
        get { dictatingSince.map { Date().timeIntervalSince($0) < 120 } ?? false }
        set { dictatingSince = newValue ? Date() : nil }
    }
    private var flash: Flash?
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hid.onButton = { [weak self] button, pressed in self?.hidButton(button, pressed: pressed) }
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

        let wantHID = settings.inputMode == .spotlight
        if wantHID && (!hid.isRunning || gainedInputMonitoring) {
            hid.start(seize: settings.exclusiveAccess)
        } else if !wantHID && hid.isRunning {
            hid.stop()
        }
        refreshIcon()
    }

    // MARK: - Input

    private func hidButton(_ button: HIDButton, pressed: Bool) {
        let isMapped = button == settings.voiceButton || button == settings.submitButton
        let learningButtons = learning == .voiceButton || learning == .submitButton
        let acting = learningButtons || (isMapped && settings.enabled && isTargetFrontmost)
        if let code = button.keyCode {
            if hid.allSeized {
                // Exclusive access hides the clicker's keys from the system, so
                // pass them on ourselves when another app is in front.
                if pressed && !acting { Actions.press(keyCode: code) }
            } else if pressed && acting {
                heldKeyCodes.insert(code)
                swallowUntil[code] = Date().addingTimeInterval(0.3)
            } else if !pressed, heldKeyCodes.remove(code) != nil {
                // Swallow the release of any press we swallowed.
                swallowUntil[code] = Date().addingTimeInterval(0.3)
            }
        }
        guard pressed else { return }

        if settings.inputMode == .spotlight, learnButton(button: button, key: nil) { return }
        guard settings.inputMode == .spotlight, learning == .none, settings.enabled, isTargetFrontmost else { return }
        if button == settings.voiceButton {
            triggerVoice()
        } else if button == settings.submitButton {
            triggerSubmit()
        }
    }

    /// Returns true to swallow the key event.
    private func keyEvent(_ code: CGKeyCode, flags: CGEventFlags, isDown: Bool, isRepeat: Bool) -> Bool {
        if heldKeyCodes.contains(code) { return true }
        if let until = swallowUntil[code], until > Date() { return true }

        let shortcut = KeyShortcut(keyCode: code, flags: flags)
        if learning == .voiceKey {
            if isDown && !isRepeat {
                settings.dictationShortcut = shortcut
                learning = .none
                lastAction = "Dictation shortcut set to \(shortcut.name)"
                refreshIcon()
            }
            return true
        }

        guard settings.inputMode == .keystrokes else { return false }
        if learning == .voiceButton || learning == .submitButton {
            if isDown && !isRepeat { _ = learnButton(button: nil, key: shortcut) }
            return true
        }
        guard settings.enabled, isTargetFrontmost else { return false }
        if shortcut == settings.voiceKey {
            if isDown && !isRepeat { triggerVoice() }
            return true
        }
        if shortcut == settings.submitKey {
            if isDown && !isRepeat { triggerSubmit() }
            return true
        }
        return false
    }

    /// Handles a press while learning which clicker button does what.
    private func learnButton(button: HIDButton?, key: KeyShortcut?) -> Bool {
        switch learning {
        case .voiceButton:
            if let button { settings.voiceButton = button }
            if let key { settings.voiceKey = key }
            learning = .submitButton
            lastAction = "Voice button set to \(button?.name ?? key?.name ?? "?")"
        case .submitButton:
            if let button {
                if button == settings.voiceButton { NSSound.beep(); return true }
                settings.submitButton = button
            }
            if let key {
                if key == settings.voiceKey { NSSound.beep(); return true }
                settings.submitKey = key
            }
            learning = .none
            lastAction = "Submit button set to \(button?.name ?? key?.name ?? "?")"
            startServices()
        case .none, .voiceKey:
            return false
        }
        refreshIcon()
        return true
    }

    // MARK: - Actions

    /// Whether the clicker should act: one of the target apps is in front.
    private var isTargetFrontmost: Bool {
        guard let id = Actions.frontmostBundleID else { return false }
        return settings.targetBundleIDs.contains(id)
    }

    /// Sends the dictation shortcut, which starts dictation or stops it.
    private func triggerVoice() {
        showFlash(.voice)
        let shortcut = settings.dictationShortcut
        Actions.press(shortcut)
        dictating.toggle()
        lastAction = "Sent \(shortcut.name) (\(dictating ? "start" : "stop")) to \(Actions.frontmostAppName)"
        refreshIcon()
    }

    /// Presses Enter, exactly like the key on the keyboard.
    private func triggerSubmit() {
        showFlash(.submit)
        dictating = false
        Actions.press(keyCode: Actions.returnKey)
        lastAction = "Sent Enter to \(Actions.frontmostAppName)"
        refreshIcon()
    }

    // MARK: - Status icon

    private var isReady: Bool {
        guard settings.enabled, Permissions.accessibility else { return false }
        switch settings.inputMode {
        case .spotlight: return hid.isConnected
        case .keystrokes: return keyTap.isRunning && settings.voiceKey != nil && settings.submitKey != nil
        }
    }

    private func showFlash(_ kind: Flash) {
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
        let symbol: String
        var tint: NSColor?
        switch (flash, learning) {
        case (.voice?, _):
            symbol = "mic.fill"
            tint = .systemOrange
        case (.submit?, _):
            symbol = "return"
            tint = .systemGreen
        case (nil, .voiceButton), (nil, .submitButton), (nil, .voiceKey):
            symbol = "hand.point.up.left.fill"
            tint = .systemBlue
        case (nil, .none):
            if !isReady {
                symbol = "mic.slash"
            } else if dictating {
                symbol = "mic.fill"
                tint = .systemRed
            } else {
                symbol = "mic"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice Clicker")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        let status = statusLine
        button.toolTip = "Voice Clicker: \(status)"
        if status != loggedStatus {
            loggedStatus = status
            log.info("Status: \(status, privacy: .public) (accessibility: \(Permissions.accessibility), input monitoring: \(Permissions.inputMonitoring))")
        }
    }

    private var statusLine: String {
        if !settings.enabled { return "Off" }
        switch learning {
        case .voiceButton: return "Press the clicker button for VOICE…"
        case .submitButton: return "Press the clicker button for SUBMIT…"
        case .voiceKey: return "Press the dictation shortcut…"
        case .none: break
        }
        if !Permissions.accessibility { return "Needs Accessibility permission" }
        switch settings.inputMode {
        case .spotlight:
            if !Permissions.inputMonitoring { return "Needs Input Monitoring permission" }
            if let device = hid.devices.first {
                return "On, \(device.name)\(hid.allSeized ? "" : ", shared access")"
            }
            return hid.lastError ?? "On, waiting for Spotlight (press a button to wake it)"
        case .keystrokes:
            if settings.voiceKey == nil || settings.submitKey == nil { return "Learn buttons to finish setup" }
            return "On, listening for keystrokes"
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(statusLine))
        menu.addItem(disabled("Last action: \(lastAction)"))
        menu.addItem(item(settings.enabled ? "Turn Off" : "Turn On", #selector(toggleEnabled)))
        menu.addItem(.separator())

        if !Permissions.accessibility {
            menu.addItem(item("Grant Accessibility…", #selector(grantAccessibility)))
        }
        if settings.inputMode == .spotlight && !Permissions.inputMonitoring {
            menu.addItem(item("Grant Input Monitoring…", #selector(grantInputMonitoring)))
        }

        let voiceName: String
        let submitName: String
        switch settings.inputMode {
        case .spotlight:
            voiceName = settings.voiceButton.name
            submitName = settings.submitButton.name
        case .keystrokes:
            voiceName = settings.voiceKey?.name ?? "not set"
            submitName = settings.submitKey?.name ?? "not set"
        }
        menu.addItem(disabled("Voice button: \(voiceName)"))
        menu.addItem(disabled("Submit button: \(submitName)"))
        if learning == .none {
            menu.addItem(item("Learn Buttons…", #selector(learnButtons)))
        } else {
            menu.addItem(item("Cancel Learning", #selector(cancelLearning)))
        }
        menu.addItem(.separator())

        let actions = NSMenu()
        actions.addItem(disabled("Next sends: \(settings.dictationShortcut.name)"))
        actions.addItem(item("Record Dictation Shortcut…", #selector(recordVoiceKey)))
        actions.addItem(item("Reset to ⌘D", #selector(resetVoiceKey)))
        menu.addItem(submenu("Button Actions", actions))

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
        menu.addItem(submenu("Apps", apps))

        let input = NSMenu()
        input.addItem(item("Spotlight Directly (Recommended)", #selector(useSpotlightInput), on: settings.inputMode == .spotlight))
        input.addItem(item("Keystrokes (Logi Options+ Remap)", #selector(useKeystrokeInput), on: settings.inputMode == .keystrokes))
        input.addItem(.separator())
        input.addItem(item("Exclusive Access to Spotlight", #selector(toggleExclusive), on: settings.exclusiveAccess))
        input.addItem(item("Open Bluetooth Settings…", #selector(openBluetooth)))
        menu.addItem(submenu("Clicker Input", input))

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Quit Voice Clicker", #selector(quit), key: "q"))
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

    @objc private func learnButtons() {
        learning = .voiceButton
        startServices()
    }

    @objc private func cancelLearning() {
        learning = .none
        startServices()
    }

    @objc private func recordVoiceKey() {
        learning = .voiceKey
        refreshIcon()
    }

    @objc private func resetVoiceKey() {
        settings.dictationShortcut = KeyShortcut(keyCode: 2, flags: .maskCommand)
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

    @objc private func useSpotlightInput() {
        settings.inputMode = .spotlight
        startServices()
    }

    @objc private func useKeystrokeInput() {
        settings.inputMode = .keystrokes
        startServices()
        if settings.voiceKey == nil || settings.submitKey == nil { learnButtons() }
    }

    @objc private func toggleExclusive() {
        settings.exclusiveAccess.toggle()
        if hid.isRunning { hid.start(seize: settings.exclusiveAccess) }
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
