"""The relay protocol, shared with Voice Clicker's RelayProtocol Swift module.

Each Mac running Voice Clicker with Wi-Fi Relay on listens for TCP
connections and advertises `_voiceclicker._tcp` over Bonjour. The relay
connects to each Mac it finds. Both sides then send one JSON object per line.

Handshake, relay first:
    relay -> mac  {"t":"hello","v":1,"id":<relay id>,"name":<name>,"nonce":<hex>}
    mac -> relay  {"t":"hello","v":1,"id":<mac id>,"name":<name>,"nonce":<hex>,"paired":<bool>}
When both hold a key for each other:
    relay -> mac  {"t":"auth","proof":hmac(key, "relay|" + mac nonce)}
    mac -> relay  {"t":"auth","proof":hmac(key, "mac|" + relay nonce)}
Otherwise the connection stays unpaired until the person starts pairing on
the relay's screen:
    relay -> mac  {"t":"pair","pub":<base64 X25519 public key>}
    mac -> relay  {"t":"pair","pub":<base64 X25519 public key>}
Both screens then show the same six-digit code. Each side sends
{"t":"pair-ok"} when the person confirms it, or {"t":"pair-no"}. A side
stores the key once it has confirmed and received the other's pair-ok. The
relay then closes the connection and reconnects with the new key.

After auth, the relay sends signed messages. The signature is an HMAC over a
fixed string that includes the Mac's nonce for this connection and a counter
that only goes up, so a recorded message fails on any later connection:
    {"t":"btn","seq":n,"b":"next"|"back","down":<bool>,"sig":...}
    {"t":"state","seq":n,"active":<bool>,"spotlight":<bool>,"battery":<int, -1 unknown>,"sig":...}
Either side may send {"t":"ping"}; the other answers {"t":"pong"}.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from dataclasses import dataclass
from typing import Any

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

VERSION = 1
SERVICE_TYPE = "_voiceclicker._tcp.local."
BUTTONS = ("next", "back")


def new_nonce() -> str:
    return secrets.token_hex(16)


def public_bytes(private: X25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def _hkdf(shared: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(shared)


def pairing_result(private: X25519PrivateKey, relay_pub: bytes, mac_pub: bytes) -> tuple[bytes, str]:
    """The shared key and the six-digit code both screens show."""
    peer = mac_pub if public_bytes(private) == relay_pub else relay_pub
    shared = private.exchange(X25519PublicKey.from_public_bytes(peer))
    salt = relay_pub + mac_pub
    key = _hkdf(shared, salt, b"voiceclicker pair key", 32)
    number = int.from_bytes(_hkdf(shared, salt, b"voiceclicker pair code", 4), "big")
    return key, f"{number % 1_000_000:06d}"


def mac(key: bytes, text: str) -> str:
    return hmac.new(key, text.encode(), hashlib.sha256).hexdigest()


def relay_proof(key: bytes, mac_nonce: str) -> str:
    return mac(key, f"relay|{mac_nonce}")


def mac_proof(key: bytes, relay_nonce: str) -> str:
    return mac(key, f"mac|{relay_nonce}")


def button_signature(key: bytes, mac_nonce: str, seq: int, button: str, down: bool) -> str:
    return mac(key, f"btn|{mac_nonce}|{seq}|{button}|{int(down)}")


def state_signature(key: bytes, mac_nonce: str, seq: int, active: bool, spotlight: bool, battery: int) -> str:
    return mac(key, f"state|{mac_nonce}|{seq}|{int(active)}|{int(spotlight)}|{battery}")


def encode(message: dict[str, Any]) -> bytes:
    return (json.dumps(message, separators=(",", ":")) + "\n").encode()


def decode(line: bytes) -> dict[str, Any]:
    message = json.loads(line)
    if not isinstance(message, dict) or not isinstance(message.get("t"), str):
        raise ProtocolError("not a message")
    return message


class ProtocolError(Exception):
    pass


@dataclass
class Peer:
    """What the relay learned about a Mac from its hello."""

    id: str
    name: str


class MacSession:
    """The relay's side of one connection to a Mac, without any I/O.

    Feed it each message from the Mac with `receive`; it returns the
    messages to send back. `keys` maps Mac ids to stored keys and is updated
    when pairing completes.
    """

    def __init__(self, relay_id: str, relay_name: str, keys: dict[str, bytes]):
        self.relay_id = relay_id
        self.relay_name = relay_name
        self.keys = keys
        self.nonce = new_nonce()
        self.peer: Peer | None = None
        self.mac_nonce = ""
        self.mac_says_paired = False
        self.authed = False
        self.paired_now = False
        self.seq = 0
        self.pair_private: X25519PrivateKey | None = None
        self.pair_key: bytes | None = None
        self.pair_code: str | None = None
        self.pair_confirmed = False
        self.pair_peer_confirmed = False
        self.pair_refused = False

    @property
    def key(self) -> bytes | None:
        return self.keys.get(self.peer.id) if self.peer else None

    def hello(self) -> dict[str, Any]:
        return {"t": "hello", "v": VERSION, "id": self.relay_id, "name": self.relay_name, "nonce": self.nonce}

    def receive(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        kind = message["t"]
        if kind == "ping":
            return [{"t": "pong"}]
        if kind == "pong":
            return []
        if kind == "hello":
            return self._hello(message)
        if self.peer is None:
            raise ProtocolError("message before hello")
        if kind == "auth":
            return self._auth(message)
        if kind == "pair":
            return self._pair_pub(message)
        if kind == "pair-ok":
            self.pair_peer_confirmed = True
            return self._maybe_store()
        if kind == "pair-no":
            self.pair_refused = True
            self._reset_pairing()
            return []
        raise ProtocolError(f"unknown message {kind}")

    def _hello(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        if message.get("v") != VERSION:
            raise ProtocolError("unsupported version")
        self.peer = Peer(id=str(message["id"]), name=str(message["name"]))
        self.mac_nonce = str(message["nonce"])
        self.mac_says_paired = bool(message.get("paired"))
        if self.key is not None and self.mac_says_paired:
            return [{"t": "auth", "proof": relay_proof(self.key, self.mac_nonce)}]
        return []

    def _auth(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        key = self.key
        if key is None or not hmac.compare_digest(str(message.get("proof")), mac_proof(key, self.nonce)):
            raise ProtocolError("bad proof")
        self.authed = True
        return []

    @property
    def is_paired(self) -> bool:
        """Whether this Mac can get clicks: it proved it holds our key."""
        return self.authed

    def start_pairing(self) -> list[dict[str, Any]]:
        self._reset_pairing()
        self.pair_refused = False
        self.pair_private = X25519PrivateKey.generate()
        return [{"t": "pair", "pub": base64.b64encode(public_bytes(self.pair_private)).decode()}]

    def _pair_pub(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        if self.pair_private is None:
            raise ProtocolError("pair reply without a request")
        mac_pub = base64.b64decode(str(message["pub"]), validate=True)
        if len(mac_pub) != 32:
            raise ProtocolError("bad public key")
        self.pair_key, self.pair_code = pairing_result(self.pair_private, public_bytes(self.pair_private), mac_pub)
        return []

    def confirm_pairing(self, accepted: bool) -> list[dict[str, Any]]:
        if self.pair_code is None:
            return []
        if not accepted:
            self._reset_pairing()
            return [{"t": "pair-no"}]
        self.pair_confirmed = True
        return [{"t": "pair-ok"}, *self._maybe_store()]

    def cancel_pairing(self) -> list[dict[str, Any]]:
        """Abandons a pairing the person backed out of, before or after the code showed."""
        if self.pair_private is None:
            return []
        self._reset_pairing()
        return [{"t": "pair-no"}]

    def _maybe_store(self) -> list[dict[str, Any]]:
        if self.pair_confirmed and self.pair_peer_confirmed and self.pair_key is not None and self.peer:
            self.keys[self.peer.id] = self.pair_key
            self.paired_now = True
            self._reset_pairing()
        return []

    def _reset_pairing(self) -> None:
        self.pair_private = None
        self.pair_key = None
        self.pair_code = None
        self.pair_confirmed = False
        self.pair_peer_confirmed = False

    def button(self, button: str, down: bool) -> dict[str, Any]:
        key = self._signing_key()
        self.seq += 1
        return {"t": "btn", "seq": self.seq, "b": button, "down": down,
                "sig": button_signature(key, self.mac_nonce, self.seq, button, down)}

    def state(self, active: bool, spotlight: bool, battery: int | None) -> dict[str, Any]:
        key = self._signing_key()
        self.seq += 1
        level = -1 if battery is None else battery
        return {"t": "state", "seq": self.seq, "active": active, "spotlight": spotlight, "battery": level,
                "sig": state_signature(key, self.mac_nonce, self.seq, active, spotlight, level)}

    def _signing_key(self) -> bytes:
        if not self.authed or self.key is None:
            raise ProtocolError("not paired")
        return self.key
