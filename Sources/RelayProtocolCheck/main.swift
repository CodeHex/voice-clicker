// Checks the relay protocol: `swift run relay-protocol-check`.
//
// The Command Line Tools ship without XCTest, so this runs as a plain
// executable that exits non-zero on the first failure. The vectors are the
// ones relay/tests/test_protocol.py checks, so both sides agree byte for byte.
import CryptoKit
import Foundation
import RelayProtocol

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

final class MemoryKeys: RelayKeyStore {
    var keys: [String: Data] = [:]
    func key(forRelay id: String) -> Data? { keys[id] }
    func store(_ key: Data, forRelay id: String, name: String) { keys[id] = key }
}

func sent(_ outputs: [RelayOutput]) -> [String: RelayValue]? {
    for case .send(let message) in outputs { return message }
    return nil
}

let relayPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
let macPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(33...64))
let relayPublic = relayPrivate.publicKey.rawRepresentation
let macPublic = macPrivate.publicKey.rawRepresentation

// Vectors shared with the Python side.
check(relayPublic.hex == "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c", "relay public key")
check(macPublic.hex == "5869aff450549732cbaaed5e5df9b30a6da31cb0e5742bad5ad4a1a768f1a67b", "mac public key")
for privateKey in [relayPrivate, macPrivate] {
    let result = try RelayCrypto.pairingResult(privateKey: privateKey, relayPublicKey: relayPublic, macPublicKey: macPublic)
    check(result.key.hex == "3ff364ca645d7297a59353a860b4f3d0c66e599ac57c3913ba14e999f1bb2f5f", "shared key")
    check(result.code == "523188", "pairing code")
}
let key = Data(hex: "3ff364ca645d7297a59353a860b4f3d0c66e599ac57c3913ba14e999f1bb2f5f")!
let zeros = String(repeating: "00", count: 16), ones = String(repeating: "11", count: 16)
check(RelayCrypto.relayProof(key, macNonce: zeros) == "723c19a7346b9126bf927cf0d7e1975641ef870ba7f3af3610a9bb762d5c2e7c", "relay proof")
check(RelayCrypto.macProof(key, relayNonce: ones) == "a27ab59c55fd2eb13a18a8cd72246f4b79bb185b18335e6b2b4107ba13d3fe8b", "mac proof")
check(RelayCrypto.buttonSignature(key, macNonce: zeros, seq: 7, button: "next", down: true)
    == "248177910088038122e310d485d45692b7835a7deb6f882a7cb80d36b88f69dc", "button signature")
check(RelayCrypto.stateSignature(key, macNonce: zeros, seq: 8, active: true, spotlight: false, battery: -1)
    == "e3b5216f139c9c4e1c4cdf6ba0a500c92b00ad198c4f7f186151c24cacc631cd", "state signature")
check(RelayCrypto.matches("abc", "abc") && !RelayCrypto.matches("abc", "abd") && !RelayCrypto.matches("ab", "abc"),
      "signature comparison")

// A relay pairs with a new Mac, then authenticates and sends clicks.
let keys = MemoryKeys()
let relayHello: [String: Any] = ["t": "hello", "v": 1, "id": "relay-1", "name": "voiceclicker", "nonce": ones]
var session = RelaySession(macID: "mac-1", macName: "Ben's Mac", keys: keys, nonce: zeros)
let hello = sent(session.receive(relayHello))
check(hello?["paired"] == .bool(false), "a new relay is reported unpaired")
check(hello?["nonce"] == .string(zeros), "hello carries the Mac's nonce")

