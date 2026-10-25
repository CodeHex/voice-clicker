import AppKit
import CryptoKit
import os

private let log = Logger(subsystem: "com.codehex.VoiceClicker", category: "updates")

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// A release is a `vX.Y.Z` tag with `VoiceClicker.zip` attached, holding
/// `Voice Clicker.app` (the Release workflow makes these). Before installing,
/// the download must come from this repo's releases, match the SHA-256 GitHub
/// lists for the asset, and unzip to our app at the release's version with a
/// signature pinned to our bundle ID, so macOS keeps the permissions it
/// already granted.
///
/// Releases are signed ad-hoc, so the signature check only proves the bundle
/// ID, not who built it. What the update can be trusted for is that it came
/// from this repo's GitHub releases over HTTPS.
@MainActor
final class Updater {
    static let repo = "CodeHex/voice-clicker"
    static let assetName = "VoiceClicker.zip"
    static let appName = "Voice Clicker.app"

    struct Release {
        let version: String
        let zipURL: URL
        /// The asset's SHA-256, as GitHub reports it.
        let sha256: String
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, installing(String), failed(String)
    }

    private(set) var state = State.idle

    nonisolated static var currentVersion: String {
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
                let release = try await Self.latestRelease()
                let newer = Self.compare(release.version, Self.currentVersion) == .orderedDescending
                log.info("Latest release \(release.version, privacy: .public), running \(Self.currentVersion, privacy: .public)")
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
            } catch {
                log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                if interactive { errorAlert("Couldn't check for updates", error) }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - GitHub

    private nonisolated static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError("No releases have been published yet.") }
        guard status == 200 else { throw UpdateError("GitHub answered with HTTP \(status).") }

        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Payload: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let zip = payload.assets.first(where: { $0.name == assetName }) else {
            throw UpdateError("Release \(payload.tag_name) has no \(assetName) attached.")
        }
        // Only download from this repo's own release assets.
        guard zip.browser_download_url.absoluteString
            .hasPrefix("https://github.com/\(repo)/releases/download/") else {
            throw UpdateError("Release \(payload.tag_name) links to an unexpected download.")
        }
        guard let digest = zip.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError("Release \(payload.tag_name) has no checksum for \(assetName).")
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, zipURL: zip.browser_download_url,
                       sha256: String(digest.dropFirst("sha256:".count)).lowercased(), pageURL: payload.html_url)
    }

    /// Compares dotted version numbers, so 1.10.0 is newer than 1.9.0.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
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
                let newApp = try await Self.download(release)
                relaunch(into: newApp, version: release.version)
            } catch {
                log.error("Update to \(release.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                errorAlert("Couldn't install Voice Clicker \(release.version)", error)
            }
        }
    }

    /// Downloads and unzips the release, and checks it's really our app.
    /// Runs off the main thread, since unzipping and codesign block.
    private nonisolated static func download(_ release: Release) async throws -> URL {
        let files = FileManager.default
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
        guard files.isWritableFile(atPath: parent) else {
            throw UpdateError("Voice Clicker can't replace itself in \(parent). Download it from the release page instead.")
        }
        let (zip, response) = try await URLSession.shared.download(from: release.zipURL)
        defer { try? files.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let hash = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard hash == release.sha256 else {
            throw UpdateError("The download doesn't match the release's checksum.")
        }

        let folder = files.temporaryDirectory.appendingPathComponent("VoiceClickerUpdate-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/ditto", "-x", "-k", zip.path, folder.path)
            let app = folder.appendingPathComponent(appName)
            // A real folder, not a symlink pointing somewhere else.
            let isLink = (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? true
            guard !isLink, let bundle = Bundle(url: app),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download doesn't contain Voice Clicker.")
            }
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard version == release.version else {
                throw UpdateError("The download is version \(version ?? "unknown"), not \(release.version).")
            }
            // Same check macOS makes before reusing permission grants.
            let requirement = "-R=identifier \"\(Bundle.main.bundleIdentifier ?? "")\""
            try run("/usr/bin/codesign", "--verify", "--deep", "--strict", requirement, app.path)
            return app
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    /// Hands over to a small script that swaps the app once we've quit, then opens it.
    private func relaunch(into newApp: URL, version: String) {
        let current = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        backup="$NEW.old"
        mv "$CURRENT" "$backup" || exit 1
        if mv "$NEW" "$CURRENT"; then rm -rf "$backup"; else mv "$backup" "$CURRENT"; fi
        rm -rf "$(dirname "$NEW")"
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

    private nonisolated static func run(_ tool: String, _ arguments: String...) throws {
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
