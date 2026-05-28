#!/usr/bin/env python3
"""
Fetch a slippy-map basemap centered on a location and emit it as an RGB565
asset for the ADS-B map mode (icesugar_pro/model/src/fb_compositor.c).

Like tools/gen_roms.py this is run by hand, not at build time. It produces the
static basemap the ECP5 blits into the ADS-B region (800x448) from SDRAM; the
range rings and aircraft dots are drawn on top by the compositor. The output
scale matches the renderer: the center pixel is the requested location, and the
75-mi outer range ring (ADSB_R_OUTER = 224 px in fb_compositor.h) sits at
height/2, i.e. radius_mi maps to height/2 pixels.

    # UCR campus, default 75-mi radius -> 800x448 RGB565
    python3 tools/map_to_rom.py --lat 33.9737 --lon -117.3281

Outputs (default icesugar_pro/model/assets/<name>.*):
    <name>.bin    little-endian RGB565, row-major  (width*height*2 bytes)
                  -> the SDRAM/flash image the gateware loads into ADSB_BASEMAP
    <name>.mem    one 4-hex-digit halfword per line  -> $readmemh for sim
    <name>.png    565-roundtrip preview (on-device colors)
    <name>.json   projection metadata (center, zoom, m/px) for plane placement

Use --dark to post-process source tiles into the same low-brightness night
style used by the simulator. This does not semantically remove map labels or
roads; use --tile-url with a sparse/dark tile provider for that.

Map data: defaults to the OpenStreetMap standard tile server. OSM tiles are
© OpenStreetMap contributors (ODbL). Follow the tile usage policy
(https://operations.osmfoundation.org/policies/tiles/): real User-Agent, no bulk
downloading. Point --tile-url at a provider whose terms permit embedding before
shipping a build.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "icesugar_pro" / "model" / "assets"

TILE_SIZE = 256
EARTH_C = 156543.03392  # equatorial m/px at zoom 0
MI_TO_M = 1609.344


def rgb565(r: int, g: int, b: int) -> int:
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3)


def latlon_to_global_px(lat: float, lon: float, z: int) -> tuple[float, float]:
    """Web-Mercator global pixel coordinate at zoom z (TILE_SIZE px tiles)."""
    siny = math.sin(math.radians(lat))
    siny = min(max(siny, -0.9999), 0.9999)
    n = TILE_SIZE * (2 ** z)
    x = (lon + 180.0) / 360.0 * n
    y = (0.5 - math.log((1 + siny) / (1 - siny)) / (4 * math.pi)) * n
    return x, y


def meters_per_px(lat: float, z: int) -> float:
    return EARTH_C * math.cos(math.radians(lat)) / (2 ** z)


def pick_zoom(lat: float, target_mpp: float) -> int:
    """Smallest zoom whose native resolution is finer than target (so we downscale)."""
    z = math.ceil(math.log2(EARTH_C * math.cos(math.radians(lat)) / target_mpp))
    return max(1, min(19, int(z)))


def fetch_tile(url_tmpl: str, z: int, x: int, y: int, ua: str, cache: Path):
    from PIL import Image
    cache.mkdir(parents=True, exist_ok=True)
    cp = cache / f"{z}_{x}_{y}.png"
    if cp.exists():
        return Image.open(cp).convert("RGB")
    url = url_tmpl.format(z=z, x=x, y=y)
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    data = urllib.request.urlopen(req, timeout=20).read()
    cp.write_bytes(data)
    time.sleep(0.1)  # be polite to the tile server
    return Image.open(cp).convert("RGB")


def build_map(args) -> "tuple":
    from PIL import Image

    # Scale: full height spans 2*radius (outer ring = radius = height/2 px).
    target_mpp = (2.0 * args.radius_mi * MI_TO_M) / args.height
    z = args.zoom if args.zoom is not None else pick_zoom(args.lat, target_mpp)
    native_mpp = meters_per_px(args.lat, z)

    # Source rect (in zoom-z pixels) covering the same ground as the output.
    ratio = target_mpp / native_mpp  # >= 1 when we downscale
    src_w = args.width * ratio
    src_h = args.height * ratio
    cx, cy = latlon_to_global_px(args.lat, args.lon, z)
    left, top = cx - src_w / 2.0, cy - src_h / 2.0
    right, bottom = cx + src_w / 2.0, cy + src_h / 2.0

    tx0, ty0 = int(math.floor(left / TILE_SIZE)), int(math.floor(top / TILE_SIZE))
    tx1, ty1 = int(math.floor((right - 1) / TILE_SIZE)), int(math.floor((bottom - 1) / TILE_SIZE))
    n_tiles = (tx1 - tx0 + 1) * (ty1 - ty0 + 1)
    print(f"zoom {z}, native {native_mpp:.1f} m/px, target {target_mpp:.1f} m/px, "
          f"{n_tiles} tiles ({tx1-tx0+1}x{ty1-ty0+1})", file=sys.stderr)
    if n_tiles > args.max_tiles:
        sys.exit(f"would need {n_tiles} tiles (> --max-tiles {args.max_tiles}); "
                 f"lower --radius-mi or pass a smaller --zoom")

    stitched = Image.new("RGB", ((tx1 - tx0 + 1) * TILE_SIZE, (ty1 - ty0 + 1) * TILE_SIZE),
                         (40, 40, 40))
    cache = Path(args.cache_dir)
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            try:
                tile = fetch_tile(args.tile_url, z, tx, ty, args.user_agent, cache)
                stitched.paste(tile, ((tx - tx0) * TILE_SIZE, (ty - ty0) * TILE_SIZE))
            except Exception as e:  # noqa: BLE001 — leave a gray hole, keep going
                print(f"  tile {z}/{tx}/{ty} failed: {e}", file=sys.stderr)

    crop = stitched.crop((int(round(left - tx0 * TILE_SIZE)),
                          int(round(top - ty0 * TILE_SIZE)),
                          int(round(left - tx0 * TILE_SIZE)) + int(round(src_w)),
                          int(round(top - ty0 * TILE_SIZE)) + int(round(src_h))))
    img = crop.resize((args.width, args.height), Image.LANCZOS)
    return img, {"center_lat": args.lat, "center_lon": args.lon, "zoom": z,
                 "meters_per_px": round(target_mpp, 3), "width": args.width,
                 "height": args.height, "radius_mi": args.radius_mi,
                 "outer_ring_px": args.height // 2}


def apply_display_style(img, dark: bool):
    if not dark:
        return img

    rgb = img.convert("RGB")
    px = rgb.load()
    w, h = rgb.size
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            gray = (30 * r + 59 * g + 11 * b) // 100
            nr = (gray * 20) // 100
            ng = (gray * 28) // 100
            nb = min(104, 12 + (gray * 42) // 100)
            px[x, y] = (nr, ng, nb)
    return rgb


def emit(img, meta, out_dir: Path, name: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    rgb = img.convert("RGB")
    w, h = rgb.size
    px = rgb.load()

    blob = bytearray(w * h * 2)
    mem_lines = []
    preview = rgb.copy()
    pp = preview.load()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            v = rgb565(r, g, b)
            i = (y * w + x) * 2
            blob[i] = v & 0xFF          # little-endian on the wire
            blob[i + 1] = (v >> 8) & 0xFF
            mem_lines.append(f"{v:04X}")
            # 565 round-trip so the preview shows on-device colors
            pp[x, y] = (v >> 8 & 0xF8, (v >> 3) & 0xFC, (v << 3) & 0xF8)

    (out_dir / f"{name}.bin").write_bytes(blob)
    (out_dir / f"{name}.mem").write_text("\n".join(mem_lines) + "\n")
    preview.save(out_dir / f"{name}.png")
    (out_dir / f"{name}.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"wrote {out_dir / name}.{{bin,mem,png,json}} "
          f"({len(blob)} bytes RGB565, {w}x{h})", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description="Fetch a basemap as an RGB565 ADS-B map asset.")
    ap.add_argument("--lat", type=float, required=True, help="center latitude (deg)")
    ap.add_argument("--lon", type=float, required=True, help="center longitude (deg)")
    ap.add_argument("--radius-mi", type=float, default=75.0,
                    help="ground radius at the outer ring (default 75)")
    ap.add_argument("--width", type=int, default=800)
    ap.add_argument("--height", type=int, default=448)
    ap.add_argument("--zoom", type=int, default=None, help="override auto-selected zoom")
    ap.add_argument("--name", default="riverside_ucr", help="output basename")
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--tile-url",
                    default="https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                    help="slippy-tile URL template with {z}/{x}/{y}")
    ap.add_argument("--dark", action="store_true",
                    help="mute source tiles into a dark, low-detail display style")
    ap.add_argument("--user-agent",
                    default="fpga-sdr-receiver-maptool/0.1 (UCR CS122A project)")
    ap.add_argument("--cache-dir", default=str(ROOT / ".cache" / "map_tiles"))
    ap.add_argument("--max-tiles", type=int, default=64)
    args = ap.parse_args()

    img, meta = build_map(args)
    img = apply_display_style(img, args.dark)
    meta["style"] = "dark" if args.dark else "source"
    emit(img, meta, args.out_dir, args.name)
    print("map data © OpenStreetMap contributors (ODbL) unless --tile-url overridden",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
