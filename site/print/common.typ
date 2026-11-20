// What the brochure and the poster share: type, greys, pictures, the
// small print.

/* =========== *
 * Type, greys *
 * =========== */

// The site's Ayu colours, in black and white: accents become weight,
// borders become rules, the muted text a grey dark enough to stay solid
// on a laser printer.
#let ink = black
#let muted = luma(35%)
#let rule-grey = luma(55%)

#let setup(body) = {
  set document(author: "Rei (ftvkyo)", date: none)
  set text(font: "Maple Mono NL", size: 8pt, fill: ink, lang: "en", region: "gb", hyphenate: false)
  set par(leading: 0.55em, spacing: 0.9em, justify: false)
  set list(marker: [--], indent: 0pt, body-indent: 0.6em, spacing: 0.55em)
  set raw(theme: "print.tmTheme")
  // Raw text is the body's font already: undo Typst's smaller size for it.
  show raw: set text(font: "Maple Mono NL", size: 1.25em)
  show raw.where(block: true): set text(size: 0.9em)
  // Org's headings: a star and the name.
  show heading: it => block(above: 1.4em, below: 0.7em, sticky: true)[
    #set text(size: 1.15em, weight: "bold")
    #box(width: 1.2em)[\*]#it.body
  ]
  body
}

// A rule across the column, as the site's borders.
#let hairline = line(length: 100%, stroke: 0.4pt + ink)

#let caption(body) = text(size: 0.85em, style: "italic", fill: muted, body)

/* ======== *
 * Pictures *
 * ======== */

// A picture, fitted to its box without distortion.
#let picture(name, width: 100%, height: auto) = image("pictures/" + name, width: width, height: height, fit: "contain")

// A detail of a picture, `width` wide: the part `region`, (x, y, width,
// height) in fractions of the picture's size.
#let detail(name, region, width: 40mm) = context {
  let (x, y, w, h) = region
  let whole = image("pictures/" + name, width: width / w)
  let size = measure(whole)
  // Padded down to the region: whole, it would not fit the block, which
  // would leave it out.
  let cut = pad(
    left: -size.width * x,
    top: -size.height * y,
    right: -size.width * (1 - x - w),
    bottom: -size.height * (1 - y - h),
    whole,
  )
  block(width: width, height: size.height * h, clip: true, cut)
}

// A trace from keycap-server, `width` wide, its cut lines drawn in black
// and `weight` thick on paper; its frame grows by half a line, so that the
// outermost lines are not cut in half.
#let trace(name, width: 40mm, weight: 0.6pt) = {
  let svg = read("pictures/" + name)
  let (x, y, w, h) = svg.find(regex("viewBox=\"[^\"]+\"")).slice(9, -1).split(" ").map(float)
  // In the SVG's millimetres.
  let line = weight.mm() * w / width.mm()
  // repr, as str writes a minus sign that SVG doesn't read.
  let frame = (x - line / 2, y - line / 2, w + line, h + line).map(repr).join(" ")
  let svg = svg
    .replace(regex("viewBox=\"[^\"]+\""), "viewBox=\"" + frame + "\"")
    .replace(regex("width=\"[0-9.]+mm\" height=\"[0-9.]+mm\""), "width=\"" + str(w + line) + "mm\" height=\"" + str(h + line) + "mm\"")
    .replace("#ff0000", "#000000")
    .replace(regex("stroke-width=\"[0-9.]+\""), "stroke-width=\"" + str(line) + "\"")
  image(bytes(svg), format: "svg", width: width)
}

/* ========= *
 * Who, what *
 * ========= */

// The same on the brochure and the poster.
#let credit = [Assisted by: Claude Code]
#let ai-line = [keycap was written with Claude Code, Anthropic's AI coding assistant. I set the goals and made the design decisions, and I review the main results, saying so where I haven't yet; Claude Code wrote most of the code, the tests, the manual and the site.]
#let independence-line = [keycap is independent: not affiliated with or endorsed by fidget, libfive, Halfspace or their author, Matt Keeter.]
#let warranty-line = [No warranty: check dimensions against your parts and print a test before relying on a fit.]
#let licence-line = [Free software: GPL-3.0-or-later and MPL-2.0, examples 0BSD; the designs and this text CC BY-SA 4.0. Details at keycap.rei.gay/about.html.]
#let pictures-line = [Every picture here was rendered by keycap from its script, the original knob by OpenSCAD.]

#let site = "https://keycap.rei.gay"
