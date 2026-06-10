#import "@preview/cetz:0.4.0"
#set page(width: auto, height: auto, margin: 0cm)

#let antenna = {
    cetz.canvas({
          import cetz.draw: *
          let line = line.with(stroke: 0.75pt)
          let ymax = 0.8
          content((0.5, ymax + 0.5), "Antenna")
          line((0.5, 0), (1, ymax), (0, ymax), close: true)
          line((0.5, 0), (0.5, ymax))
      })
}

#let mixer = {
    cetz.canvas({
        import cetz.draw: *
        circle((0, 0), name: "circle", radius: 0.7, stroke: 0.5pt)
        line("circle.north-west", "circle.south-east", stroke: 0.5pt)
        line("circle.north-east", "circle.south-west", stroke: 0.5pt)
    })
}
