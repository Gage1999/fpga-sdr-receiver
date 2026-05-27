#!/usr/bin/env python3
"""
Generate icesugar_pro/model/src/font.c, sprites.c, palette.c from compact descriptions.

Run from the repo root:
    python3 tools/gen_roms.py

Emits committed C source — not run at build time. The C files are the
source of truth for both the host harness and (via tools/rom_to_mem.py)
the FPGA .mem files.
"""
from __future__ import annotations

import math
import os
import sys
import textwrap
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parent.parent
MODEL_SRC = ROOT / "icesugar_pro" / "model" / "src"


# ──────────────────────────────────────────────────────────────────────────────
# 8x16 font — hand-crafted ASCII bitmap (0x20..0x7F).
# Each glyph is 16 rows of 8 bits, MSB = leftmost pixel.
# Most glyphs use a 5x7 cell rendered at rows 4..10 of the 16-row cell, with
# descenders for g, j, p, q, y reaching row 12.
# ──────────────────────────────────────────────────────────────────────────────

# Compact glyph syntax: each char gets a list of strings (one per row 4..11) where
# '#' = pixel set, '.' = clear. Missing chars fall back to a solid block.
GLYPHS_5x7 = {
    " ": ["........"] * 8,
    "!": ["..##....", "..##....", "..##....", "..##....", "..##....", "........", "..##....", "........"],
    "\"":[".##.##..", ".##.##..", ".##.##..", "........", "........", "........", "........", "........"],
    "#": [".##.##..", ".######.", ".##.##..", ".######.", ".##.##..", "........", "........", "........"],
    "$": ["..####..", ".##.....", "..####..", ".....##.", ".####...", "..##....", "........", "........"],
    "%": ["##...##.", "##..##..", "...##...", "..##.##.", "##...##.", "........", "........", "........"],
    "&": [".##.....", "##.##...", ".##.....", "##.##.#.", ".####.#.", "........", "........", "........"],
    "'": ["..##....", "..##....", "........", "........", "........", "........", "........", "........"],
    "(": [".##.....", "##......", "##......", "##......", ".##.....", "........", "........", "........"],
    ")": [".##.....", "..##....", "..##....", "..##....", ".##.....", "........", "........", "........"],
    "*": ["..#.#...", "...#....", "..###...", "...#....", "..#.#...", "........", "........", "........"],
    "+": ["........", "..##....", ".####...", "..##....", "........", "........", "........", "........"],
    ",": ["........", "........", "........", "........", "..##....", "..##....", "..#.....", "........"],
    "-": ["........", "........", ".####...", "........", "........", "........", "........", "........"],
    ".": ["........", "........", "........", "........", "..##....", "..##....", "........", "........"],
    "/": ["....##..", "...##...", "..##....", ".##.....", "##......", "........", "........", "........"],
    "0": [".####...", "##..##..", "##.###..", "###.##..", ".####...", "........", "........", "........"],
    "1": ["..##....", ".###....", "..##....", "..##....", ".####...", "........", "........", "........"],
    "2": [".####...", "##..##..", "...##...", "..##....", "######..", "........", "........", "........"],
    "3": [".####...", "##..##..", "...##...", "##..##..", ".####...", "........", "........", "........"],
    "4": ["...##...", "..###...", ".####...", "######..", "...##...", "........", "........", "........"],
    "5": ["######..", "##......", "#####...", "....##..", "#####...", "........", "........", "........"],
    "6": [".####...", "##......", "#####...", "##..##..", ".####...", "........", "........", "........"],
    "7": ["######..", "....##..", "...##...", "..##....", "..##....", "........", "........", "........"],
    "8": [".####...", "##..##..", ".####...", "##..##..", ".####...", "........", "........", "........"],
    "9": [".####...", "##..##..", ".#####..", "....##..", ".####...", "........", "........", "........"],
    ":": ["........", "..##....", "..##....", "........", "..##....", "..##....", "........", "........"],
    ";": ["........", "..##....", "..##....", "........", "..##....", "..##....", "..#.....", "........"],
    "<": ["....##..", "..##....", ".##.....", "..##....", "....##..", "........", "........", "........"],
    "=": ["........", ".####...", "........", ".####...", "........", "........", "........", "........"],
    ">": [".##.....", "..##....", "...##...", "..##....", ".##.....", "........", "........", "........"],
    "?": [".####...", "##..##..", "...##...", "........", "..##....", "........", "........", "........"],
    "@": [".####...", "##..##..", "##.###..", "##......", ".####...", "........", "........", "........"],
    "A": [".####...", "##..##..", "######..", "##..##..", "##..##..", "........", "........", "........"],
    "B": ["#####...", "##..##..", "#####...", "##..##..", "#####...", "........", "........", "........"],
    "C": [".####...", "##..##..", "##......", "##..##..", ".####...", "........", "........", "........"],
    "D": ["####....", "##.##...", "##..##..", "##.##...", "####....", "........", "........", "........"],
    "E": ["######..", "##......", "#####...", "##......", "######..", "........", "........", "........"],
    "F": ["######..", "##......", "#####...", "##......", "##......", "........", "........", "........"],
    "G": [".####...", "##......", "##.###..", "##..##..", ".####...", "........", "........", "........"],
    "H": ["##..##..", "##..##..", "######..", "##..##..", "##..##..", "........", "........", "........"],
    "I": [".####...", "..##....", "..##....", "..##....", ".####...", "........", "........", "........"],
    "J": ["..####..", "....##..", "....##..", "##..##..", ".####...", "........", "........", "........"],
    "K": ["##.##...", "####....", "###.....", "####....", "##.##...", "........", "........", "........"],
    "L": ["##......", "##......", "##......", "##......", "######..", "........", "........", "........"],
    "M": ["##..##..", "######..", "######..", "##..##..", "##..##..", "........", "........", "........"],
    "N": ["##..##..", "###.##..", "######..", "##.###..", "##..##..", "........", "........", "........"],
    "O": [".####...", "##..##..", "##..##..", "##..##..", ".####...", "........", "........", "........"],
    "P": ["#####...", "##..##..", "#####...", "##......", "##......", "........", "........", "........"],
    "Q": [".####...", "##..##..", "##.###..", "##.###..", ".#####..", "........", "........", "........"],
    "R": ["#####...", "##..##..", "#####...", "####....", "##.##...", "........", "........", "........"],
    "S": [".####...", "##......", ".####...", "....##..", "#####...", "........", "........", "........"],
    "T": ["######..", "..##....", "..##....", "..##....", "..##....", "........", "........", "........"],
    "U": ["##..##..", "##..##..", "##..##..", "##..##..", ".####...", "........", "........", "........"],
    "V": ["##..##..", "##..##..", "##..##..", ".####...", "..##....", "........", "........", "........"],
    "W": ["##..##..", "##..##..", "######..", "######..", "##..##..", "........", "........", "........"],
    "X": ["##..##..", ".####...", "..##....", ".####...", "##..##..", "........", "........", "........"],
    "Y": ["##..##..", "##..##..", ".####...", "..##....", "..##....", "........", "........", "........"],
    "Z": ["######..", "....##..", "..##....", ".##.....", "######..", "........", "........", "........"],
    "[": [".####...", ".##.....", ".##.....", ".##.....", ".####...", "........", "........", "........"],
    "\\":["##......", ".##.....", "..##....", "...##...", "....##..", "........", "........", "........"],
    "]": [".####...", "...##...", "...##...", "...##...", ".####...", "........", "........", "........"],
    "^": ["..##....", ".####...", "##..##..", "........", "........", "........", "........", "........"],
    "_": ["........", "........", "........", "........", "........", "........", "######..", "........"],
    "`": [".##.....", "..##....", "........", "........", "........", "........", "........", "........"],
    "{": ["..###...", "..##....", ".###....", "..##....", "..###...", "........", "........", "........"],
    "|": ["..##....", "..##....", "..##....", "..##....", "..##....", "........", "........", "........"],
    "}": [".###....", "..##....", "..###...", "..##....", ".###....", "........", "........", "........"],
    "~": [".#..##..", "######..", ".##..#..", "........", "........", "........", "........", "........"],
}

