"""Draws the relay's 240x240 screen: green on black, one monospace font."""

from __future__ import annotations

import random
from dataclasses import dataclass, field

from PIL import Image, ImageDraw, ImageFont

SIZE = 240
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
BOLD_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"

BLACK = (0, 0, 0)
GREEN = (0, 255, 65)
MID = (0, 170, 45)
DIM = (0, 90, 25)
DARK = (0, 35, 10)
AMBER = (255, 190, 0)
RED = (255, 60, 60)

RAIN = "01<>/\\=+*:#$%&"


@dataclass
class MacRow:
    name: str
    # "paired", "new" (found, not paired), "offline" (paired, not on the network) or "pairing"
    status: str
    active: bool = False


@dataclass
class View:
    macs: list[MacRow] = field(default_factory=list)
    cursor: int = 0
    spotlight: bool = False
    battery: int | None = None
    # "main", "pair" (pairing a Mac), "spotlight" (pairing the Spotlight) or "info"
    mode: str = "main"
    # A big word shown for a moment, such as NEXT or BACK.
    flash: str | None = None
    # The lines of a pairing or info screen.
    title: str = ""
    lines: list[str] = field(default_factory=list)
    code: str | None = None
    hints: tuple[str, str, str] = ("PAIR", "BT", "INFO")
    # Increases every frame, so the rain moves.
    tick: int = 0


def _font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    try:
        return ImageFont.truetype(BOLD_PATH if bold else FONT_PATH, size)
    except OSError:
        return ImageFont.load_default(size)


class Renderer:
    def __init__(self) -> None:
        self.small = _font(13)
        self.body = _font(17)
        self.body_bold = _font(17, bold=True)
        self.title = _font(20, bold=True)
        self.big = _font(44, bold=True)
        self.code = _font(46, bold=True)
        columns = SIZE // 12
        self._drops = [random.Random(c).randrange(0, 30) for c in range(columns)]

    def render(self, view: View) -> Image.Image:
        image = Image.new("RGB", (SIZE, SIZE), BLACK)
        draw = ImageDraw.Draw(image)
        self._header(draw, view.tick)
        if view.mode == "main":
            self._main(draw, view)
        else:
            self._panel(draw, view)
        self._hints(draw, view.hints)
        if view.flash:
            self._flash(draw, view.flash)
        return image

    def _header(self, draw: ImageDraw.ImageDraw, tick: int) -> None:
        draw.rectangle([0, 0, SIZE, 30], fill=DARK)
        rng = random.Random(tick // 2)
        for column, start in enumerate(self._drops):
            head = (start + tick) % 6
            for row in range(3):
                shade = MID if row == head % 3 else DIM
                draw.text((column * 12 + 1, row * 10 - 2), rng.choice(RAIN), font=self.small, fill=shade)
        draw.text((SIZE // 2, 16), "VOICE//CLICKER", font=self.title, fill=GREEN, anchor="mm",
                  stroke_width=3, stroke_fill=BLACK)
        draw.line([0, 30, SIZE, 30], fill=MID)

    def _main(self, draw: ImageDraw.ImageDraw, view: View) -> None:
        if view.spotlight:
            level = f"{view.battery}%" if view.battery is not None else ""
            draw.text((8, 38), "SPOTLIGHT", font=self.body_bold, fill=GREEN)
            draw.text((232, 38), f"ON {level}".strip(), font=self.body, fill=GREEN, anchor="ra")
        else:
            draw.text((8, 38), "SPOTLIGHT", font=self.body_bold, fill=DIM)
            draw.text((232, 38), "ASLEEP", font=self.body, fill=AMBER, anchor="ra")
        draw.line([8, 62, 232, 62], fill=DIM)
        if not view.macs:
            draw.text((SIZE // 2, 110), "SEARCHING FOR", font=self.body, fill=MID, anchor="mm")
            draw.text((SIZE // 2, 132), "VOICE CLICKER", font=self.body, fill=MID, anchor="mm")
            draw.text((SIZE // 2, 154), "MACS" + "." * (view.tick // 3 % 4), font=self.body, fill=MID, anchor="mm")
            return
        top = 68
        visible = 5
        first = min(max(0, view.cursor - visible + 1), max(0, len(view.macs) - visible))
        for index, mac in enumerate(view.macs[first:first + visible], start=first):
            y = top + (index - first) * 28
            selected = index == view.cursor
            if selected:
                draw.rectangle([4, y, 236, y + 25], outline=GREEN)
            colour = GREEN if mac.status == "paired" else DIM if mac.status == "offline" else MID
            marker = ">" if mac.active else " "
            name = mac.name if len(mac.name) <= 13 else mac.name[:12] + "~"
            draw.text((10, y + 4), f"{marker}{name}", font=self.body_bold if mac.active else self.body, fill=colour)
            badge = {"paired": "OK", "new": "NEW", "offline": "OFF", "pairing": "..."}[mac.status]
            badge_colour = AMBER if mac.status == "new" else colour
            draw.text((230, y + 4), badge, font=self.body, fill=badge_colour, anchor="ra")

    def _panel(self, draw: ImageDraw.ImageDraw, view: View) -> None:
        draw.text((SIZE // 2, 48), view.title, font=self.body_bold, fill=GREEN, anchor="mm")
        y = 70
        if view.code:
            spaced = f"{view.code[:3]} {view.code[3:]}"
            draw.rectangle([10, y, 230, y + 58], outline=GREEN)
            draw.text((SIZE // 2, y + 30), spaced, font=self.code, fill=GREEN, anchor="mm")
            y += 70
        for line in view.lines:
            draw.text((SIZE // 2, y + 8), line, font=self.body, fill=MID, anchor="mm")
            y += 22

    def _hints(self, draw: ImageDraw.ImageDraw, hints: tuple[str, str, str]) -> None:
        draw.line([0, 214, SIZE, 214], fill=DIM)
        for slot, label in enumerate(hints):
            if label:
                x = 40 + slot * 80
                draw.text((x, 228), f"{slot + 1}:{label}", font=self.small, fill=MID, anchor="mm")

    def _flash(self, draw: ImageDraw.ImageDraw, word: str) -> None:
        draw.rectangle([20, 80, 220, 160], fill=BLACK, outline=GREEN, width=2)
        draw.text((SIZE // 2, 120), word, font=self.big, fill=GREEN, anchor="mm")
