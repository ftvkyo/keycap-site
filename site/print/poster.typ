// The poster: one A4 page; only optional detail, the caption, is smaller
// than the body.

#import "common.typ": *
#import "@preview/tiaoma:0.3.0"

#show: setup
#set page(paper: "a4", margin: 12mm)
#set text(size: 12pt)
#set list(spacing: 0.8em)

#block(below: 2mm, text(size: 76pt, weight: "extrabold", tracking: -0.02em, bottom-edge: "descender")[keycap#text(fill: rule-grey)[IDE]])
#text(size: 15pt)[Solid modelling with signed distance fields, in Emacs]

#text(size: 13pt)[by Rei (ftvkyo) \ #credit]

#v(1fr)
#picture("preonic.png", width: 100%)
#v(0.3em)
#caption[MX-style keycaps on an OLKB Preonic, with the legends of QMK's default keymap.]
#v(1fr)

- Write a script, and the model is shown next to it in Emacs, updating as you type
- Shapes are signed distance fields, run by Matt Keeter's fidget: rounded edges, even walls and clearances are easy, and nothing is faceted
- A parts library for 3D printing and laser cutting: screws, nuts, threads, inserts, bearings, magnets, extrusions, finger joints, living hinges and boxes
- Everything in my OpenSCAD collection can be written in it; more than 30 designs are ported and checked against the originals
- A manual whose pictures are rendered from its examples, a tutorial, and over 40 models to look through

#v(1fr)
#hairline
#v(0.3em)
#grid(
  columns: (auto, 1fr),
  column-gutter: 6mm,
  align: (left + top, left + top),
  tiaoma.qrcode(site, width: 34mm),
  [
    #text(size: 22pt, weight: "bold")[keycap.rei.gay]

    #set par(spacing: 0.6em)
    Written with Claude Code, Anthropic's AI coding assistant.

    Independent of fidget, libfive, Halfspace and Matt Keeter; not endorsed by them.

    No warranty. Free software, text CC BY-SA 4.0; the details are on the site's About page.
  ],
)