let pairOutputs = session.receive(["t": "pair", "pub": relayPublic.base64EncodedString()])
guard case .string(let macPub64)? = sent(pairOutputs)?["pub"], let macPub = Data(base64Encoded: macPub64),
      case .askToPair(let code)? = pairOutputs.last else {
    fatalError("pairing didn't answer with a key and a code")
}
let relaySide = try RelayCrypto.pairingResult(privateKey: relayPrivate, relayPublicKey: relayPublic, macPublicKey: macPub)
check(code == relaySide.code, "both sides show the same code")
check(session.receive(["t": "pair-ok"]).isEmpty && keys.keys.isEmpty, "the relay's OK alone stores nothing")
check(session.confirmPairing(true).last == .pairingEnded(stored: true), "both OKs store the key")
check(keys.keys["relay-1"] == relaySide.key, "the stored key is the relay's key")

session = RelaySession(macID: "mac-1", macName: "Ben's Mac", keys: keys, nonce: zeros)
check(sent(session.receive(relayHello))?["paired"] == .bool(true), "a paired relay is reported paired")
let authOutputs = session.receive(["t": "auth", "proof": RelayCrypto.relayProof(relaySide.key, macNonce: zeros)])
check(sent(authOutputs)?["proof"] == .string(RelayCrypto.macProof(relaySide.key, relayNonce: ones)), "the Mac proves its key")
check(session.isAuthenticated, "a good proof authenticates")

func click(_ seq: Int, _ down: Bool, key: Data = relaySide.key) -> [String: Any] {
    ["t": "btn", "seq": seq, "b": "next", "down": down,
     "sig": RelayCrypto.buttonSignature(key, macNonce: zeros, seq: seq, button: "next", down: down)]
}
check(session.receive(click(1, true)) == [.button(.next, down: true)], "a signed click is accepted")
check(session.receive(click(1, true)).first == .close(reason: "a click failed its signature check"), "a replayed click is refused")
check(session.receive(click(2, false, key: Data(count: 32))).count == 1
      && session.receive(click(3, false)) == [.button(.next, down: false)], "a forged click is refused and later clicks still work")
let state: [String: Any] = ["t": "state", "seq": 4, "active": true, "spotlight": true, "battery": 80,
    "sig": RelayCrypto.stateSignature(relaySide.key, macNonce: zeros, seq: 4, active: true, spotlight: true, battery: 80)]
check(session.receive(state) == [.state(active: true, spotlight: true, battery: 80)] && session.isActive, "a signed state is accepted")

// A Mac with no key, or the wrong one, refuses everything signed.
session = RelaySession(macID: "mac-1", macName: "Ben's Mac", keys: MemoryKeys(), nonce: zeros)
_ = session.receive(relayHello)
check(session.receive(["t": "auth", "proof": RelayCrypto.relayProof(relaySide.key, macNonce: zeros)]).first
      == .close(reason: "the relay's key doesn't match; pair again"), "auth without a key is refused")
check(session.receive(click(1, true)).first == .close(reason: "a click failed its signature check"), "clicks before auth are refused")
check(session.receive(["t": "ping"]) == [.send(["t": .string("pong")])], "pings are answered")

// Refusing to pair stores nothing.
let refusingKeys = MemoryKeys()
session = RelaySession(macID: "mac-1", macName: "Ben's Mac", keys: refusingKeys, nonce: zeros)
_ = session.receive(relayHello)
_ = session.receive(["t": "pair", "pub": relayPublic.base64EncodedString()])
check(session.confirmPairing(false) == [.send(["t": .string("pair-no")]), .pairingEnded(stored: false)], "No sends pair-no")
_ = session.receive(["t": "pair", "pub": relayPublic.base64EncodedString()])
check(session.receive(["t": "pair-no"]) == [.pairingEnded(stored: false)], "the relay's No ends the pairing")
check(session.receive(["t": "pair-ok"]).isEmpty && refusingKeys.keys.isEmpty, "a late OK stores nothing")

// Messages travel as single JSON lines.
let line = RelayWire.encode(["t": .string("ping")])
check(line.last == 0x0A && RelayWire.decode(line.dropLast())?["t"] as? String == "ping", "wire round trip")
check(RelaySession(macID: "m", macName: "n", keys: keys).receive(["t": "btn"]).first == .close(reason: "message before hello"),
      "messages before hello are refused")

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("All relay protocol checks passed")
