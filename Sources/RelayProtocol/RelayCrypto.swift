import CryptoKit
import Foundation

/// The relay protocol's key exchange and signatures. `relay/voiceclicker_relay/protocol.py`
/// is the other side; both check the same test vectors.
public enum RelayCrypto {
    /// The shared key and the six-digit code both screens show.
    public static func pairingResult(
        privateKey: Curve25519.KeyAgreement.PrivateKey, relayPublicKey: Data, macPublicKey: Data
    ) throws -> (key: Data, code: String) {
        let mine = privateKey.publicKey.rawRepresentation
        let peer = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: mine == relayPublicKey ? macPublicKey : relayPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let salt = relayPublicKey + macPublicKey
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("voiceclicker pair key".utf8), outputByteCount: 32)
        let codeBytes = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("voiceclicker pair code".utf8), outputByteCount: 4)
        let number = codeBytes.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        return (key.withUnsafeBytes { Data($0) }, String(format: "%06u", number % 1_000_000))
    }

    public static func hmac(_ key: Data, _ text: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))
        return Data(code).hex
    }

    public static func relayProof(_ key: Data, macNonce: String) -> String {
        hmac(key, "relay|\(macNonce)")
    }

    public static func macProof(_ key: Data, relayNonce: String) -> String {
        hmac(key, "mac|\(relayNonce)")
    }

    public static func buttonSignature(_ key: Data, macNonce: String, seq: Int, button: String, down: Bool) -> String {
        hmac(key, "btn|\(macNonce)|\(seq)|\(button)|\(down ? 1 : 0)")
    }

    public static func stateSignature(
        _ key: Data, macNonce: String, seq: Int, active: Bool, spotlight: Bool, battery: Int
    ) -> String {
        hmac(key, "state|\(macNonce)|\(seq)|\(active ? 1 : 0)|\(spotlight ? 1 : 0)|\(battery)")
    }

    /// Compares two signatures in time that doesn't depend on where they differ.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).hex
    }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
