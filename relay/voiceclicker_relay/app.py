"""Wires the Spotlight, the Macs, the screen and the HAT's buttons together.

Controls on the HAT:
    joystick up/down      move the highlight through the Macs
    joystick press        send clicks to the highlighted Mac (or pair it, if new)
    joystick left/right   switch straight to the previous or next paired Mac
    KEY1                  pair the highlighted Mac; YES on a pairing code
    KEY2                  pair a Spotlight
    KEY3                  show the relay's details; NO or BACK on other screens
"""

from __future__ import annotations

import asyncio
import logging
import socket
import time
from collections.abc import Callable

from . import spotlight as bt
from .macs import Browser, Found, MacLink
from .store import State
from .ui import MacRow, Renderer, View

log = logging.getLogger(__name__)

# BCM pins of the HAT's controls.
BUTTON_PINS = {"up": 6, "down": 19, "left": 5, "right": 26, "press": 13, "key1": 21, "key2": 20, "key3": 16}
PAIR_TIMEOUT = 90


class App:
    def __init__(self, state: State, show: Callable, frame_seconds: float = 0.25):
        self.state = state
        self.show = show
        self.frame_seconds = frame_seconds
        self.keys = state.keys()
        self.renderer = Renderer()
        self.links: dict[str, MacLink] = {}
        self.services: dict[str, str] = {}
        self.cursor = 0
        self.mode = "main"
        self.pairing: MacLink | None = None
        self.pairing_started = 0.0
        self.message: tuple[str, list[str]] | None = None
        self.flash: tuple[str, float] | None = None
        self.battery: int | None = None
        self.tick = 0
        self.dirty = asyncio.Event()
        self.spotlight = bt.Spotlight(self.clicked, self.spotlight_changed)
        self.browser = Browser(self.found, self.lost)

    # MARK: - Macs

    def rows(self) -> list[tuple[str, str, str]]:
        """(mac id, name, status) for every Mac, paired ones first, in a stable order."""
        rows = []
        for mac_id, entry in self.state.macs.items():
            link = self.links.get(mac_id)
            if link and link.online and link is self.pairing:
                status = "pairing"
            elif link and link.paired:
                status = "paired"
            elif link and link.online:
                status = "new"  # online, but its key didn't check out: pair again
            else:
                status = "offline"
            rows.append((mac_id, link.name if link else entry["name"], status))
        for mac_id, link in sorted(self.links.items(), key=lambda item: item[1].name.lower()):
            if mac_id not in self.state.macs and link.online:
                rows.append((mac_id, link.name, "pairing" if link is self.pairing else "new"))
        return rows

    def found(self, found: Found) -> None:
        self.services[found.service] = found.mac_id
        link = self.links.get(found.mac_id)
        if link and (link.found.host, link.found.port) == (found.host, found.port):
            return
        if link:
            link.close()
        self.links[found.mac_id] = MacLink(found, self.state.relay_id, self.state.name, self.keys,
                                           self.link_changed, self.paired)
        self.redraw()

    def lost(self, service: str) -> None:
        mac_id = self.services.pop(service, None)
        link = self.links.pop(mac_id, None) if mac_id else None
        if link:
            link.close()
            if link is self.pairing:
                self.end_pairing("MAC LEFT", ["It went off the network."])
        self.redraw()

    def link_changed(self, link: MacLink) -> None:
        if link.paired and link.mac_id in self.state.macs and self.state.macs[link.mac_id]["name"] != link.name:
            self.state.macs[link.mac_id]["name"] = link.name
            self.state.save()
        if link.paired and self.state.active is None:
            self.state.active = link.mac_id
            self.state.save()
        if link is self.pairing and link.session and link.session.pair_refused:
            self.end_pairing("NOT PAIRED", ["The Mac said no."])
        self.send_state(link)
        self.redraw()

    def paired(self, link: MacLink, key: bytes) -> None:
        self.state.remember(link.mac_id, link.name, key)
        if self.state.active is None:
            self.state.active = link.mac_id
            self.state.save()
        self.end_pairing("PAIRED", [link.name[:18]])

    def send_state(self, link: MacLink) -> None:
        link.state(active=link.mac_id == self.state.active, spotlight=self.spotlight.connected, battery=self.battery)

    def broadcast_state(self) -> None:
        for link in self.links.values():
            self.send_state(link)

    def make_active(self, mac_id: str) -> None:
        if mac_id != self.state.active:
            self.state.active = mac_id
            self.state.save()
            self.broadcast_state()
        self.redraw()

    # MARK: - Spotlight

    def clicked(self, button: str, down: bool) -> None:
        link = self.links.get(self.state.active or "")
        if link and link.paired:
            link.button(button, down)
            if down:
                self.flash = ("NEXT" if button == "next" else "BACK", time.monotonic() + 0.5)
        elif down:
            self.flash = ("NO MAC", time.monotonic() + 0.8)
        self.redraw()

    def spotlight_changed(self) -> None:
        self.broadcast_state()
        self.redraw()

    async def watch_battery(self) -> None:
        while True:
            level = await bt.battery(self.state.spotlight) if self.state.spotlight else None
            if level != self.battery:
                self.battery = level
                self.broadcast_state()
                self.redraw()
            await asyncio.sleep(60)

    async def pair_spotlight(self) -> None:
        self.mode = "spotlight"
        self.message = ("PAIR SPOTLIGHT", ["Hold its top and", "bottom buttons until", "it vibrates.", "", "Searching..."])
        self.redraw()
        address = await bt.pair()
        if address:
            self.state.spotlight = address
            self.state.save()
            self.message = ("SPOTLIGHT PAIRED", [address])
            self.battery = await bt.battery(address)
        else:
            self.message = ("NO SPOTLIGHT", ["None found in 40 s.", "Try again with 2."])
        self.mode = "spotlight"
        self.redraw()

    # MARK: - Pairing a Mac

    def start_pairing(self, mac_id: str) -> None:
        link = self.links.get(mac_id)
        if not link or not link.online:
            return
        self.pairing = link
        self.pairing_started = time.monotonic()
        self.mode = "pair"
        link.start_pairing()
        self.redraw()

    def end_pairing(self, title: str, lines: list[str]) -> None:
        self.pairing = None
        self.mode = "result"
        self.message = (title, lines)
        self.redraw()

    def check_pairing_timeout(self) -> None:
        if self.pairing and time.monotonic() - self.pairing_started > PAIR_TIMEOUT:
            self.pairing.cancel_pairing()
            self.end_pairing("TIMED OUT", ["Nobody confirmed", "on the Mac."])

    # MARK: - HAT controls

    def pressed(self, control: str) -> None:
        rows = self.rows()
        if self.mode == "pair":
            session = self.pairing.session if self.pairing else None
            if control == "key1" and session and session.pair_code:
                self.pairing.confirm_pairing(True)
            elif control == "key3":
                if self.pairing:
                    self.pairing.cancel_pairing()
                self.end_pairing("NOT PAIRED", ["Cancelled."])
        elif self.mode != "main":
            if control in ("key3", "press"):
                self.mode = "main"
        elif control == "up":
            self.cursor = max(0, self.cursor - 1)
        elif control == "down":
            self.cursor = min(max(0, len(rows) - 1), self.cursor + 1)
        elif control in ("left", "right"):
            paired = [mac_id for mac_id, _, status in rows if status == "paired"]
            if paired:
                index = paired.index(self.state.active) if self.state.active in paired else -1
                step = 1 if control == "right" else -1
                self.make_active(paired[(index + step) % len(paired)])
                self.cursor = [r[0] for r in rows].index(self.state.active)
        elif control == "press" and rows:
            mac_id, _, status = rows[min(self.cursor, len(rows) - 1)]
            if status == "paired":
                self.make_active(mac_id)
            elif status == "new":
                self.start_pairing(mac_id)
        elif control == "key1" and rows:
            self.start_pairing(rows[min(self.cursor, len(rows) - 1)][0])
        elif control == "key2":
            asyncio.ensure_future(self.pair_spotlight())
        elif control == "key3":
            self.mode = "info"
        self.redraw()

    # MARK: - Screen

    def view(self) -> View:
        flash = self.flash[0] if self.flash and self.flash[1] > time.monotonic() else None
        if self.mode == "pair" and self.pairing:
            code = self.pairing.session.pair_code if self.pairing.session else None
            lines = ["SAME CODE ON THE MAC?", "1 = YES   3 = NO"] if code else ["Waiting for the Mac..."]
            if self.pairing.session and self.pairing.session.pair_confirmed:
                lines = ["Now click Pair", "on the Mac."]
            return View(mode="pair", title=f"PAIR {self.pairing.name[:13].upper()}", code=code, lines=lines,
                        hints=("YES" if code else "", "", "NO"), tick=self.tick)
        if self.mode == "info":
            return View(mode="info", title="RELAY", tick=self.tick, hints=("", "", "BACK"), lines=[
                self.state.name, self.ip(), f"{sum(1 for r in self.rows() if r[2] == 'paired')} paired Mac(s)",
                f"Spotlight {self.state.spotlight or 'not paired'}"[:22]])
        if self.mode in ("result", "spotlight") and self.message:
            return View(mode=self.mode, title=self.message[0], lines=self.message[1], tick=self.tick,
                        hints=("", "", "BACK"))
        rows = self.rows()
        self.cursor = min(self.cursor, max(0, len(rows) - 1))
        macs = [MacRow(name=name, status=status, active=mac_id == self.state.active) for mac_id, name, status in rows]
        return View(macs=macs, cursor=self.cursor, spotlight=self.spotlight.connected, battery=self.battery,
                    flash=flash, tick=self.tick)

    @staticmethod
    def ip() -> str:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("192.0.2.1", 9))  # no packet is sent; this only picks the outgoing interface
                return s.getsockname()[0]
        except OSError:
            return "no network"

    def redraw(self) -> None:
        self.dirty.set()

    async def draw_loop(self) -> None:
        while True:
            try:
                await asyncio.wait_for(self.dirty.wait(), self.frame_seconds)
            except TimeoutError:
                pass
            self.dirty.clear()
            self.tick += 1
            self.check_pairing_timeout()
            await asyncio.to_thread(self.show, self.renderer.render(self.view()))

    async def run(self) -> None:
        await self.browser.start()
        await asyncio.gather(self.spotlight.run(), self.watch_battery(), self.draw_loop())