# Lowercase reuses uppercase shape (chunky bitmap font, common trick for tight ROMs).
for c in "abcdefghijklmnopqrstuvwxyz":
    GLYPHS_5x7[c] = GLYPHS_5x7[c.upper()]


def render_glyph_8x16(rows8: list[str]) -> list[int]:
    """rows8 is 8 strings (each 8 chars) for rows 4..11. Pad to 16 with blanks."""
    out = [0] * 16
    for i, r in enumerate(rows8):
        bits = 0
        for j in range(8):
            if r[j] == "#":
                bits |= (1 << (7 - j))
        out[4 + i] = bits
    return out


def build_font_8x16() -> list[int]:
    bytes_out = []
    fallback = [0xFF if r in (2, 14) else 0x81 for r in range(16)]  # box outline
    for code in range(0x20, 0x80):
        ch = chr(code)
        if ch in GLYPHS_5x7:
            bytes_out.extend(render_glyph_8x16(GLYPHS_5x7[ch]))
        else:
            bytes_out.extend(fallback)
    return bytes_out


def build_font_16x32(font_8x16: list[int]) -> list[int]:
    """Upscale 8x16 → 16x32 by 2x nearest-neighbor. Each row is one uint16_t."""
    out_rows: list[int] = []
    for ch_idx in range(96):
        for src_row in range(16):
            byte = font_8x16[ch_idx * 16 + src_row]
            doubled = 0
            for bit in range(8):
                if byte & (1 << bit):
                    doubled |= (3 << (bit * 2))
            for _ in range(2):
                out_rows.append(doubled)
    return out_rows


