import Foundation
import Network
import RelayProtocol
import Security
import os

private let log = Logger(subsystem: "com.codehex.VoiceClicker", category: "relay")

/// Receives Spotlight clicks over Wi-Fi from a Voice Clicker relay (the
/// Raspberry Pi in `relay/`).
///
/// The Mac listens on a TCP port and advertises it over Bonjour, and each
/// relay on the network connects to it. Clicks count only from a relay this
/// Mac has paired with, and only while that relay has picked this Mac.
final class RelayServer {
    static let serviceType = "_voiceclicker._tcp"

    var onButton: ((SpotlightButton, _ pressed: Bool) -> Void)?
    var onChange: (() -> Void)?
    /// Ask the person whether to pair, showing the code. Answer with `confirmPairing`.
    var onPairRequest: ((RelayLink, _ code: String) -> Void)?
    /// A pairing ended, so any question about it should close.
    var onPairingEnded: ((RelayLink, _ stored: Bool) -> Void)?

    let keys = KeychainRelayKeys()
    private(set) var links: [RelayLink] = []
    private(set) var lastError: String?
    private var listener: NWListener?
    private var keepAlive: Timer?

    var isRunning: Bool { listener != nil }

    /// The relay currently sending its clicks to this Mac.
    var activeLink: RelayLink? { links.first { $0.session.isAuthenticated && $0.session.isActive } }

    var status: String {
        if let lastError { return lastError }
        if let link = activeLink { return "\(link.name) is sending clicks here" }
        if let link = links.first(where: { $0.session.isAuthenticated }) {
            return "\(link.name) is sending clicks to another Mac"
        }
        if let link = links.first(where: { $0.session.relayID != nil }) {
            return "\(link.name) found, pair it from its screen"
        }
        return "Waiting for a relay"
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let listener = try NWListener(using: .tcp)
            var txt = NWTXTRecord()
            txt["id"] = Settings.shared.relayMacID
            txt["v"] = String(RelaySession.version)
            listener.service = NWListener.Service(name: Self.macName, type: Self.serviceType, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = "Wi-Fi Relay couldn't start: \(error.localizedDescription)"
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.ping() }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
        onChange?()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        keepAlive?.invalidate()
        keepAlive = nil
        for link in links { link.connection.cancel() }
        links.removeAll()
        lastError = nil
        onChange?()
    }

    func confirmPairing(_ link: RelayLink, accepted: Bool) {
        handle(link.session.confirmPairing(accepted), from: link)
    }

    /// Forgets a relay's key. It has to pair again before its clicks count.
    func forget(relayID: String) {
        keys.remove(relayID: relayID)
        for link in links where link.session.relayID == relayID { drop(link, reason: "forgotten") }
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            lastError = nil
            log.info("Listening on port \(self.listener?.port?.rawValue ?? 0)")
        case .failed(let error):
            lastError = "Wi-Fi Relay stopped: \(error.localizedDescription)"
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
        default:
            break
        }
        onChange?()
    }

    private func accept(_ connection: NWConnection) {
        let session = RelaySession(macID: Settings.shared.relayMacID, macName: Self.macName, keys: keys)
        let link = RelayLink(connection: connection, session: session)
        links.append(link)
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .failed, .cancelled: self.drop(link, reason: "connection closed")
            default: break
            }
        }
        connection.start(queue: .main)
        receive(on: link)
        log.info("Relay connected from \(String(describing: connection.endpoint), privacy: .public)")
    }

    private func receive(on link: RelayLink) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak link] data, _, done, error in
            guard let self, let link else { return }
            if let data {
                link.buffer.append(data)
                link.lastHeard = Date()
            }
            while let newline = link.buffer.firstIndex(of: 0x0A) {
                let line = link.buffer[link.buffer.startIndex..<newline]
                link.buffer.removeSubrange(link.buffer.startIndex...newline)
                guard let message = RelayWire.decode(line) else {
                    return self.drop(link, reason: "unreadable message")
                }
                self.handle(link.session.receive(message), from: link)
            }
            // A line never needs this much; anything longer isn't a relay.
            if link.buffer.count > 16_384 { return self.drop(link, reason: "message too long") }
            if done || error != nil { return self.drop(link, reason: "connection closed") }
            if self.links.contains(where: { $0 === link }) { self.receive(on: link) }
        }
    }

    private func handle(_ outputs: [RelayOutput], from link: RelayLink) {
        for output in outputs {
            switch output {
            case .send(let message):
                link.connection.send(content: RelayWire.encode(message), completion: .contentProcessed { _ in })
            case .button(let button, let down):
                onButton?(button == .next ? .next : .back, down)
            case .state(_, let spotlight, let battery):
                link.spotlightConnected = spotlight
                link.battery = battery
            case .askToPair(let code):
                onPairRequest?(link, code)
            case .pairingEnded(let stored):
                onPairingEnded?(link, stored)
            case .authenticated:
                log.info("Relay \(link.name, privacy: .public) authenticated")
            case .close(let reason):
                drop(link, reason: reason)
                return
            }
        }
        onChange?()
    }

    private func ping() {
        let stale = Date().addingTimeInterval(-35)
        for link in links {
            if link.lastHeard < stale {
                drop(link, reason: "no reply for 35 s")
            } else {
                link.connection.send(content: RelayWire.encode(["t": .string("ping")]), completion: .contentProcessed { _ in })
            }
        }
    }

    private func drop(_ link: RelayLink, reason: String) {
        guard links.contains(where: { $0 === link }) else { return }
        log.info("Relay \(link.name, privacy: .public) dropped: \(reason, privacy: .public)")
        links.removeAll { $0 === link }
        link.connection.cancel()
        onPairingEnded?(link, false)
        onChange?()
    }
}

/// One connection from a relay.
final class RelayLink {
    let connection: NWConnection
    let session: RelaySession
    var buffer = Data()
    var lastHeard = Date()
    var spotlightConnected = false
    var battery: Int?

    init(connection: NWConnection, session: RelaySession) {
        self.connection = connection
        self.session = session
    }

    var name: String { session.relayName ?? "Relay" }
}

/// The relay keys, in the login keychain.
final class KeychainRelayKeys: RelayKeyStore {
    private static let service = "com.codehex.VoiceClicker.relay"

    func key(forRelay id: String) -> Data? {
        var query = base(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func store(_ key: Data, forRelay id: String, name: String) {
        remove(relayID: id)
        var item = base(id)
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = "Voice Clicker relay \(name)"
        item[kSecAttrDescription as String] = name
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("Couldn't store the relay key: \(status)") }
    }

    func remove(relayID id: String) {
        SecItemDelete(base(id) as CFDictionary)
    }

    /// Every paired relay, as (id, name).
    var paired: [(id: String, name: String)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item[kSecAttrAccount as String] as? String else { return nil }
            return (id, item[kSecAttrDescription as String] as? String ?? id)
        }
    }

    private func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: id]
    }
}
