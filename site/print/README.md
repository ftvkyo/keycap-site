# Print

An A5 brochure and an A4 poster about keycap, for printing in black and white.

## Building

```sh
nix-build print     # the PDFs, in ./result
```

- `brochure-a5.pdf` -- the brochure's four A5 pages in reading order, for reading on a screen or for a printer that makes booklets itself.
- `brochure-a4-sheet.pdf` -- the same pages on both sides of one A4 sheet: print it double-sided, flipped on the short edge, at 100%, and fold it in half.
- `poster-a4.pdf` -- the poster.

The fonts are embedded, and the same pins give the same bytes.

Every picture is rendered by the build from the pinned scripts, on the CPU, in about 30 s on 16 cores: keycap's through `keycap-server`, the OpenSCAD original through `openscad` on Mesa's software renderer.
They are grey, cropped to the model, and their greys are darkened a little, so that light models keep their shading on paper.

The editor frames are the site's own: `frames.el` runs the front page's keycap block through `tools/ob-keycap.el`, as it is and with the preview's menu open, and `shoot.py` screenshots the pages in headless Chromium, on the CPU, with the site's style sheet and fonts.

## Changing them

```sh
print/watch.sh brochure     # or poster
```

`watch.sh` links the built pictures as `print/pictures` and recompiles `print/brochure.pdf` whenever a source changes; `--input layout=sheet` after the name shows the A4 sheet.
After changing `pictures.json`, `render.py` or the frames' files, run it again to rebuild the pictures.

The rules the layout keeps:

- Text is black; grey is only for captions, at 35%, and inside pictures, so that nothing falls apart into a laser printer's dots.
- Everything stays 12 mm from the edge of the page, more than most printers need, so there is no bleed.
- Emphasis is weight and Org's `*` headings, where the site has its Ayu colours; `print.tmTheme` does the same for code.

## Layout

```
default.nix      the build: the pictures, then the PDFs
render.py        renders pictures.json's pictures, in grey
pictures.json    which scripts, which views, at what size
frames.el        the editor frames' pages, made by the site's ob-keycap
shoot.py         screenshots them, in grey
shoot.css        a frame alone on the page, for shoot.py
common.typ       type, greys, pictures, the small print
brochure.typ     the four pages, and the A4 sheet
poster.typ       the poster
print.tmTheme    code in black and white
watch.sh         recompiles a PDF as its source changes
```

- The small print is in `common.typ`, the same on both.
- The pins are the site's (`../npins`), with `openscad`, the GitHub repository of the OpenSCAD designs, for the original beside its port.
- The QR code, to https://keycap.rei.gay, comes from Typst's `tiaoma` package, from nixpkgs, so the build needs no network.
