#let i2c = $"I"^2"C"$
#let i2s = $"I"^2"S"$

#v(20em)
#align(
  center,
    text(20pt)[
      CS122A Final Project\
      An FPGA Software-Defined Radio Receiver\

    #text(16pt)[
      Spectrum, Weather-Satellite, and Aircraft Display on an ECP5]

    #v(1em)
    #text(16pt)[
      Marco Miralles \ Gage Shaddock]
    ]
  )

#pagebreak()

#text(16pt)[*Terminology*]
#text(14pt)[

- SDR - Software Defined Radio

- RF - Radio Frequency

- IQ - In-phase and Quadrature samples

- LO - Local Oscillator

- FPGA - Field Programmable Gate Array

- FFT - Fast Fourier Transform

- RDS - Radio Data System (the digital sub-carrier on FM broadcast)

- PS name - Program Service name (the 8-character station label in RDS)

- MPX - Multiplex (the composite FM baseband)

- GOES - Geostationary Operational Environmental Satellite

- APT - Automatic Picture Transmission (NOAA weather-image format)

- ADS-B - Automatic Dependent Surveillance Broadcast (aircraft position beacon)

- LCD - Liquid Crystal Display

- DAC - Digital to Analog Converter

- SDRAM - Synchronous Dynamic Random-Access Memory

- EBR - Embedded Block RAM (the FPGA's on-chip memory)

- TLV - Type-Length-Value (the framing for the Pluto link)

- SPI - Serial Peripheral Interface

- #i2c - Inter-Integrated Circuit

- #i2s - Inter-Integrated Circuit Sound

- MCU - Microcontroller Unit
]
#pagebreak()
#outline(title: "Table of Contents")
#pagebreak()

= Introduction
Most software-defined radios end at the speaker. Ours was meant to start there and keep going. The goal of this project was to build an SDR whose primary output is not audio but a screen, where a single RF front end can feed three very different displays. In FM mode the screen shows a live spectrum and a scrolling waterfall while audio plays out of a speaker. In GOES mode it paints a weather-satellite image line by line as it arrives. In ADS-B mode it draws a map of the local airspace with aircraft plotted as dots wherever they broadcast their positions. The user chooses a mode by touch, the radio retunes itself, and the screen changes to match.

This project is, in spirit, a continuation of an earlier SDR. That radio was built around a custom RF front-end PCB, and the overwhelming majority of the effort went into the analog board, into filters and mixers and impedance-matched traces, rather than into anything the user could see or hear. The lesson from that attempt was to design around a working prototype instead of betting everything on a single fabricated board. So this time we bought the RF front end. A PlutoSky 7020 pairs an Analog Devices AD9363 transceiver with a Xilinx Zynq SoC and hands us calibrated IQ samples over a simple link. With the radio front end taken as a given, we could spend our effort on the digital signal processing and the system integration, which is where the interesting part of this project lives.

The design is split across three boards, each doing what it is best at. The PlutoSky is the RF front end. It tunes, samples, and streams IQ. The iCESugar-Pro, a Lattice ECP5 FPGA with 32 MB of SDRAM, is the hub of the system. It ingests the IQ stream, runs all of the digital signal processing, composes the screen, drives the LCD, and feeds an audio DAC. The Raspberry Pi Pico 2W owns the user interface. It reads the capacitive touch panel and sends compact UI-state frames to the FPGA, which in turn relays tuning commands back to the radio. Only one mode runs at a time, because the AD9363 cannot hold two receive frequencies at once, but switching between them is meant to feel seamless.

#include "diagrams/system-diagram.typ"

The mode that works end to end, on hardware, is FM. Tuned to a broadcast station, the PlutoSky streams raw IQ to the ECP5, which demodulates it, plays the audio out of the speaker, and at the same time runs the IQ through a 256-point FFT to draw the spectrum and waterfall. The two image modes, GOES and ADS-B, are decoded on the PlutoSky and their results already cross the link to the FPGA, but the rendering that would paint a weather image or plot aircraft on the map is not yet wired, so today those packets are received and counted rather than shown. The body of this report covers how the working parts fit together and where the project stops short.

