# ADS-B basemap assets

The ADS-B map mode shows a static basemap centered on a location (UCR campus by
default), with range rings and aircraft drawn on top by the compositor. The
basemap is an 800x448 RGB565 image - ~700 KB, too big for EBR, so it lives in
SDRAM (`ADSB_BASEMAP`, see [`../../../docs/fpga-sdr-receiver-architecture.md`](../../../docs/fpga-sdr-receiver-architecture.md)
section 6) loaded from SPI config flash at boot.

Generate it with [`tools/map_to_rom.py`](../../../tools/map_to_rom.py):

```sh
# UCR campus, 75-mi radius (outer ring) -> 800x448 RGB565
python3 tools/map_to_rom.py --lat 33.9737 --lon -117.3281

# Dark, muted display asset
python3 tools/map_to_rom.py --lat 33.9737 --lon -117.3281 --dark
```

Outputs (this directory):

| File | Use |
|---|---|
| `riverside_ucr.bin` | little-endian RGB565, row-major - the flash/SDRAM image |
| `riverside_ucr.mem` | hex halfwords for `$readmemh` in simulation |
| `riverside_ucr.png` | 565-roundtrip preview (on-device colors) |
| `riverside_ucr.json` | projection metadata (center, zoom, m/px) for plane placement |

The `.bin` and `.mem` are large generated artifacts and are **git-ignored** -
regenerate them rather than committing. The `.png` preview and `.json` are kept
so the map and its scale are visible in the repo.

**Map data** defaults to OpenStreetMap ((c) OpenStreetMap contributors, ODbL).
Follow the [tile usage policy](https://operations.osmfoundation.org/policies/tiles/),
and point `--tile-url` at a provider whose terms permit embedding before shipping.
The `--dark` option is a post-process pass; for truly sparse labels or road
lines, use `--tile-url` with a provider/style that renders fewer features.

The scale is the logical source-map scale: the center pixel is the requested
location and the 75-mi outer ring sits at `height/2` = 224 px
(`ADSB_R_OUTER` in `../include/fb_compositor.h`). The renderer fits this
800x448 source below the ADS-B header and scales aircraft positions with it.
Aircraft are projected from their range/bearing off the center using
`meters_per_px` from the `.json`.
