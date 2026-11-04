import base64
import unittest

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from voiceclicker_relay import protocol as p

# The same vectors are checked by `swift run relay-protocol-check`, so the two
# sides of the protocol can't drift apart.
RELAY_PRIVATE = bytes(range(1, 33))
MAC_PRIVATE = bytes(range(33, 65))
VECTORS = {
    "relay_pub": "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c",
    "mac_pub": "5869aff450549732cbaaed5e5df9b30a6da31cb0e5742bad5ad4a1a768f1a67b",
    "key": "3ff364ca645d7297a59353a860b4f3d0c66e599ac57c3913ba14e999f1bb2f5f",
    "code": "523188",
    "relay_proof": "723c19a7346b9126bf927cf0d7e1975641ef870ba7f3af3610a9bb762d5c2e7c",
    "mac_proof": "a27ab59c55fd2eb13a18a8cd72246f4b79bb185b18335e6b2b4107ba13d3fe8b",
    "btn": "248177910088038122e310d485d45692b7835a7deb6f882a7cb80d36b88f69dc",
    "state": "e3b5216f139c9c4e1c4cdf6ba0a500c92b00ad198c4f7f186151c24cacc631cd",
}


class VectorTests(unittest.TestCase):
    def test_both_sides_derive_the_published_key_and_code(self):
        relay = X25519PrivateKey.from_private_bytes(RELAY_PRIVATE)
        mac = X25519PrivateKey.from_private_bytes(MAC_PRIVATE)
        relay_pub, mac_pub = p.public_bytes(relay), p.public_bytes(mac)
        self.assertEqual(relay_pub.hex(), VECTORS["relay_pub"])
        self.assertEqual(mac_pub.hex(), VECTORS["mac_pub"])
        for private in (relay, mac):
            key, code = p.pairing_result(private, relay_pub, mac_pub)
            self.assertEqual(key.hex(), VECTORS["key"])
            self.assertEqual(code, VECTORS["code"])

    def test_signatures_match_the_published_vectors(self):
        key = bytes.fromhex(VECTORS["key"])
        self.assertEqual(p.relay_proof(key, "00" * 16), VECTORS["relay_proof"])
        self.assertEqual(p.mac_proof(key, "11" * 16), VECTORS["mac_proof"])
        self.assertEqual(p.button_signature(key, "00" * 16, 7, "next", True), VECTORS["btn"])
        self.assertEqual(p.state_signature(key, "00" * 16, 8, True, False, -1), VECTORS["state"])


class FakeMac:
    """The Mac's side of the protocol, written from the docstring in protocol.py."""

    def __init__(self, key=None):
        self.key = key
        self.nonce = p.new_nonce()
        self.relay_nonce = ""
        self.private = X25519PrivateKey.generate()
        self.relay_pub = b""

    def hello(self, relay_hello):
        self.relay_nonce = relay_hello["nonce"]
        return {"t": "hello", "v": 1, "id": "mac-1", "name": "Ben's Mac", "nonce": self.nonce,
                "paired": self.key is not None}

    def answer_pair(self, message):
        self.relay_pub = base64.b64decode(message["pub"])
        mine = p.public_bytes(self.private)
        self.pair_key, self.code = p.pairing_result(self.private, self.relay_pub, mine)
        return {"t": "pair", "pub": base64.b64encode(mine).decode()}


def connect(keys, mac):
    session = p.MacSession("relay-1", "voiceclicker", keys)
    replies = session.receive(mac.hello(session.hello()))
    return session, replies


