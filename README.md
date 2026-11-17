# keycap

Emacs IDE for [fidget](https://github.com/mkeeter/fidget) models.
fidget models are Rhai scripts that build signed distance fields; keycap edits them with errors on the right token, a reference of fidget's functions and shapes, and the model rendered beside the script as you type.

Each script buffer has its own `keycap-server` process (`server/`), which evaluates the script, renders it and meshes it; the manual is `doc/keycap.org`, `M-x keycap-guide` in Emacs.
Its reference is written by `doc/keycap-reference.el` from what describes each function: the prelude's `///` comments, the server's `server/docs/*.toml` and fidget's own reflection.

keycap comes without warranty: check a standard part's dimensions against the part you have, and print or cut a test piece before relying on a fit.
It was written with Claude Code (Anthropic); see the site's [About](https://keycap.rei.gay/about.html) page.
It is not affiliated with fidget, libfive or Rhai, nor endorsed by their authors.

## Features

- `keycap-mode`, derived from `rhai-ts-mode`: `.keycap` and `.fidget` files, fidget's functions and shapes highlighted
- Flymake: errors on their token, the calls that led there in the message and as notes; errors in imported files on the call or the `import`; a warning on every shape that pokes out of the bounds
- `completion-at-point` over functions, shapes, the prelude and the script's own names; inside `circle(#{ ... })`, the shape's fields with their type and default
- ElDoc: the signature of the call at point with its argument highlighted, or the fields of the shape whose map point is in
- `keycap-describe`: a function or shape; with `C-u`, or on no name, the whole reference by category
- `keycap-eval-last-expression`: the value of the expression before point, in the script's scope
- `keycap-increase-number`, `keycap-decrease-number`: nudge the number at point by its digit before point; the preview follows
- `keycap-preview`: the model beside the script, following its changes and those of the files it reads, turned, moved and zoomed with the mouse; the header line reads the model under the pointer
- `text` and `svg` in scripts: lettering in any font and shapes from SVG files as exact distance fields, sized as OpenSCAD's `text()` and `import()` size them
- `keycap-export-stl`: the mesh is made beside the editing and the preview, its progress in the preview's header line, and a cancelled export leaves the last STL as it was
- Exported meshes are simplified to within `keycap-export-tolerance` of the mesher's surface, a tenth of a cell by default, keeping sharp edges and thin walls: a vase of 1.5 million triangles becomes 49,000
- `keycap-export-2d`: the outlines on a plane as an SVG or a DXF for laser cutting, in lines and arcs, each shape drawn to cut, score or engrave (`draw(shape, #{role: "score"})`) in its conventional colour, the cuts grown by `keycap-export-kerf`
- `keycap-guide`, `info-lookup-symbol` in the manual's index

## Dialects

- `.keycap`: fidget's functions and shapes, plus the prelude, `text`, `svg`, `bounds`, `resolution` and any number of `draw`s
- `.fidget`: only what fidget's own viewer and CLI run, so the script works in them unchanged; calling one of keycap's functions is an error that says so

The buffer-local `keycap-dialect` comes from the extension; a file-local variable overrides it.
`examples/spacer.fidget` is written for fidget's tools, the other examples are `.keycap` files.

## Requirements

- Emacs 30.1, with tree-sitter
- [`rhai-ts-mode`](https://tangled.org/rei.gay/rhai-ts-mode) and its grammar
- `keycap-server`, built from `server/` (`just server-build`); `libvulkan.so.1` for the GPU, else it renders on the CPU
- On Nix, `package.nix` puts the server, the prelude and the manual at store paths; `server/package.nix` builds Liberation Sans (© Red Hat, under the SIL Open Font License 1.1) in as `text`'s default font, which a build elsewhere names in `KEYCAP_SERVER_FONT` or finds installed

## Keys

In a script:

| Key | Command |
|---|---|
| `C-c C-c` | `keycap-preview` |
| `C-c C-v` | `keycap-preview-cycle-view` |
| `C-c C-e` | `keycap-export-stl`; with `C-u`, at another resolution |
| `C-c C-l` | `keycap-export-2d`; with `C-u`, with another kerf |
| `C-c C-k` | `keycap-export-cancel` |
| `C-c C-d` | `keycap-describe`; with `C-u`, the whole reference |
| `C-c C-n` `C-c C-p` | `keycap-increase-number`, `keycap-decrease-number`; then `n` `p` again |
| `C-x C-e` | `keycap-eval-last-expression` |

In the preview:

| Key | Action |
|---|---|
| drag, arrows | turn the camera around the model; in 2D views, move it |
| middle drag, `M-`arrows | move the camera |
| wheel, `+` `=` `-` | zoom |
| `v` | next view: shaded, heightmap, sdf, mono |
| `s` `z` `d` `m` | shaded, heightmap (depth), sdf (distance), mono |
| `1` `3` `7` `0` | front, right, top, isometric; in 2D views, slice level across Y, X, Z through the middle of the bounds, or facing the isometric camera |
| `r` | look from isometric, unmoved and unzoomed; in 2D views, level the slice |
| `[` `]`, `S-`wheel, `S-`drag | move the slice; a numeric prefix puts it there, `C-u` asks |
| `M-`wheel | move the slice ten steps |
| `{` `}`, `M-{` `M-}`, `C-`drag | tilt the slice 5° about the image's right or up; a numeric prefix sets the angle |
| `?` | the most used keys of the view shown |
| `p` | orthographic or perspective |
| `b` | the script's bounds or fitted ones |
| `G` | GPU or CPU |
| `e` | export STL |
| `l` | export the outlines on the slice shown, for laser cutting |
| `C-g` | cancel the export; without one, quit |
| `g` | evaluate again, restarting the server if it stopped |

## Preview

The preview evaluates the script `keycap-load-delay` seconds after a change, to it or to a file it reads (an imported script, an SVG file, a font file), and renders it in the server, on the GPU where there is one, into a frame under `$XDG_RUNTIME_DIR/keycap/`.
While one render runs, the next waits, so a drag shows the latest camera rather than every step of it; while the mouse drags, frames have half the resolution, and the last one is in full.
A script that fails leaves the last frame up, with the error first in the header line.
A 2D model, unbounded along Z, starts in the `sdf` view; picking a view by hand keeps it.

The header line shows the view and the slice; while the mouse is over the image, the point under it and the field there; then the bounds in use and their size, the backend and the render time.
The script's `print` output shows below the image, its last `keycap-preview-output-lines` lines.

It opens in a side window on the right; `display-buffer-alist` can put `*keycap: NAME*` buffers anywhere else.

## Tests

`just test` runs the ERT suite against the package built from the working tree, `just server-test` the server's suite.
nixpkgs and `rhai-ts-mode` are pinned with [npins](https://github.com/andir/npins) in `npins/`.

## Licence

- The Emacs package, `keycap.el` and `keycap-preview.el`, is GPL-3.0-or-later (`LICENSE`).
- `keycap-server` (`server/`) and the prelude (`prelude/`) are MPL-2.0, as fidget is (`server/LICENSE`, `prelude/LICENSE`).
  What they port from Matt Keeter's fidget, libfive and Halfspace keeps its notice, and the prelude's rounded combinations keep hg_sdf's MIT notice.
- The examples (`examples/`) are 0BSD (`examples/LICENSE`), free to use without attribution.
- The manual (`doc/`) is GPL-3.0-or-later, as the Emacs package is.