#figure(
  table(
    columns: 2,
    align: (left, left),
    [RF front end], [PlutoSky 7020 (AD9363 transceiver + XC7Z020 Zynq)],
    [Display FPGA], [iCESugar-Pro (Lattice ECP5-25K) + 32 MB SDRAM],
    [UI microcontroller], [Raspberry Pi Pico 2W (RP2350)],
    [Display], [4.3" 800$times$480 RGB-parallel LCD, 60 Hz, RGB565],
    [Touch], [Goodix GT911 capacitive controller over #i2c],
    [Audio DAC], [Texas Instruments PCM5102 over #i2s],
  ),
  caption: [The four hardware blocks of the receiver.],
)

= Elements of Complexity
The course had already walked us through building a display controller that drives the 800$times$480 RGB LCD from a framebuffer, so the raw video output stage was a known quantity we built on top of rather than the hard part of this project. The original and difficult work was on the radio and memory side, and in stitching three boards into one real-time system. The pieces that carried the most complexity were these:

- *A streaming 256-point FFT in fabric.* `fft256` is built from a `butterfly` datapath and a `twiddle_rom`, running continuously on the incoming IQ to produce one spectrum row per frame.

- *FM demodulation in hardware.* `fm_demod` recovers audio from the complex baseband with the conjugate-product method, turning a few multipliers and an arctangent into real-time audio.

- *A from-scratch SDRAM controller and arbiter.* `sdram_ctrl` and `sdram_arb` bring up the 32 MB SDRAM and share it between three clients on a fixed priority. Getting it reliable meant diagnosing a hardware-level page-boundary fault on the part itself, described later.

- *Hard real-time scan-out.* `scan_out` and `line_cache` read one display line ahead of the beam and cross from the 100 MHz memory clock to the 30 MHz pixel clock without tearing.

- *The waterfall compositor.* `compositor` scrolls the history by moving a base-row pointer instead of copying memory, so a new row costs one short write.

- *A custom capacitive touch driver.* The GT911 controller was not provided. We wrote the #i2c driver and the touch handling on the Pico ourselves.

- *Multi-device integration.* Three boards talk over four different links using a custom CRC-checked wire protocol, with the ECP5 acting as the hub and relaying tuning commands back to the radio.

- *A C to FPGA verification harness.* The render path has a portable C reference and a Verilator parity test that proves the SystemVerilog produces pixel-identical output, which let us develop and check the display logic away from hardware.

- *DSP zoom.* `spectrum_zoom_decimator` changes the FFT input rate to zoom the spectrum while keeping all 256 bins on screen.

= Signal Processing Background
== IQ Sampling
The previous project spent most of its effort building the analog stage that turns an RF signal into in-phase and quadrature baseband: a band-pass filter, a low-noise amplifier, a pair of mixers fed by quarter-period-shifted local oscillators, and matched low-pass filters. The AD9363 inside the PlutoSky does all of that on a single chip. We tune it to a center frequency and it hands back a stream of complex samples, each one a pair $(I, Q)$ describing the signal's amplitude and phase relative to the local oscillator. Mathematically the radio gives us the complex baseband
#figure($ z[n] = I[n] + j thin Q[n] $)
already downconverted and decimated to a manageable rate. Everything our design does begins from that stream.

Why complex, and not just one channel? A single real mixer cannot tell a signal above the local oscillator from one an equal distance below it, because the two fold onto the same baseband frequency. Sampling both an in-phase component and a quadrature component shifted by 90 degrees resolves the ambiguity. Positive and negative frequencies become distinguishable, which is exactly what we need both to draw a two-sided spectrum and to demodulate FM. This quadrature mixing was the hard analog problem of the last project, and here it arrives already solved.

== FM Demodulation
In frequency modulation the information rides in the instantaneous frequency of the signal, and frequency is simply the rate of change of phase. With complex samples the phase is $phi[n] = "atan2"(Q[n], I[n])$, so the demodulated output is the phase difference between consecutive samples. The cleanest way to compute it avoids unwrapping two separate arctangents. We multiply each sample by the conjugate of the previous one and take the angle of the result.
#figure($ m[n] prop arg(z[n] dot z^*[n-1]) =
  "atan2"(I[n-1]Q[n] - I[n]Q[n-1], thick I[n]I[n-1] + Q[n]Q[n-1]) $)
The two arguments are a cross product and a dot product of consecutive IQ vectors, a handful of multiplies and adds, and a single arctangent runs on their ratio. The `fm_demod` module computes exactly this. What falls out is the FM multiplex: mono audio at baseband, a stereo difference signal above it, and the RDS sub-carrier higher still.

== Spectrum and Waterfall
The same IQ stream that feeds the demodulator also feeds a 256-point FFT (`fft256`, built from a `butterfly` datapath and a `twiddle_rom`). Taking the magnitude of each bin gives the power at that frequency, and mapping magnitude through a color palette gives one row of pixels. Stacked over time, those rows are the waterfall. The vertical axis is time, the horizontal axis is frequency, and brightness is signal strength, so a steady carrier draws a bright vertical streak and a transient flashes and scrolls away. The instantaneous trace across the top is the spectrum. Both are derived from the same FFT output. The spectrum is the newest row drawn as a line, and the waterfall is its history.

== RDS
FM broadcast carries a low-rate digital channel, the Radio Data System, on a sub-carrier at 57 kHz within the multiplex, which is why RDS recovery starts from the FM demodulator's output rather than from raw IQ. The data is differentially encoded BPSK at 1187.5 bits per second, grouped into 26-bit blocks with offset words that let a receiver find block and group boundaries without a separate sync channel. Our gateware recovers it in three stages. `rds_demod` recovers the bitstream from the multiplex, `rds_sync` locks to the block and group structure, and `rds_group` assembles the groups and extracts the 8-character Program Service name, the short station label a car radio shows. The decode chain works in simulation, recovering the station name from captured multiplex, but we were not able to get it to lock reliably on live hardware, so RDS is not part of the working hardware feature set. When no name has been decoded, the status row falls back to text supplied by the Pico.

= System Design
== The PlutoSky Front End
The PlutoSky 7020 pairs the AD9363 with a Xilinx Zynq SoC, and runs a build based on the open-source maia-sdr firmware. The Zynq's programmable logic streams calibrated IQ out of an AXI Quad SPI block on the JP5 expansion header at roughly 12.5 MHz. At 32 bits per complex sample that budget is about 390 thousand complex samples per second, and the FM path is sized to fit inside it. The PlutoSky is also where the GOES and ADS-B decoders run. They are heavier, more sequential workloads that suit the Zynq's ARM cores better than the FPGA fabric, and their results are meant to cross the same link in a compact form rather than as raw IQ.

== The Radio Pipeline
Everything past the radio happens in the ECP5. Bytes arrive on the JP5 SPI link, `spi_frame_rx` reassembles them, and `tlv_demux` routes each packet by type. IQ packets land in `tlv_iq_sink`, which feeds the three branches shown in the figure below: the FFT branch for the spectrum and waterfall, the `fm_demod` branch for audio out through an `audio_fifo` and `i2s_tx` to the PCM5102, and the RDS branch off the recovered multiplex. This pipeline, and the SDRAM controller that backs it, is the heart of the project's original work.

#include "diagrams/fm-dsp.typ"

== The Display Path
The display controller that turns a framebuffer into RGB and sync signals for the LCD came out of the course, so we treated the video output stage as a building block. Our work on the display side was making that framebuffer carry live radio data in real time, which is built around the iCESugar-Pro's 32 MB SDRAM. The framebuffer, the waterfall history, and the GOES and ADS-B image regions all live in SDRAM, and three clients share it through a fixed-priority arbiter (`sdram_arb`). The highest priority is the scan-out reader, because missing a line shows up immediately as a tear. Below it sit the compositor's writes and the ingest of new IQ.

A `scan_timing` module owns the 800$times$480 at 60 Hz LCD timing and runs in the pixel-clock domain at about 30 MHz, while the SDRAM, arbiter, and compositor run at 100 MHz. The `line_cache` between them is a small on-chip buffer filled one line ahead of the beam. It is both the latency cushion that absorbs arbiter stalls and the crossing point between the two clock domains. The `compositor` advances the waterfall by one row not by copying memory but by moving a base-row pointer that the scan-out reader follows, so a new spectrum row costs a single short write. On top of the SDRAM-backed line, the `pixel_shader` draws the live overlay, which is the spectrum trace, the status bar, the frequency and band readout, the mode and volume indicators, and the touch crosshair, from font and sprite ROMs and the current UI state, emitting one RGB pixel per clock.

#include "diagrams/display-pipeline.typ"

== The Touch Interface and Control Loop
The Pico 2W reads the Goodix GT911 capacitive panel over #i2c and keeps the authoritative copy of the user-facing state: mode, center frequency, volume, mute, and touch position. It sends that state to the FPGA as framed packets, each one a `0xA5` magic byte, an opcode, a little-endian length, a payload, and a CRC16-CCITT check, defined once in portable C and shared by both ends. On the FPGA two parsers read the same frames. `ui_wire_rx` keeps the fields the shader needs for the status bar, RDS line, touch overlay, and zoom, while `spi_ui_cmd_rx` extracts the fields that should become radio commands. Those commands, which set mode, frequency, volume, and mute, are applied locally by `control_regs` for audio and queued by `spi_backchannel` to be relayed back to the PlutoSky over the JP5 return line. The result is a closed loop. A touch on the glass changes the Pico's state, which retunes the radio.

== Implementation Notes
*The SDRAM page-boundary workaround.* The single most stubborn hardware problem was a band of streaks across the display. The cause was not the RTL. This board's SDRAM part turned out to be unreliable for bursts that reach the far half of a row, and any access crossing the 512-word page boundary returned a few corrupt words. Three controller-level fixes, namely shorter fixed-length bursts, guard cycles, and a slower clock, were each built and tested, and none cleared it, which told us it was a physical margin rather than a logic bug. The fix was to change how a pixel maps to an address. The framebuffer stores only the first 256 words of each SDRAM row and leaves the upper half unused, so no burst ever reaches the marginal column. The logical framebuffer is still a flat array of pixels and the rest of the design never sees the difference. Only the word-to-address function changed, and the writer and reader both carry the same mapping so they cannot disagree. It costs twice the address space, which on a 32 MB part is free.

*Zoom by decimation.* Zooming the spectrum is handled without rescaling any pixels. A `span_hz_log2` field from the Pico selects the visible RF span, and `spectrum_zoom_decimator` changes the rate of IQ samples entering the FFT rather than the FFT itself. Narrower spans decimate the input more, so the 256 bins always fill the same 256 columns of screen while the hertz per bin shrinks. The display density stays fixed and only the frequency scale changes. It is a first-pass approach. A true channelizer would also shift center frequency in fabric, whereas here a center change is sent back to retune the PlutoSky's oscillator, and the waterfall history deliberately keeps whatever scale each row was drawn at.

= User Guide
The receiver is meant to be used through the touchscreen alone. On power-up the three boards boot on their own and the radio comes up in FM mode, showing a live spectrum across the top of the screen with a waterfall scrolling beneath it. A status bar reports the current mode, the center frequency, the visible band, and the volume.

All interaction is through the touchscreen, handled by the Pico. A row of on-screen buttons along the side of the display drives the controls:

- *Tuning.* Touching the tuning control retunes the radio. The Pico sends the new frequency to the FPGA, the FPGA relays it to the PlutoSky, and both the spectrum and the audio follow.

- *Volume and mute.* One control sets the volume from 0 to 100, and a mute toggle silences the audio while leaving the display running.

- *Zoom.* The span control narrows or widens the visible band. The display always shows 256 bins, so zooming in raises the resolution in hertz per bin instead of changing the number of bars on screen.

- *Mode.* The mode button cycles FM, GOES, and ADS-B, and back to FM. Selecting a mode retunes the radio for that signal. FM is fully interactive today. The two image modes change the radio and the requested layout but do not yet paint their images.

Audio plays out of the speaker through the PCM5102 DAC, and any touch is echoed on screen as a crosshair so the user gets immediate feedback.

= Hardware Components
#figure(
  table(
    columns: (auto, 1fr),
    align: (left, left),
    [*Component*], [*Part and role*],
    [RF front end], [PlutoSky 7020: AD9363 transceiver with an XC7Z020 Zynq SoC, tunes and streams IQ],
    [Display FPGA], [iCESugar-Pro, Lattice ECP5-25K (CABGA256), with 32 MB IS42S16160B SDRAM],
    [UI microcontroller], [Raspberry Pi Pico 2W (RP2350)],
    [LCD], [4.3" 800$times$480 RGB-parallel panel, 60 Hz, RGB565],
    [Touch controller], [Goodix GT911 capacitive controller (#i2c address 0x5D)],
    [Audio DAC], [Texas Instruments PCM5102 over #i2s],
    [Speaker], [Powered from the DAC's analog output],
    [Antenna], [Whip antenna at the PlutoSky RX port],
  ),
  caption: [Hardware components used in the receiver.],
)

= Software Libraries and Tools
- *maia-sdr / maia-hdl* form the base firmware and FPGA design on the PlutoSky, providing the AD9363 interface and the IQ data path.
- *libiio* on the PlutoSky reads IQ samples from the radio in userspace.
- *Raspberry Pi Pico SDK* builds the RP2350 firmware that drives the GT911 and the SPI link.
- *SDL2* renders the host harness on a laptop, used only for development.
- *CMake* was used to build the shared C, the host harness, and the test suite.
- *Verilator* simulates the SystemVerilog and runs the C to RTL parity tests.
- *Yosys*, *nextpnr-ecp5*, and *Project Trellis* synthesize and place the ECP5 bitstream.
- *Vivado* builds the PlutoSky bitstream, and the Vitis ARM cross-compiler builds its userspace code.
- Small *Python* scripts convert font, sprite, and palette data into the `.mem` ROMs the ECP5 loads.

= Protocols
- *SPI*, used twice. The PlutoSky streams IQ to the ECP5 over the JP5 header (SPI mode 3), and the Pico sends UI-state frames to the ECP5 (SPI mode 0).
- *#i2c*, between the GT911 touch controller and the Pico.
- *#i2s*, carrying stereo audio from the ECP5 to the PCM5102 DAC.
- *AXI*, inside the Zynq, connecting the ARM cores to the AD9361 interface and the JP5 SPI block.
- *TLV framing* on the PlutoSky to ECP5 link, a type byte, a big-endian length, and a payload, used to carry IQ, image rows, and object lists over one stream.
- *Custom #box[`0xA5`] wire protocol* on the Pico to ECP5 link, with a magic byte, opcode, little-endian length, payload, and a CRC16-CCITT check.
- *RGB-parallel video* with HSYNC, VSYNC, and DE to the LCD.
- *RDS*, the broadcast data protocol decoded from the FM multiplex.

= Wiring Diagram
#include "diagrams/wiring.typ"

The pin assignments for the three wired links are listed below, grouped by bus.

#figure(
  table(
    columns: (auto, auto, auto, auto),
    align: (left + horizon, left, left, left),
    table.header([*Bus*], [*Signal*], [*From*], [*To*]),
    table.cell(rowspan: 4)[JP5 SPI\ (Pluto $arrow.l.r$ ECP5)],
      [SCK], [JP5 7 / Zynq V10], [ECP5 D7],
      [MOSI], [JP5 9 / Zynq U9], [ECP5 D8],
      [CS], [JP5 13 / Zynq T9], [ECP5 D9],
      [MISO], [ECP5 T3], [JP5 11 / Zynq U10],
    table.cell(rowspan: 3)[Pico SPI\ (Pico $arrow.r$ ECP5)],
      [SCK], [Pico GP18], [ECP5 D12],
      [MOSI], [Pico GP19], [ECP5 C11],
      [CS], [Pico GP17], [ECP5 D13],
    table.cell(rowspan: 2)[Touch #i2c\ (GT911 $arrow.r$ Pico)],
      [SDA], [GT911 SDA], [Pico GP4],
      [SCL], [GT911 SCL], [Pico GP5],
  ),
  caption: [Pin assignments for the inter-board links. The audio (#i2s) and video
  (RGB) lines use the iCESugar-Pro header pinout from the course display
  controller, and a common ground is shared across all boards.],
)

= Meeting the Proposal Requirements
Our proposal described an SDR that tunes FM or satellite-image radio, shows audio spectrum and waterfall visualizations on a touchscreen, plays audio through a speaker, and lets the user switch modes and tune by touch, with the PlutoSky acquiring the radio signal, the Pico tracking state from touch input, and the ECP5 driving the display and audio. Measured against that proposal:

- *FM reception with spectrum and waterfall:* met. FM works end to end on hardware.
- *Audio output through the PCM5102 and a speaker:* met.
- *Touchscreen control of frequency, volume, and mode:* met. We added a zoom control beyond the proposal.
- *Switching modes by touch:* met for selection. FM renders fully, and the satellite-image and ADS-B modes select and retune but do not yet render their images.
- *Satellite-image mode:* partially met. The PlutoSky-side decoder and the transport to the ECP5 exist, but the FPGA-side image rendering is not wired.
- *ADS-B mode:* a stretch beyond the original FM-or-satellite proposal. Like satellite, the decoder and transport exist but the map rendering is not wired.

One architectural change from the proposal is worth noting. We had planned a direct Pico-to-PlutoSky UART for tuning. In the built system the Pico talks only to the ECP5, and the ECP5 relays tuning commands to the PlutoSky over the JP5 return line. Making the FPGA the single hub simplified the wiring and kept all control on one protocol.

= Testing
The portability contract makes most of the system testable away from hardware. A suite of host-side unit and golden-image tests exercises the compositor and pixel shader against stored reference images: a default screen, the spectrum trace, the touch crosshair, the mute indicator, a waterfall stepped several rows, and others. A change that alters a single pixel is caught in continuous integration without a board attached. Because the C reference is also the gateware's specification, those same inputs and goldens are what validate the SystemVerilog. A Verilator parity job renders the same inputs through the C model and through the RTL shader and checks that they are byte-for-byte identical, including the generated ROMs.

On hardware, bring-up followed a deliberate order so that each stage could be checked on its own: the SDRAM controller alone with a write-read pattern, then scan-out of a solid color, then the line cache and arbiter with a moving test pattern, then the Pico SPI link and a live touch cursor, then the font and sprite ROMs and the status bar, then the compositor's waterfall from synthetic data, and finally real IQ from the PlutoSky. Each step was independently observable with a logic analyzer while the same UI logic ran in the host harness for comparison. This is the lesson from the previous project put into practice: build on something that runs, and add one verifiable thing at a time.

= AI Usage
We used AI as a coding assistant on well-scoped parts of the project, and it helped most where we could check its output exactly.

- *For the display path,* we used AI to write SystemVerilog modules and the C reference model they are checked against. The two are tied to the same specification by an end-to-end harness: a Verilator job feeds identical inputs through the RTL and the C model and fails if a single pixel comes out different, and the generated ROMs are compared the same way. Because of that, anything AI wrote for the display had to clear a hard test before we kept it, namely matching the reference pixel for pixel. The harness did the judging in place of a code review, which is what made it worth leaning on AI here.

- *For the test suite,* we used AI to fill out coverage, turning a described scenario into a golden-image or unit test, which we then checked once against the live harness and locked in as a regression.

// Gage: add your AI uses here as more "for X, we did Y" bullets.

= Acknowledgements
Thanks to the CS122A course staff for the display-controller starting point and the iCESugar-Pro framebuffer reference, whose SDRAM controller and PHY for this board gave our own memory bring-up a place to start. Thanks also to the open-source projects this work stands on: maia-sdr for the PlutoSky firmware and FPGA design, and Yosys, nextpnr, and Project Trellis for the open ECP5 toolchain. This was a two-person project by Marco Miralles and Gage Shaddock.

= Reflection
Compared with the previous attempt, the result this time is one we are happy with. That project ended with a front end and a few isolated signs of life on an expensive board. This one is a radio you can use: tune an FM station by touch, hear it, and watch its spectrum and waterfall move in real time. Buying the RF front end instead of building it was the right call. It moved the effort to the part of the problem we actually wanted to work on, and it meant the project stood on a working prototype rather than a single fabricated gamble.

The honest gaps are RDS and the two image modes. RDS decodes correctly in simulation but would not lock on live hardware, so it stayed a simulation result. GOES and ADS-B are decoded on the PlutoSky and their results already cross the link, but the compositor path that would paint a weather image or plot aircraft on a map is not yet wired, so today they are received and counted rather than shown. The architecture was built to accommodate them, with the SDRAM regions reserved, the packet types defined, and the compositor given a place for each, so finishing them is the clear next step. What we set out to prove, that a single FPGA can ingest a radio stream and render its own display in real time, is proven for FM. Extending that same machinery to the other two modes is the work that remains.
