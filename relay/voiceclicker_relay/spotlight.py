"""The Logitech Spotlight, paired to the Pi over Bluetooth.

BlueZ turns the clicker into Linux input devices. Next sends Right Arrow and
Back sends Left Arrow, the same keys Voice Clicker reads on a Mac. The relay
grabs the devices so the Pi's console never sees the keys.
"""

from __future__ import annotations

import asyncio
import logging
import re
from collections.abc import Callable

import evdev
from evdev import ecodes

log = logging.getLogger(__name__)

BUTTON_KEYS = {
    ecodes.KEY_RIGHT: "next",
    ecodes.KEY_PAGEDOWN: "next",
    ecodes.KEY_LEFT: "back",
    ecodes.KEY_PAGEUP: "back",
}
LOGITECH = 0x046D
SPOTLIGHT_BLUETOOTH = 0xB503


def is_spotlight(device: evdev.InputDevice) -> bool:
    info = device.info
    return "spotlight" in device.name.lower() or (info.vendor == LOGITECH and info.product == SPOTLIGHT_BLUETOOTH)


class Spotlight:
    """Watches for the Spotlight's input devices and reports button presses."""

    def __init__(self, on_button: Callable[[str, bool], None], on_change: Callable[[], None]):
        self.on_button = on_button
        self.on_change = on_change
        self.devices: dict[str, evdev.InputDevice] = {}
        # The Bluetooth address of the last Spotlight seen, which Linux puts in the device's uniq.
        self.address: str | None = None

    @property
    def connected(self) -> bool:
        return bool(self.devices)

    async def run(self) -> None:
        while True:
            for path in evdev.list_devices():
                if path in self.devices:
                    continue
                try:
                    device = evdev.InputDevice(path)
                except OSError:
                    continue
                if not is_spotlight(device) or ecodes.EV_KEY not in device.capabilities():
                    device.close()
                    continue
                try:
                    device.grab()
                except OSError:
                    log.warning("Couldn't grab %s", device.name)
                self.devices[path] = device
                if device.uniq:
                    self.address = device.uniq.upper()
                log.info("Spotlight input %s (%s)", device.name, path)
                asyncio.create_task(self._read(path, device))
                self.on_change()
            await asyncio.sleep(1.5)

    async def _read(self, path: str, device: evdev.InputDevice) -> None:
        try:
            async for event in device.async_read_loop():
                # Value 2 is key repeat, which a held button would flood.
                if event.type == ecodes.EV_KEY and event.code in BUTTON_KEYS and event.value in (0, 1):
                    self.on_button(BUTTON_KEYS[event.code], event.value == 1)
        except OSError:
            pass
        finally:
            self.devices.pop(path, None)
            device.close()
            log.info("Spotlight input %s gone", path)
            self.on_change()


async def _bluetoothctl(*args: str, timeout: float = 30) -> str:
    process = await asyncio.create_subprocess_exec(
        "bluetoothctl", *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), timeout)
    except TimeoutError:
        process.kill()
        output, _ = await process.communicate()
    return output.decode(errors="replace")


async def battery(address: str) -> int | None:
    """The Spotlight's battery level, which BlueZ reads from its Battery Service."""
    match = re.search(r"Battery Percentage: 0x[0-9a-fA-F]+ \((\d+)\)", await _bluetoothctl("info", address))
    return int(match.group(1)) if match else None


_ANSI = re.compile(r"\x1b\[[0-9;]*m|\x01|\x02")
_DEVICE = re.compile(r"Device ([0-9A-F:]{17}) (.*)")


async def pair(seconds: int = 40) -> str | None:
    """Scans for a Spotlight in pairing mode and pairs it. Returns its address.

    It runs one interactive bluetoothctl session, because a scan and an
    agent only last as long as the session that started them.
    """
    # A bond left over from an earlier pairing makes the new one fail.
    for line in (await _bluetoothctl("devices")).splitlines():
        match = _DEVICE.search(_ANSI.sub("", line))
        if match and "spotlight" in match.group(2).lower():
            await _bluetoothctl("remove", match.group(1))

    process = await asyncio.create_subprocess_exec(
        "bluetoothctl", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT)

    def send(command: str) -> None:
        process.stdin.write(f"{command}\n".encode())

    async def wait_for(pattern: re.Pattern[str], timeout: float) -> re.Match[str] | None:
        deadline = asyncio.get_running_loop().time() + timeout
        while (left := deadline - asyncio.get_running_loop().time()) > 0:
            try:
                raw = await asyncio.wait_for(process.stdout.readline(), left)
            except TimeoutError:
                return None
            if not raw:
                return None
            if match := pattern.search(_ANSI.sub("", raw.decode(errors="replace"))):
                return match
        return None

    try:
        for command in ("power on", "pairable on", "agent NoInputNoOutput", "default-agent", "scan le"):
            send(command)
        found = await wait_for(re.compile(r"Device ([0-9A-F:]{17}) .*spotlight", re.IGNORECASE), seconds)
        if not found:
            return None
        address = found.group(1)
        log.info("Pairing Spotlight %s", address)
        send("scan off")
        send(f"pair {address}")
        result = await wait_for(re.compile(r"Pairing successful|Failed to pair: (\S+)"), 30)
        if not result or result.group(0).startswith("Failed"):
            log.warning("Pairing failed: %s", result.group(1) if result else "no answer")
            return None
        send(f"trust {address}")
        send(f"connect {address}")
        await wait_for(re.compile(r"Connection successful|Failed to connect"), 15)
        return address
    finally:
        send("quit")
        try:
            await asyncio.wait_for(process.wait(), 3)
        except TimeoutError:
            process.kill()
