#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

#figure(
  diagram(
    spacing: (13mm, 11mm),
    node-stroke: 0.5pt,
    node-corner-radius: 3pt,
    node-inset: 6pt,
    {
      node((0, 0), [32 MB\ SDRAM], name: <sdram>)
      node((1.3, 0), [SDRAM\ arbiter], name: <arb>)
      node((1.3, -1.2), [compositor], name: <comp>)
      node((2.7, 0), [scan-out\ + line cache], name: <scan>)
      node((4, 0), [pixel\ shader], name: <shader>)
      node((4, -1.2), [font / sprite\ ROMs], name: <rom>)
      node((4, 1.2), [UI state\ (from Pico)], name: <ui>)
      node((5.3, 0), [LCD], name: <lcd>)

      edge(<sdram>, <arb>, "<->")
      edge(<comp>, <arb>, "->", label: [write])
      edge(<arb>, <scan>, "->", label: [read])
      edge(<scan>, <shader>, "->")
      edge(<rom>, <shader>, "->")
      edge(<ui>, <shader>, "->")
      edge(<shader>, <lcd>, "->", label: [RGB])
    },
  ),
  caption: [The display pipeline. The waterfall and image regions live in SDRAM;
  the compositor writes them and a scan-out reader pulls one line ahead into an
  on-chip cache. The pixel shader composes the final image on the fly, overlaying
  live UI elements from font and sprite ROMs and the current UI state on top of
  the SDRAM-backed line, and emits one RGB pixel per clock to the LCD.],
)
