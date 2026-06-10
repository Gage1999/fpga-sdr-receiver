#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "symbols.typ": antenna
#let i2c = $"I"^2"C"$
#let i2s = $"I"^2"S"$

#figure(
  diagram(
    spacing: (12mm, 11mm),
    node-stroke: 0.5pt,
    node-corner-radius: 3pt,
    node-inset: 7pt,
    {
      node((-0, -1), inset: -8pt, antenna, stroke: none, name: <antenna>)
      node((0, 0), [PlutoSky 7020\ AD9363 + Zynq], name: <sdr>)
      node((2, 0), [iCESugar-Pro\ ECP5 FPGA], height: 16mm, name: <fpga>)
      node((4, -1), [LCD Display\ FM / GOES / ADS-B], name: <screen>)
      node((4, 0.5), [GT911\ Touch], name: <touch>)
      node((4, 1.8), [Pico 2W], name: <pico>)
      node((1.3, 1.6), [PCM5102\ DAC], name: <dac>)
      node((2.7, 1.6), [Speaker], stroke: none, name: <speaker>)

      edge(<antenna>, <sdr>, "->", label: [RF])
      edge(<sdr>, <fpga>, "->", label: [JP5 SPI (IQ)], bend: 16deg)
      edge(<fpga>, <sdr>, "->", label: [tuning], bend: 16deg, label-side: right)
      edge(<fpga>, <screen>, "->", label: [16-bit RGB])
      edge(<screen>, <touch>, "->", label: [touch], stroke: (dash: "dashed"))
      edge(<touch>, <pico>, "->", label: [#i2c])
      edge(<pico>, <fpga>, "->", label: [SPI (UI state)])
      edge(<fpga>, <dac>, "->", label: [#i2s])
      edge(<dac>, <speaker>, "->", label: [audio])
    },
  ),
  caption: [System block diagram. The ECP5 is the hub of the design: it ingests IQ
  samples from the PlutoSky, renders the display directly in fabric, drives the
  audio DAC, and relays tuning commands back to the radio. The FM path (spectrum,
  waterfall, and audio) is proven end to end; GOES and ADS-B are planned modes
  fed from the same front end.],
)
