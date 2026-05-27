#!/usr/bin/env python3
"""
Convert the C arrays in icesugar_pro/model/src/{font,sprites,palette}.c to .mem files
that the ECP5 toolchain consumes via $readmemh.

This is meant to be called from a future gateware/ build step. The host
build does not depend on it. The C source is the source of truth — if you
change a sprite or glyph, re-run gen_roms.py first, then this.

Usage:
    python3 tools/rom_to_mem.py [--out gateware/mem]
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL_SRC = ROOT / "icesugar_pro" / "model" / "src"


def parse_c_array(path: Path, name: str) -> list[int]:
    """Pull the numeric initializers out of `const ... NAME[...] = { ... };`."""
    text = path.read_text()
    # Find the opening brace of the matching array.
    m = re.search(rf"{re.escape(name)}\s*\[[^\]]*\]\s*=\s*\{{", text)
    if not m:
        raise SystemExit(f"could not find array {name} in {path}")
    start = m.end()
    depth = 1
    end = start
    while end < len(text) and depth > 0:
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
        end += 1
    body = text[start : end - 1]
    # Strip C comments.
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    out: list[int] = []
    for tok in body.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok.startswith("0x") or tok.startswith("0X"):
            out.append(int(tok, 16))
        else:
            out.append(int(tok, 10))
    return out


def emit_mem(values: list[int], width_bits: int, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    digits = (width_bits + 3) // 4
    fmt = f"{{:0{digits}X}}"
    with out_path.open("w") as f:
        for v in values:
            f.write(fmt.format(v & ((1 << width_bits) - 1)))
            f.write("\n")
    print(f"wrote {out_path} ({len(values)} entries, {width_bits}-bit wide)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "gateware" / "mem"),
                    help="Output directory for .mem files (default: gateware/mem)")
    args = ap.parse_args()
    out_dir = Path(args.out)

    font_8x16 = parse_c_array(MODEL_SRC / "font.c", "font_8x16")
    font_16x32 = parse_c_array(MODEL_SRC / "font.c", "font_16x32")
    sprites = parse_c_array(MODEL_SRC / "sprites.c", "sprite_rom")
    pw = parse_c_array(MODEL_SRC / "palette.c", "palette_waterfall")
    pa = parse_c_array(MODEL_SRC / "palette.c", "palette_goes")

    emit_mem(font_8x16,  8,  out_dir / "font_8x16.mem")
    emit_mem(font_16x32, 16, out_dir / "font_16x32.mem")
    emit_mem(sprites,    16, out_dir / "sprite_rom.mem")
    emit_mem(pw,         16, out_dir / "palette_waterfall.mem")
    emit_mem(pa,         16, out_dir / "palette_goes.mem")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
