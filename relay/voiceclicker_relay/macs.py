"""Finds the Macs running Voice Clicker and keeps a connection to each."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable
from dataclasses import dataclass

from zeroconf import ServiceStateChange
from zeroconf.asyncio import AsyncServiceBrowser, AsyncServiceInfo, AsyncZeroconf

from . import protocol as p

log = logging.getLogger(__name__)


@dataclass
class Found:
    """A Mac advertising Voice Clicker's Wi-Fi Relay."""

    service: str
    mac_id: str
    name: str
    host: str
    port: int


class Browser:
    """Reports Macs as they appear on and leave the network."""

    def __init__(self, on_found: Callable[[Found], None], on_lost: Callable[[str], None]):
        self.on_found = on_found
        self.on_lost = on_lost
        self.zeroconf: AsyncZeroconf | None = None

    async def start(self) -> None:
        self.zeroconf = AsyncZeroconf()
        self.browser = AsyncServiceBrowser(self.zeroconf.zeroconf, p.SERVICE_TYPE, handlers=[self._changed])

    def _changed(self, zeroconf, service_type: str, name: str, state_change: ServiceStateChange) -> None:
        if state_change is ServiceStateChange.Removed:
            self.on_lost(name)
        else:
            asyncio.ensure_future(self._resolve(service_type, name))

    async def _resolve(self, service_type: str, name: str) -> None:
        info = AsyncServiceInfo(service_type, name)
        if not await info.async_request(self.zeroconf.zeroconf, 3000):
            return
        addresses = info.parsed_addresses()
        properties = {k.decode(): (v or b"").decode() for k, v in info.properties.items()}
        if not addresses or not info.port or "id" not in properties:
            return
        # Prefer IPv4: link-local IPv6 needs a scope the address string drops.
        host = next((a for a in addresses if ":" not in a), addresses[0])
        label = name.removesuffix("." + service_type)
        self.on_found(Found(service=name, mac_id=properties["id"], name=label, host=host, port=info.port))


class MacLink:
    """One Mac: reconnects while it's on the network and runs a protocol session."""

    def __init__(self, found: Found, relay_id: str, relay_name: str, keys: dict[str, bytes],
                 on_change: Callable[["MacLink"], None], on_paired: Callable[["MacLink", bytes], None]):
        self.found = found
        self.relay_id = relay_id
        self.relay_name = relay_name
        self.keys = keys
        self.on_change = on_change
        self.on_paired = on_paired
        self.session: p.MacSession | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.online = False
        self.task = asyncio.create_task(self._run())

    @property
    def mac_id(self) -> str:
        return self.found.mac_id

    @property
    def name(self) -> str:
        return self.session.peer.name if self.session and self.session.peer else self.found.name

    @property
    def paired(self) -> bool:
        return bool(self.session and self.session.is_paired)

    def close(self) -> None:
        self.task.cancel()

    def send(self, messages: list[dict]) -> None:
        if self.writer is None:
            return
        for message in messages:
            self.writer.write(p.encode(message))

    def start_pairing(self) -> None:
        if self.session and self.session.peer:
            self.send(self.session.start_pairing())

    def confirm_pairing(self, accepted: bool) -> None:
        if self.session:
            self.send(self.session.confirm_pairing(accepted))
            self._after_pairing()

    def cancel_pairing(self) -> None:
        if self.session:
            self.send(self.session.cancel_pairing())

    def button(self, button: str, down: bool) -> None:
        if self.paired:
            self.send([self.session.button(button, down)])

    def state(self, active: bool, spotlight: bool, battery: int | None) -> None:
        if self.paired:
            self.send([self.session.state(active, spotlight, battery)])

    async def _run(self) -> None:
        while True:
            try:
                await self._connect()
            except (OSError, p.ProtocolError, ValueError) as error:
                log.info("%s: %s", self.found.name, error)
            finally:
                self.online = False
                self.writer = None
                self.on_change(self)
            await asyncio.sleep(3)

    async def _connect(self) -> None:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(self.found.host, self.found.port), 5)
        self.writer = writer
        self.session = p.MacSession(self.relay_id, self.relay_name, self.keys)
        self.online = True
        self.send([self.session.hello()])
        self.on_change(self)
        pinger = asyncio.create_task(self._ping())
        try:
            while True:
                line = await asyncio.wait_for(reader.readline(), 35)
                if not line:
                    return
                self.send(self.session.receive(p.decode(line)))
                self._after_pairing()
                self.on_change(self)
                await writer.drain()
        finally:
            pinger.cancel()
            writer.close()

    def _after_pairing(self) -> None:
        if self.session and self.session.paired_now:
            self.session.paired_now = False
            self.on_paired(self, self.keys[self.mac_id])
            # Reconnect, so the new key authenticates the next session.
            if self.writer:
                self.writer.close()

    async def _ping(self) -> None:
        while True:
            await asyncio.sleep(10)
            self.send([{"t": "ping"}])
