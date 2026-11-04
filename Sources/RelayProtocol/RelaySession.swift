import CryptoKit
import Foundation

/// Where the Mac keeps the key it shares with each relay.
public protocol RelayKeyStore: AnyObject {
    func key(forRelay id: String) -> Data?
    func store(_ key: Data, forRelay id: String, name: String)
}

public enum RelayButton: String {
    case next, back
}

/// What the app should do after a message.
public enum RelayOutput: Equatable {
    case send([String: RelayValue])
    case button(RelayButton, down: Bool)
    case state(active: Bool, spotlight: Bool, battery: Int?)
    /// Show this code and ask whether to pair.
    case askToPair(code: String)
    /// The pairing ended, stored or not. Close the question if it's still up.
    case pairingEnded(stored: Bool)
    case authenticated
    case close(reason: String)
}

/// A JSON value in a relay message.
public enum RelayValue: Equatable {
    case string(String), int(Int), bool(Bool)

    var json: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .bool(let b): return b
        }
    }
}

/// The Mac's side of one connection from a relay, without any I/O. See
/// `relay/voiceclicker_relay/protocol.py` for the message flow.
public final class RelaySession {
    public static let version = 1

    public let macID: String
    public let macName: String
    public let nonce: String
    private let keys: RelayKeyStore

    public private(set) var relayID: String?
    public private(set) var relayName: String?
    public private(set) var isAuthenticated = false
    /// Whether the relay is sending its clicks to this Mac.
    public private(set) var isActive = false
    private var relayNonce = ""
    private var lastSeq = 0
    private var pairing: (key: Data, macConfirmed: Bool, relayConfirmed: Bool)?

    public init(macID: String, macName: String, keys: RelayKeyStore, nonce: String = RelayCrypto.newNonce()) {
        self.macID = macID
        self.macName = macName
        self.keys = keys
        self.nonce = nonce
    }

    public func receive(_ message: [String: Any]) -> [RelayOutput] {
        guard let kind = message["t"] as? String else { return [.close(reason: "not a message")] }
        switch kind {
        case "ping": return [.send(["t": .string("pong")])]
        case "pong": return []
        case "hello": return hello(message)
        default: break
        }
        guard let relayID else { return [.close(reason: "message before hello")] }
        switch kind {
        case "auth": return auth(message, relayID: relayID)
        case "pair": return pair(message)
        case "pair-ok":
            pairing?.relayConfirmed = true
            return storeIfConfirmed(relayID: relayID)
        case "pair-no":
            guard pairing != nil else { return [] }
            pairing = nil
            return [.pairingEnded(stored: false)]
        case "btn": return button(message)
        case "state": return state(message)
        default: return [.close(reason: "unknown message \(kind)")]
        }
    }

    /// The person's answer to `askToPair`.
    public func confirmPairing(_ accepted: Bool) -> [RelayOutput] {
        guard pairing != nil, let relayID else { return [] }
        guard accepted else {
            pairing = nil
            return [.send(["t": .string("pair-no")]), .pairingEnded(stored: false)]
        }
        pairing?.macConfirmed = true
        return [.send(["t": .string("pair-ok")])] + storeIfConfirmed(relayID: relayID)
    }

    private func hello(_ message: [String: Any]) -> [RelayOutput] {
        guard message["v"] as? Int == Self.version,
              let id = message["id"] as? String, let name = message["name"] as? String,
              let nonce = message["nonce"] as? String else {
            return [.close(reason: "unsupported relay")]
        }
        relayID = id
        relayName = name
        relayNonce = nonce
        return [.send([
            "t": .string("hello"), "v": .int(Self.version), "id": .string(macID), "name": .string(macName),
            "nonce": .string(self.nonce), "paired": .bool(keys.key(forRelay: id) != nil),
        ])]
    }

    private func auth(_ message: [String: Any], relayID: String) -> [RelayOutput] {
        guard let key = keys.key(forRelay: relayID), let proof = message["proof"] as? String,
              RelayCrypto.matches(proof, RelayCrypto.relayProof(key, macNonce: nonce)) else {
            return [.close(reason: "the relay's key doesn't match; pair again")]
        }
        isAuthenticated = true
        return [.send(["t": .string("auth"), "proof": .string(RelayCrypto.macProof(key, relayNonce: relayNonce))]),
                .authenticated]
    }

    private func pair(_ message: [String: Any]) -> [RelayOutput] {
        guard let encoded = message["pub"] as? String, let relayPublic = Data(base64Encoded: encoded),
              relayPublic.count == 32 else {
            return [.close(reason: "bad public key")]
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let macPublic = privateKey.publicKey.rawRepresentation
        guard let result = try? RelayCrypto.pairingResult(
            privateKey: privateKey, relayPublicKey: relayPublic, macPublicKey: macPublic) else {
            return [.close(reason: "bad public key")]
        }
        pairing = (result.key, false, false)
        return [.send(["t": .string("pair"), "pub": .string(macPublic.base64EncodedString())]),
                .askToPair(code: result.code)]
    }

    private func storeIfConfirmed(relayID: String) -> [RelayOutput] {
        guard let pairing, pairing.macConfirmed, pairing.relayConfirmed else { return [] }
        keys.store(pairing.key, forRelay: relayID, name: relayName ?? relayID)
        self.pairing = nil
        return [.pairingEnded(stored: true)]
    }

    /// The signed counter, if it's newer than the last one this connection accepted.
    private func verifiedSeq(_ message: [String: Any], signature: (Data, Int) -> String) -> Int? {
        guard isAuthenticated, let relayID, let key = keys.key(forRelay: relayID),
              let seq = message["seq"] as? Int, seq > lastSeq,
              let sig = message["sig"] as? String, RelayCrypto.matches(sig, signature(key, seq)) else {
            return nil
        }
        lastSeq = seq
        return seq
    }

    private func button(_ message: [String: Any]) -> [RelayOutput] {
        guard let name = message["b"] as? String, let button = RelayButton(rawValue: name),
              let down = message["down"] as? Bool,
              verifiedSeq(message, signature: {
                  RelayCrypto.buttonSignature($0, macNonce: nonce, seq: $1, button: name, down: down)
              }) != nil else {
            return [.close(reason: "a click failed its signature check")]
        }
        return [.button(button, down: down)]
    }

    private func state(_ message: [String: Any]) -> [RelayOutput] {
        guard let active = message["active"] as? Bool, let spotlight = message["spotlight"] as? Bool,
              let battery = message["battery"] as? Int,
              verifiedSeq(message, signature: {
                  RelayCrypto.stateSignature($0, macNonce: nonce, seq: $1, active: active,
                                             spotlight: spotlight, battery: battery)
              }) != nil else {
            return [.close(reason: "a status update failed its signature check")]
        }
        isActive = active
        return [.state(active: active, spotlight: spotlight, battery: battery < 0 ? nil : battery)]
    }
}

public enum RelayWire {
    /// One message as a line of JSON.
    public static func encode(_ message: [String: RelayValue]) -> Data {
        let object = message.mapValues(\.json)
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
