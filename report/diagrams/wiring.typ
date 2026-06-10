#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#let i2c = $"I"^2"C"$
#let i2s = $"I"^2"S"$

#figure(
  diagram(
    spacing: (17mm, 14mm),
    node-stroke: 0.5pt,
    node-corner-radius: 3pt,
    node-inset: 7pt,
    {
      node((-1.3, 0), [Antenna], stroke: none, name: <ant>)
      node((0, 0), [PlutoSky 7020], name: <pluto>)
      node((2, 0), [iCESugar-Pro\ ECP5], height: 14mm, name: <ecp5>)
      node((2, -1.3), [LCD], name: <lcd>)
      node((2, 1.3), [PCM5102\ DAC], name: <dac>)
      node((3.4, 1.3), [Speaker], stroke: none, name: <spk>)
      node((0, 1.3), [Pico 2W], name: <pico>)
      node((0, 2.6), [GT911 Touch], name: <gt>)

      edge(<ant>, <pluto>, "->", label: [RF])
      edge(<pluto>, <ecp5>, "<->", label: [JP5 SPI (4)])
      edge(<pico>, <ecp5>, "->", label: [P5 SPI (3)])
      edge(<gt>, <pico>, "->", label: [#i2c (2)])
      edge(<ecp5>, <lcd>, "->", label: [RGB + sync])
      edge(<ecp5>, <dac>, "->", label: [#i2s (3)])
      edge(<dac>, <spk>, "->", label: [analog])
    },
  ),
  caption: [Physical wiring of the four boards. The label on each link gives the
  bus and its wire count; exact pin assignments are in the connection table.],
)
