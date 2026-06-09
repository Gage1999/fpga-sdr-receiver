# PlutoSky 7020 Runtime

This folder contains the PlutoSky/Zynq side of the SDR receiver. PlutoSky owns
the AD9363 RF front end, captures IQ samples, and streams data to the iCeSugar
Pro over JP5 SPI.

The final runtime is `src/main.c`, built as `sdr_main`.

## Final Demo Pairing

Program the iCeSugar Pro first:

```powershell
cd ..\icesugar_pro
make prog
```

Then run the PlutoSky FM path:

```powershell
cd ..\plutosky
make radio-run FREQ_MHZ=95.1
```

Use a strong local FM station for `FREQ_MHZ`.

## What Runs On PlutoSky

| File | Purpose |
|---|---|
| `src/main.c` | Final combined FM/GOES/ADS-B runtime (`sdr_main`) |
| `src/ads_stream.c` | ADS-B decoder/runtime code, built into `sdr_main` |
| `src/goes_stream.c` | GOES/LRIT stream processing, built into `sdr_main` |
| `src/goes_lrit.c` | GOES/LRIT support code |
| `src/icesugar_stream.c` | Standalone TLV IQ streamer diagnostic |
| `tests/test_spi_reg.c` | AXI SPI register sanity test |

`icesugar_stream.c` is not part of the final runtime. It remains useful for
isolating the Pluto-to-iCeSugar SPI/TLV path.

## Make Targets

| Target | Purpose |
|---|---|
| `make sdr-build` | Build `/root/sdr_main` locally in `build/` |
| `make sdr-run SDR_MODE=fm SDR_FREQ=95.1` | Deploy and run `sdr_main` |
| `make radio-run FREQ_MHZ=95.1` | Convenience FM demo target |
| `make spi-reg-run` | Verify AXI SPI register access at `0x7C440000` |
| `make stream-run STREAM_ARGS="..."` | Run standalone IQ streamer diagnostic |
| `make synth-fm-run` | Send synthetic FM IQ through the diagnostic streamer |
| `make goes-test` | Standalone GOES dry-run diagnostic |
| `make ads-test` | Standalone ADS-B dry-run diagnostic |

The Makefile assumes the board is reachable as `root@192.168.2.1`. Override it
with:

```powershell
make radio-run PLUTO=<ip-address> FREQ_MHZ=95.1
```

## Repository Layout

| Path | Purpose |
|---|---|
| `src/fishball7020_rf/` | Vivado project scripts and Zynq block design |
| `src/boot_parts/` | BOOT.BIN inputs and BIF file |
| `src/board/` | Scripts installed to persistent JFFS2 storage |
| `src/maia-sdr/` | Maia SDR submodule |
| `docs/architecture.md` | PlutoSky hardware, boot chain, and AXI map |
| `docs/build_guide.md` | Full rebuild/deploy instructions |
| `docs/ssh_setup.md` | Persistent SSH key setup |

## Notes

- JP5 SPI is driven by the PlutoSky AXI Quad SPI core at `0x7C440000`.
- MOSI carries TLV IQ/result packets to the iCeSugar Pro.
- MISO carries radio command frames back from iCeSugar/Pico to `sdr_main`.
- FM is the showcase path. GOES and ADS-B remain documented extension modes in
  the combined runtime and protocol.
