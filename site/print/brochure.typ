// The brochure: an A4 sheet folded once into four A5 pages.
//
// `--input layout=pages` (the default) makes the four pages in reading
// order, one A5 page each; `--input layout=sheet` lays them out on the two
// sides of the A4 sheet, pages 4 and 1 outside, 2 and 3 inside, to print
// on both sides, flipped on the short edge, and fold.

#import "common.typ": *
#import "@preview/tiaoma:0.3.0"

#show: setup

#let margin = 12mm

/* ====== *
 * Page 1 *
 * ====== */

#let cover = [
  #block(below: 1.5mm, text(size: 50pt, weight: "extrabold", tracking: -0.02em, bottom-edge: "descender")[keycap])
  #text(size: 11pt)[Solid modelling with signed distance fields, in Emacs]

  #v(1fr)
  #picture("preonic.png", width: 100%)
  #v(0.4em)
  #caption[MX-style keycaps on an OLKB Preonic, with the legends of QMK's default keymap: 51 lines of script, on top of my library of keycap shapes.]
  #v(1fr)

  #picture("frame.png", width: 100%)
  #v(0.4em)
  #caption[The knob from keycap's examples beside its preview, as on the front page of the site.]
  #v(1fr)

  #set text(size: 10pt)
  #grid(
    columns: (1fr, auto),
    align: (left + bottom, right + bottom),
    row-gutter: 0.5em,
    [], [by Rei (ftvkyo)],
    text(weight: "bold")[keycap.rei.gay], credit,
  )
]

/* ====== *
 * Page 2 *
 * ====== */

#let herringbone = "involute_gear(16, 2)
  .extrude([0, 10], #{
    twist: [[0, 0], [0.5, 12], [1, 0]]
  })"

#let what-it-is = [
  = What it is

  keycap is an Emacs IDE for designing parts for 3D printing and laser cutting.
  You write a script, and the model it describes is shown next to it, updating as you type.

  It was written with Claude Code, Anthropic's AI coding assistant: I set the goals and made the design decisions, and Claude Code wrote most of the code.
  There is more on how it was made at the back.

  The scripts are written in Rhai and run by Matt Keeter's fidget.
  In fidget, a shape is a formula: a function of `x`, `y` and `z` that is negative inside the shape, positive outside, and tells how far away the surface is.
  Rounded edges, walls of even thickness and fits with a clearance are easy to make this way, and surfaces have no facets however close you zoom in.

  #v(0.6em)
  #grid(
    columns: (1fr, 50mm),
    column-gutter: 5mm,
    align: (left + horizon, center + horizon),
    block(stroke: (left: 1.2pt + ink), inset: (left: 3mm, y: 1mm), raw(herringbone, lang: "rust", block: true)),
    picture("herringbone.png", width: 100%),
  )
  #v(0.3em)
  #caption[A herringbone gear, one of the manual's examples. The manual's pictures are rendered from its examples when the site is built.]

  = Features

  #grid(
    columns: (1fr, 34mm),
    column-gutter: 5mm,
    [
      - The preview updates about 0.3 s after you stop typing
      - Everything can be done from the keyboard; the mouse can also turn and zoom the model
      - Errors are marked on the exact token, with the call that led there
      - Completion and ElDoc know every shape and function
      - `C-c C-n` nudges the number at point, so you can try a few values for a dimension
      - 2D views slice the model anywhere and show its distance field
      - STL export, simplified to a tolerance, and SVG or DXF of any slice for laser cutting
      - Renders on the GPU, or on all CPU cores without one
    ],
    [
      #picture("bolt-field.png", width: 100%)
      #v(0.2em)
      #caption[The distance field around an M8 bolt from the threads module, cut in half.]
    ],
  )

  #grid(
    columns: (1fr, 38mm),
    column-gutter: 5mm,
    align: (left + horizon, left + horizon),
    [
      In the preview, dragging with the mouse turns the model, the wheel zooms, and a double click goes to the shape's `draw` in the script.
      A right click opens a menu with the views, the cameras and the exports.
    ],
    detail("frame-menu.png", (0.2286, 0.2723, 0.3848, 0.1913), width: 38mm),
  )
]

/* ====== *
 * Page 3 *
 * ====== */

#let models = (
  ("grid-mx.png", [MX-style keycap]),
  ("grid-dna-loop.png", [DNA loop]),
  ("grid-menger-sponge.png", [Menger sponge]),
  ("grid-hex-bowl.png", [Hex bowl]),
  ("grid-vase-koch.png", [Koch snowflake vase]),
  ("grid-whistle.png", [Whistle]),
  ("grid-fidget-magnetic.png", [Magnetic fidget spinner]),
  ("grid-singer-gear.png", [Singer 720 drive gear]),
  ("grid-skadis-hook.png", [SKÅDIS towel hook]),
)

