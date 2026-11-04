"""Driver for the Waveshare 1.3 inch LCD HAT: an ST7789 240x240 panel on SPI0."""

from __future__ import annotations

import time

import numpy as np
import spidev
from gpiozero import DigitalOutputDevice
from PIL import Image

WIDTH = HEIGHT = 240

# BCM pin numbers from the HAT's schematic.
PIN_DC = 25
PIN_RST = 27
PIN_BACKLIGHT = 24

# Waveshare's init sequence for this panel: (command, data).
_INIT = [
    (0x36, [0x70]),  # memory access order: landscape, joystick on the left
    (0x3A, [0x05]),  # 16-bit colour
    (0xB2, [0x0C, 0x0C, 0x00, 0x33, 0x33]),
    (0xB7, [0x35]),
    (0xBB, [0x19]),
    (0xC0, [0x2C]),
    (0xC2, [0x01]),
    (0xC3, [0x12]),
    (0xC4, [0x20]),
    (0xC6, [0x0F]),
    (0xD0, [0xA4, 0xA1]),
    (0xE0, [0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B, 0x3F, 0x54, 0x4C, 0x18, 0x0D, 0x0B, 0x1F, 0x23]),
    (0xE1, [0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C, 0x3F, 0x44, 0x51, 0x2F, 0x1F, 0x1F, 0x20, 0x23]),
    (0x21, []),  # colour inversion on, which this panel needs
]


def rgb565(image: Image.Image) -> bytes:
    """The image as big-endian RGB565, the panel's pixel format."""
    pixels = np.asarray(image.convert("RGB"), dtype=np.uint16)
    value = ((pixels[..., 0] & 0xF8) << 8) | ((pixels[..., 1] & 0xFC) << 3) | (pixels[..., 2] >> 3)
    return value.astype(">u2").tobytes()


class LCD:
    def __init__(self, spi_hz: int = 40_000_000):
        self.spi = spidev.SpiDev()
        self.spi.open(0, 0)
        self.spi.max_speed_hz = spi_hz
        self.spi.mode = 0
        self.dc = DigitalOutputDevice(PIN_DC)
        self.rst = DigitalOutputDevice(PIN_RST)
        self.backlight = DigitalOutputDevice(PIN_BACKLIGHT)
        self._reset()
        for command, data in _INIT:
            self._command(command, data)
        self._command(0x11)  # sleep out
        time.sleep(0.12)
        self._command(0x29)  # display on
        self.backlight.on()

    def show(self, image: Image.Image) -> None:
        self._command(0x2A, [0, 0, 0, WIDTH - 1])
        self._command(0x2B, [0, 0, 0, HEIGHT - 1])
        self._command(0x2C)
        self.dc.on()
        self.spi.writebytes2(rgb565(image))

    def close(self) -> None:
        self.backlight.off()
        self.spi.close()

    def _reset(self) -> None:
        for state in (True, False, True):
            self.rst.value = state
            time.sleep(0.01)

    def _command(self, command: int, data: list[int] | None = None) -> None:
        self.dc.off()
        self.spi.writebytes([command])
        if data:
            self.dc.on()
            self.spi.writebytes(data)
