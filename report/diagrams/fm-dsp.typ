#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#let i2s = $"I"^2"S"$

#figure(
  diagram(
    spacing: (10mm, 10mm),
    node-stroke: 0.5pt,
    node-corner-radius: 3pt,
    node-inset: 6pt,
    {
      node((0, 0), [IQ from\ PlutoSky], stroke: none, name: <iq>)
      node((1, 0), [`tlv_iq_sink`], name: <sink>)
      node((2, -1), [zoom\ decimator], name: <dec>)
      node((3, -1), [`fft256`], name: <fft>)
      node((4.3, -1), [spectrum +\ waterfall], name: <wf>)
      node((2, 1), [`fm_demod`], name: <fm>)
      node((3, 1), [#i2s], name: <i2s>)
      node((4, 1), [PCM5102\ DAC], name: <dac>)
      node((5, 1), [Speaker], stroke: none, name: <spk>)
      node((3, 2), [RDS decode\ (MPX $arrow.r$ PS name)], name: <rds>)

      edge(<iq>, <sink>, "->")
      edge(<sink>, <dec>, "->")
      edge(<dec>, <fft>, "->")
      edge(<fft>, <wf>, "->")
      edge(<sink>, <fm>, "->")
      edge(<fm>, <i2s>, "->", label: [audio])
      edge(<i2s>, <dac>, "->")
      edge(<dac>, <spk>, "->")
      edge(<fm>, <rds>, "->", label: [MPX], label-side: right)
    },
  ),
  caption: [The FM signal-processing chain inside the ECP5. One IQ stream splits
  three ways: an FFT branch that feeds the spectrum and waterfall, an audio
  branch through the FM demodulator to the DAC, and an RDS branch that recovers
  the station name from the FM multiplex. The spectrum and waterfall outputs are
  written to SDRAM by the compositor in the display pipeline.],
)
