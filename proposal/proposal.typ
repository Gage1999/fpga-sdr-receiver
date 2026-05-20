#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

= Software Defined Radio Project
Gage Shaddock\
Marco Miralles
== Introduction
This project is a software defined radio receiver that tunes to FM, or satellite image radio and displays images on a touchscreen display or plays audio from a speaker. The display includes tuning options for the radio as well as audio spectrum and waterfall visualizations. The user can use the touch screen to change between satellite or FM mode. When in FM mode, the display shows the audio spectrum and waterfall visualizations and the user can use the touch screen to tune to a specific frequency or change the volume from the speaker. When in satellite image mode, the display shows images from satellites as well as tuning options. 
== Hardware 
- IceSugar Pro FPGA
- Raspberry Pi Pico 2W
- PlutoSky 7020
- Touch Screen
- PCM5102 DAC 
- Speaker
- Capacitive Touch Controller
== Functionality
The PlutoSky board is responsible for acquiring and processing radio signals given a specific tuning config. This tuning config is updated by the Pico 2W based on input from the user over touchscreen. Processed data from the PlutoSky is sent to the IceSugar FPGA over SPI. The IceSugar FPGA routes this data to either the display or the speaker and builds the waterfall and spectrum visualization. The Pico 2W keeps track of current state values for the display and PlutoSky. 
The output is entirely driven by the FPGA while the PlutoSky feeds in processed  radio data and the Pico 2W feeds in current state values such as volume and frequency. The Pico 2W communicates with the PlutoSky via UART, the IceSugar FPGA via SPI, and the touch controller over I2C. The FPGA communicates with the audio DAC over I2S.

== Block Diagram
#figure(
  diagram(
    spacing: (10mm, 9mm),
    node-stroke: 0.6pt,
    node-corner-radius: 2pt,
    node-inset: 6pt,

    node((0, 0), [Antenna], stroke: none, name: <antenna>),
    node((0, 1), [PlutoSky SDR], name: <sdr>),
    node((2, 1), [IceSugar Pro\ FPGA], height: 18mm, name: <fpga>),
    node((0, 3), [Pico 2W], name: <pico>),
    node((2, 3), [Touch\ Controller], name: <touch>),
    node((3, 3), [Touch Screen], name: <screen>),
    node((3, 1), [PCM5102\ DAC], name: <dac>),
    node((4, 1), [Speaker], stroke: none, name: <speaker>),

    edge(<antenna>, <sdr>, "->", label: [RF], label-side: right),
    edge(<sdr>, <fpga>, "->", label: [SPI (IQ)]),
    edge(<pico>, <sdr>, "->", label: [UART], label-side: left),
    edge(<pico>, <fpga>, "->", label: [SPI (State)], label-angle: auto),
    edge(<touch>, <pico>, "->", label: [I2C]),
    edge(<fpga>, <screen>, "->", label: [16 bit RGB], label-angle: auto),
    edge(<screen>, <touch>, "->", label: [touch], stroke: (dash: "dashed")),
    edge(<fpga>, <dac>, "->", label: [I2S]),
    edge(<dac>, <speaker>, "->", label: [audio]),
  ),
  caption: [SDR receiver system block diagram.],
)