"""The relay's saved state: its id, the Mac keys, the chosen Mac and the Spotlight."""

from __future__ import annotations

import json
import os
import secrets
import socket
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PATH = Path("/var/lib/voiceclicker-relay/state.json")


@dataclass
class State:
    path: Path
    relay_id: str = ""
    name: str = ""
    # Mac id -> {"name": ..., "key": hex}
    macs: dict[str, dict[str, str]] = field(default_factory=dict)
    active: str | None = None
    spotlight: str | None = None

    @classmethod
    def load(cls, path: Path = DEFAULT_PATH) -> "State":
        state = cls(path=path)
        if path.exists():
            data = json.loads(path.read_text())
            state.relay_id = data.get("relay_id", "")
            state.name = data.get("name", "")
            state.macs = data.get("macs", {})
            state.active = data.get("active")
            state.spotlight = data.get("spotlight")
        if not state.relay_id:
            state.relay_id = secrets.token_hex(8)
        if not state.name:
            state.name = socket.gethostname()
        state.save()
        return state

    def keys(self) -> dict[str, bytes]:
        return {mac_id: bytes.fromhex(entry["key"]) for mac_id, entry in self.macs.items()}

    def remember(self, mac_id: str, name: str, key: bytes) -> None:
        self.macs[mac_id] = {"name": name, "key": key.hex()}
        self.save()

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {"relay_id": self.relay_id, "name": self.name, "macs": self.macs,
                "active": self.active, "spotlight": self.spotlight}
        temporary = self.path.with_suffix(".tmp")
        # Keys live here, so only the service's user can read the file.
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2)
        os.replace(temporary, self.path)