class HandshakeTests(unittest.TestCase):
    def test_a_paired_mac_authenticates_and_gets_signed_buttons(self):
        key = bytes(32)
        mac = FakeMac(key)
        session, replies = connect({"mac-1": key}, mac)
        self.assertEqual(replies, [{"t": "auth", "proof": p.relay_proof(key, mac.nonce)}])
        session.receive({"t": "auth", "proof": p.mac_proof(key, session.nonce)})
        self.assertTrue(session.is_paired)

        first, second = session.button("next", True), session.button("next", False)
        self.assertEqual(first["sig"], p.button_signature(key, mac.nonce, 1, "next", True))
        self.assertGreater(second["seq"], first["seq"])
        state = session.state(active=True, spotlight=True, battery=None)
        self.assertEqual(state["battery"], -1)
        self.assertEqual(state["sig"], p.state_signature(key, mac.nonce, state["seq"], True, True, -1))

    def test_a_mac_with_the_wrong_key_is_refused(self):
        session, _ = connect({"mac-1": bytes(32)}, FakeMac(bytes([1]) * 32))
        with self.assertRaises(p.ProtocolError):
            session.receive({"t": "auth", "proof": p.mac_proof(bytes([1]) * 32, session.nonce)})
        self.assertFalse(session.is_paired)

    def test_an_unpaired_mac_gets_no_auth_and_no_buttons(self):
        session, replies = connect({}, FakeMac())
        self.assertEqual(replies, [])
        with self.assertRaises(p.ProtocolError):
            session.button("next", True)

    def test_pairing_stores_the_key_only_after_both_confirm(self):
        keys = {}
        mac = FakeMac()
        session, _ = connect(keys, mac)
        [pair] = session.start_pairing()
        session.receive(mac.answer_pair(pair))
        self.assertEqual(session.pair_code, mac.code)

        self.assertEqual(session.confirm_pairing(True), [{"t": "pair-ok"}])
        self.assertEqual(keys, {})
        session.receive({"t": "pair-ok"})
        self.assertEqual(keys, {"mac-1": mac.pair_key})
        self.assertTrue(session.paired_now)

    def test_a_refusal_on_the_mac_stores_nothing(self):
        keys = {}
        mac = FakeMac()
        session, _ = connect(keys, mac)
        session.receive(mac.answer_pair(session.start_pairing()[0]))
        session.receive({"t": "pair-no"})
        self.assertTrue(session.pair_refused)
        self.assertEqual(session.confirm_pairing(True), [])
        self.assertEqual(keys, {})

    def test_a_refusal_on_the_relay_tells_the_mac(self):
        mac = FakeMac()
        session, _ = connect({}, mac)
        session.receive(mac.answer_pair(session.start_pairing()[0]))
        self.assertEqual(session.confirm_pairing(False), [{"t": "pair-no"}])
        self.assertIsNone(session.pair_code)

    def test_cancel_before_the_code_arrives_tells_the_mac(self):
        session, _ = connect({}, FakeMac())
        self.assertEqual(session.cancel_pairing(), [])
        session.start_pairing()
        self.assertEqual(session.cancel_pairing(), [{"t": "pair-no"}])

    def test_pings_are_answered(self):
        session = p.MacSession("relay-1", "voiceclicker", {})
        self.assertEqual(session.receive({"t": "ping"}), [{"t": "pong"}])
        self.assertEqual(session.receive({"t": "pong"}), [])

    def test_bad_input_is_a_protocol_error(self):
        session = p.MacSession("relay-1", "voiceclicker", {})
        with self.assertRaises(p.ProtocolError):
            session.receive({"t": "auth", "proof": ""})
        with self.assertRaises(p.ProtocolError):
            session.receive({"t": "hello", "v": 2, "id": "m", "name": "n", "nonce": ""})
        with self.assertRaises(p.ProtocolError):
            p.decode(b"[1]")
        session.receive(FakeMac().hello(session.hello()))
        with self.assertRaises(p.ProtocolError):
            session.receive({"t": "pair", "pub": "AAAA"})
        with self.assertRaises(p.ProtocolError):
            session.receive({"t": "nonsense"})

    def test_messages_round_trip_as_single_lines(self):
        line = p.encode({"t": "ping"})
        self.assertTrue(line.endswith(b"\n"))
        self.assertEqual(p.decode(line), {"t": "ping"})


if __name__ == "__main__":
    unittest.main()