#let what-you-can-make = [
  = What you can make

  A few of the models in the gallery, which has over 40: keycap's examples, my keycaps, and ports of my OpenSCAD designs.

  #grid(
    columns: (1fr,) * 3,
    column-gutter: 3mm,
    row-gutter: 1.5mm,
    ..models.map(((file, name)) => [
      #box(width: 100%, height: 23mm, align(center + horizon, picture(file, height: 23mm)))
      #align(center, caption(name))
    ]),
  )

  = The parts library

  #grid(
    columns: (1fr, 44mm),
    column-gutter: 5mm,
    [
      keycap's library, the prelude, has the shapes, and its modules have common parts for printing and laser cutting:

      - Screws, nuts and washers, with their holes and pockets
      - ISO metric threads, to print
      - Heat-set inserts and their holes
      - Bearings and their seats, disc magnets and their pockets
      - Aluminium extrusions with T-slots
      - For laser cutting: finger joints, tabs and slots, T-slots, cross laps, living hinges and boxes

      Every module says where its numbers come from.
    ],
    [
      #trace("box.svg", width: 44mm)
      #v(0.2em)
      #block(stroke: (left: 1.2pt + ink), inset: (left: 2mm, y: 0.5mm), raw("lc::box([60, 40, 30], 3,
  #{inner: true, fit: 0.1})", lang: "rust", block: true))
      #caption[A box 60 × 40 × 30 inside, in 3 mm material, traced to SVG for the laser cutter; also from the manual.]
    ],
  )
]

/* ====== *
 * Page 4 *
 * ====== */

#let back = [
  = Ported from OpenSCAD

  My older designs are in OpenSCAD (github.com/ftvkyo/openscad).
  Everything in that collection can be written in keycap, and more than 30 designs are ported.
  Almost every port was compared with its original's export, and most agree within 0.3 mm.

  #grid(
    columns: (1fr, 1fr),
    column-gutter: 4mm,
    align: center,
    picture("knob-openscad.png", height: 28mm), picture("knob-keycap.png", height: 28mm),
    caption[OpenSCAD, at the file's `$fn = 24`], caption[keycap],
  )

  = How it was made

  #ai-line
  The designs are mine; their ports to keycap are Claude Code's, checked against my originals.
  Not every line has been read by a person yet.

  None of it needs AI to run: it's ordinary Emacs Lisp, Rust and Rhai, and it works offline.

  = What it isn't

  #independence-line
  fidget's author doesn't use language models for its code and asks contributors not to either, so nothing written by AI goes from here to fidget.

  It's also at version 0.1, and not on MELPA yet.

  = Plans

  - Use it as my personal CAD
  - Keep maintaining it
  - Report the bugs in fidget and Rhai found while making it, and send fixes upstream where they're welcome; for fidget, written by hand
  - Review everything by hand, eventually

  #v(1fr)
  #hairline
  #v(0.2em)
  #grid(
    columns: (auto, 1fr),
    column-gutter: 4mm,
    align: (left + top, left + top),
    tiaoma.qrcode(site, width: 22mm),
    [
      #text(size: 10pt, weight: "bold")[keycap.rei.gay]

      Install instructions, a tutorial, the manual and the gallery.

      #set par(spacing: 0.5em)
      #warranty-line
      #licence-line
      #pictures-line
    ],
  )
]

/* ====== *
 * Layout *
 * ====== */

// A page, which fails the build rather than run past its margin.
#let a5(body) = block(width: 148mm, height: 210mm, inset: margin, breakable: false, context {
  let height = measure(block(width: 148mm - 2 * margin, body)).height
  assert(height <= 210mm - 2 * margin, message: "a page runs " + repr(height - 210mm + 2 * margin) + " past its margin")
  body
})

#if sys.inputs.at("layout", default: "pages") == "sheet" {
  set page(paper: "a4", flipped: true, margin: 0pt)
  grid(columns: 2, a5(back), a5(cover))
  pagebreak()
  grid(columns: 2, a5(what-it-is), a5(what-you-can-make))
} else {
  set page(paper: "a5", margin: 0pt)
  for (i, body) in (cover, what-it-is, what-you-can-make, back).enumerate() {
    if i > 0 { pagebreak() }
    a5(body)
  }
}
