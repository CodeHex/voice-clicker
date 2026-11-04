"""Runs the relay: `python3 -m voiceclicker_relay`.

`--screen PATH` writes each frame to a PNG instead of the LCD, for working
on the screen layout without the HAT.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
from pathlib import Path

from .app import BUTTON_PINS, App
from .store import DEFAULT_PATH, State


async def main() -> None:
    parser = argparse.ArgumentParser(prog="voiceclicker-relay")
    parser.add_argument("--state", type=Path, default=DEFAULT_PATH)
    parser.add_argument("--screen", type=Path, help="write frames to this PNG instead of the LCD")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    if args.screen:
        app = App(State.load(args.state), show=lambda image: image.save(args.screen))
    else:
        from gpiozero import Button

        from .lcd import LCD

        lcd = LCD()
        app = App(State.load(args.state), show=lcd.show)
        loop = asyncio.get_running_loop()
        buttons = []
        for name, pin in BUTTON_PINS.items():
            button = Button(pin, pull_up=True, bounce_time=0.03)
            button.when_pressed = lambda name=name: loop.call_soon_threadsafe(app.pressed, name)
            buttons.append(button)
    await app.run()


if __name__ == "__main__":
    asyncio.run(main())