# ──────────────────────────────────────────────────────────────────────────────
# Sprites: 16 procedurally-generated 32x32 RGB565 button icons.
# ──────────────────────────────────────────────────────────────────────────────

SPRITE_W = 32
SPRITE_H = 32


def rgb565(r: int, g: int, b: int) -> int:
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3)


def sprite_button_bg(theme: tuple[int, int, int], outline: tuple[int, int, int]) -> list[int]:
    """Rounded-rect button background with outline."""
    px = [0] * (SPRITE_W * SPRITE_H)
    bg = rgb565(*theme)
    ol = rgb565(*outline)
    bg_dark = rgb565(theme[0] // 2, theme[1] // 2, theme[2] // 2)
    for y in range(SPRITE_H):
        for x in range(SPRITE_W):
            edge_dist = min(x, y, SPRITE_W - 1 - x, SPRITE_H - 1 - y)
            corner = (x < 3 or x > SPRITE_W - 4) and (y < 3 or y > SPRITE_H - 4)
            cx = x if x < SPRITE_W // 2 else SPRITE_W - 1 - x
            cy = y if y < SPRITE_H // 2 else SPRITE_H - 1 - y
            if cx + cy < 3:
                px[y * SPRITE_W + x] = 0  # transparent corner
            elif edge_dist == 0 or (corner and cx + cy < 4):
                px[y * SPRITE_W + x] = 0
            elif edge_dist <= 1:
                px[y * SPRITE_W + x] = ol
            else:
                # vertical gradient for a faux bevel
                t = y / SPRITE_H
                shade = int((1 - t) * 255 + t * 180) / 255.0
                r = int(theme[0] * shade)
                g = int(theme[1] * shade)
                b = int(theme[2] * shade)
                px[y * SPRITE_W + x] = rgb565(r, g, b)
    return px


def draw_glyph_into(px: list[int], glyph: list[str], ox: int, oy: int, color: int):
    """Stamp a 7-row glyph (list of 5-wide rows) starting at (ox, oy)."""
    for r, row in enumerate(glyph):
        for c, ch in enumerate(row):
            if ch == "#":
                x = ox + c
                y = oy + r
                if 0 <= x < SPRITE_W and 0 <= y < SPRITE_H:
                    px[y * SPRITE_W + x] = color


# Compact ad-hoc 5x7 glyphs for icon labels.
ICON_GLYPHS = {
    "UP":  [
        ".....",
        "..#..",
        ".###.",
        "#.#.#",
        "..#..",
        "..#..",
        "..#..",
    ],
    "DN":  [
        "..#..",
        "..#..",
        "..#..",
        "#.#.#",
        ".###.",
        "..#..",
        ".....",
    ],
    "VP":  [
        "#...#",
        "#...#",
        ".#.#.",
        ".#.#.",
        "..#..",
        "..#..",
        ".###.",
    ],
    "FM":  [
        "###.#",
        "#...#",
        "##.##",
        "#...#",
        "#...#",
        "#...#",
        ".....",
    ],
    "AM":  [
        ".#..#",
        "#.#.#",
        "#.###",
        "###.#",
        "#...#",
        "#...#",
        ".....",
    ],
    "GOES": [
        ".#.##",
        "#.##.",
        "###..",
        "#.#.#",
        "#.#.#",
        ".....",
        ".....",
    ],
    "REC": [
        ".###.",
        "#####",
        "#####",
        "#####",
        "#####",
        ".###.",
        ".....",
    ],
    "MUTE":[
        "#....",
        "##.#.",
        "###.#",
        "##.#.",
        "#....",
        "..#..",
        ".###.",
    ],
    "GEAR":[
        "..#..",
        "#.#.#",
        ".###.",
        "##.##",
        ".###.",
        "#.#.#",
        "..#..",
    ],
    "LAY": [
        "#####",
        "#####",
        ".....",
        "##.##",
        "##.##",
        ".....",
        "#####",
    ],
    "SAT": [
        ".#.#.",
        "###.#",
        "###..",
        ".###.",
        "#.###",
        ".#.#.",
        ".....",
    ],
    "LOCK":[
        ".###.",
        "#...#",
        "#...#",
        "#####",
        "##.##",
        "#####",
        ".....",
    ],
    "BLANK":[
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
    ],
}


def build_sprite(theme: tuple[int, int, int], label_key: str, label_color=(255, 255, 255)) -> list[int]:
    px = sprite_button_bg(theme, (theme[0] // 3, theme[1] // 3, theme[2] // 3))
    glyph = ICON_GLYPHS[label_key]
    glyph_w = len(glyph[0])
    glyph_h = len(glyph)
    ox = (SPRITE_W - glyph_w * 3) // 2
    oy = (SPRITE_H - glyph_h * 3) // 2
    col = rgb565(*label_color)
    # 3x scale for visibility
    for r, row in enumerate(glyph):
        for c, ch in enumerate(row):
            if ch == "#":
                for dy in range(3):
                    for dx in range(3):
                        x = ox + c * 3 + dx
                        y = oy + r * 3 + dy
                        if 0 <= x < SPRITE_W and 0 <= y < SPRITE_H:
                            px[y * SPRITE_W + x] = col
    return px


SPRITE_DEFS = [
    ("SPR_BTN_FREQ_UP",  (60, 110, 180), "UP"),
    ("SPR_BTN_FREQ_DN",  (60, 110, 180), "DN"),
    ("SPR_BTN_VOL_UP",   (60, 140, 100), "UP"),
    ("SPR_BTN_VOL_DN",   (60, 140, 100), "DN"),
    ("SPR_BTN_MODE_FM",  (140, 100, 50), "FM"),
    ("SPR_BTN_MODE_AM",  (140, 100, 50), "AM"),
    ("SPR_BTN_MODE_GOES", (140, 100, 50), "GOES"),
    ("SPR_BTN_LAYOUT",   (80, 80, 120), "LAY"),
    ("SPR_BTN_REC",      (120, 60, 60), "REC"),
    ("SPR_BTN_REC_ON",   (220, 40, 40), "REC"),
    ("SPR_BTN_MUTE",     (90, 90, 90), "MUTE"),
    ("SPR_BTN_MUTE_ON",  (220, 180, 40), "MUTE"),
    ("SPR_ICON_SAT",     (40, 60, 100), "SAT"),
    ("SPR_ICON_GEAR",    (90, 90, 90), "GEAR"),
    ("SPR_ICON_RFLOCK",  (140, 50, 50), "LOCK"),
    ("SPR_ICON_BLANK",   (50, 50, 50), "BLANK"),
]


# ──────────────────────────────────────────────────────────────────────────────
# Palettes
# ──────────────────────────────────────────────────────────────────────────────

def palette_viridis() -> list[int]:
    # Approximation via piecewise blend through known viridis anchors.
    anchors = [
        (0.0,  (68,   1,  84)),
        (0.25, (59,  82, 139)),
        (0.5,  (33, 144, 141)),
        (0.75, (94, 201,  98)),
        (1.0,  (253, 231,  37)),
    ]
    out: list[int] = []
    for i in range(256):
        t = i / 255.0
        for k in range(len(anchors) - 1):
            t0, c0 = anchors[k]
            t1, c1 = anchors[k + 1]
            if t0 <= t <= t1:
                u = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
                r = int(c0[0] + (c1[0] - c0[0]) * u)
                g = int(c0[1] + (c1[1] - c0[1]) * u)
                b = int(c0[2] + (c1[2] - c0[2]) * u)
                out.append(rgb565(r, g, b))
                break
    return out


def palette_goes_grayscale_tint() -> list[int]:
    out: list[int] = []
    for i in range(256):
        r = i
        g = min(255, int(i * 1.05))
        b = min(255, int(i * 0.95))
        out.append(rgb565(r, g, b))
    return out


# ──────────────────────────────────────────────────────────────────────────────
# Emitters
# ──────────────────────────────────────────────────────────────────────────────

BANNER = (
    "// Generated by tools/gen_roms.py — DO NOT EDIT BY HAND.\n"
    "// Re-run the generator if the underlying glyph/sprite definitions change.\n"
)


def emit_bytes(values: Iterable[int], per_line: int = 16) -> str:
    chunks: list[str] = []
    buf: list[str] = []
    for i, v in enumerate(values):
        buf.append(f"0x{v & 0xFF:02X}")
        if (i + 1) % per_line == 0:
            chunks.append("    " + ", ".join(buf) + ",")
            buf = []
    if buf:
        chunks.append("    " + ", ".join(buf) + ",")
    return "\n".join(chunks)


def emit_halfwords(values: Iterable[int], per_line: int = 12) -> str:
    chunks: list[str] = []
    buf: list[str] = []
    for i, v in enumerate(values):
        buf.append(f"0x{v & 0xFFFF:04X}")
        if (i + 1) % per_line == 0:
            chunks.append("    " + ", ".join(buf) + ",")
            buf = []
    if buf:
        chunks.append("    " + ", ".join(buf) + ",")
    return "\n".join(chunks)


def write_font_c():
    font_8x16 = build_font_8x16()
    font_16x32 = build_font_16x32(font_8x16)

    out = BANNER + '#include "font.h"\n\n'
    out += "const uint8_t font_8x16[FONT_8X16_COUNT * FONT_8X16_H] = {\n"
    out += emit_bytes(font_8x16)
    out += "\n};\n\n"
    out += "const uint16_t font_16x32[FONT_16X32_COUNT * FONT_16X32_H] = {\n"
    out += emit_halfwords(font_16x32)
    out += "\n};\n"

    (MODEL_SRC / "font.c").write_text(out)
    print(f"wrote {MODEL_SRC / 'font.c'} ({len(font_8x16)} + {len(font_16x32)*2} bytes of glyph data)")


def write_sprites_c():
    pixels: list[int] = []
    for _name, theme, label in SPRITE_DEFS:
        pixels.extend(build_sprite(theme, label))
    assert len(pixels) == 16 * SPRITE_W * SPRITE_H

    out = BANNER + '#include "sprites.h"\n\n'
    out += "const uint16_t sprite_rom[SPRITE_COUNT * SPRITE_PIXELS] = {\n"
    out += emit_halfwords(pixels)
    out += "\n};\n"
    (MODEL_SRC / "sprites.c").write_text(out)
    print(f"wrote {MODEL_SRC / 'sprites.c'} ({len(pixels)*2} bytes)")


def write_palette_c():
    waterfall = palette_viridis()
    goes = palette_goes_grayscale_tint()

    out = BANNER + '#include "palette.h"\n\n'
    out += "const uint16_t palette_waterfall[PALETTE_SIZE] = {\n"
    out += emit_halfwords(waterfall)
    out += "\n};\n\n"
    out += "const uint16_t palette_goes[PALETTE_SIZE] = {\n"
    out += emit_halfwords(goes)
    out += "\n};\n"
    (MODEL_SRC / "palette.c").write_text(out)
    print(f"wrote {MODEL_SRC / 'palette.c'}")


def main() -> int:
    MODEL_SRC.mkdir(parents=True, exist_ok=True)
    write_font_c()
    write_sprites_c()
    write_palette_c()
    return 0


if __name__ == "__main__":
    sys.exit(main())
