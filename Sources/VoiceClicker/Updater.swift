import AppKit
import os

private let log = Logger(subsystem: "com.codehex.VoiceClicker", category: "updates")

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// A release is a `vX.Y.Z` tag with a zipped `Voice Clicker.app` attached (the
/// Release workflow makes these). The new app is only installed if its
/// signature is pinned to our bundle ID, like the builds from
/// `scripts/build-app.sh`, so macOS keeps the permissions it already granted.
final class Updater {
    static let repo = "CodeHex/voice-clicker"

    struct Release {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, installing(String), failed(String)
    }

    private(set) var state = State.idle

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Whether the app can update itself: it's in an Applications folder we
    /// can write to, rather than a development build in the repo.
    static var canAutoInstall: Bool {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return (parent == "/Applications" || parent == NSHomeDirectory() + "/Applications")
            && FileManager.default.isWritableFile(atPath: parent)
    }

    /// The version the launch check last tried to install, so a failed
    /// install doesn't restart the app over and over.
    private var lastAutoInstall: String? {
        get { UserDefaults.standard.string(forKey: "lastAutoInstallVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "lastAutoInstallVersion") }
    }

    /// Checks for a newer release. Interactive checks ask before installing
    /// and say when there's nothing new; the launch check installs silently.
    func check(interactive: Bool) {
        guard state == .idle || isFailed else { return }
        state = .checking
        Task {
            do {
                let release = try await latestRelease()
                let newer = Self.compare(release.version, Self.currentVersion) == .orderedDescending
                log.info("Latest release \(release.version, privacy: .public), running \(Self.currentVersion, privacy: .public)")
                await MainActor.run {
                    state = .idle
                    if !newer {
                        if interactive { upToDateAlert() }
                    } else if !interactive {
                        guard Self.canAutoInstall, lastAutoInstall != release.version else { return }
                        lastAutoInstall = release.version
                        install(release)
                    } else if confirmInstall(release) {
                        install(release)
                    }
                }
            } catch {
                log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    state = .failed(error.localizedDescription)
                    if interactive { errorAlert("Couldn't check for updates", error) }
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - GitHub

    private func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError("No releases have been published yet.") }
        guard status == 200 else { throw UpdateError("GitHub answered with HTTP \(status).") }

        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let zip = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError("Release \(payload.tag_name) has no .zip attached.")
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, zipURL: zip.browser_download_url, pageURL: payload.html_url)
    }

    /// Compares dotted version numbers, so 1.10.0 is newer than 1.9.0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Install

    private func install(_ release: Release) {
        state = .installing(release.version)
        Task {
            do {
                let newApp = try await download(release)
                await MainActor.run { relaunch(into: newApp, version: release.version) }
            } catch {
                log.error("Update to \(release.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    state = .failed(error.localizedDescription)
                    errorAlert("Couldn't install Voice Clicker \(release.version)", error)
                }
            }
        }
    }

    /// Downloads and unzips the release, and checks it's really our app.
    private func download(_ release: Release) async throws -> URL {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateError("Voice Clicker can't replace itself in \(parent). Download it from the release page instead.")
        }
        let (zip, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceClickerUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", "-x", "-k", zip.path, folder.path)
        try? FileManager.default.removeItem(at: zip)

        guard let app = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download doesn't contain Voice Clicker.")
        }
        // Same check macOS makes before reusing permission grants.
        let requirement = "-R=identifier \"\(Bundle.main.bundleIdentifier ?? "")\""
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", requirement, app.path)
        return app
    }

    /// Hands over to a small script that swaps the app once we've quit, then opens it.
    private func relaunch(into newApp: URL, version: String) {
        let current = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        backup="$NEW.old"
        mv "$CURRENT" "$backup" || exit 1
        if mv "$NEW" "$CURRENT"; then rm -rf "$backup"; else mv "$backup" "$CURRENT"; fi
        xattr -dr com.apple.quarantine "$CURRENT" 2>/dev/null
        open "$CURRENT"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["CURRENT": current, "NEW": newApp.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            errorAlert("Couldn't install Voice Clicker \(version)", error)
            return
        }
        log.info("Installing \(version, privacy: .public) and relaunching")
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed (exit \(process.terminationStatus)).")
        }
    }

    // MARK: - Alerts

    private func confirmInstall(_ release: Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Voice Clicker \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Install it now? Voice Clicker restarts."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
        return false
    }

    private func upToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Voice Clicker \(Self.currentVersion) is the latest version."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func errorAlert(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
