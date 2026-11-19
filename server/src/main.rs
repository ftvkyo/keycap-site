// SPDX-License-Identifier: MPL-2.0

//! The render and evaluation server behind keycap.
//!
//! `keycap-server [--prelude DIR] [--threads N] [--gpu-budget MS]` serves
//! one script buffer.
//! It reads one JSON request per line on stdin and answers each with one
//! JSON line on stdout.  Renders are answered in their order, and the
//! other requests in theirs, so that a `load` or a `probe` never waits for
//! a frame; a render shows the scene of the loads before it.  A newer
//! `render` cancels an older one still waiting or running, and `mesh` and
//! `trace` answer once their export, running beside the other requests,
//! is done.  stderr carries logs only.
//!
//! It renders on half as many threads as there are cores, and exports on
//! one per core, both at a lower priority, exports the lower; `--threads N`
//! makes that N each, so that a shared machine keeps cores for others.  A
//! 3D frame on the GPU goes in tiles, each a submission of about
//! `--gpu-budget MS` at most (400 by default), as drivers reset a GPU
//! whose work runs for seconds.
//!
//! Scripts are Rhai in one of two dialects.  `keycap`, the default, is
//! fidget's bindings (`fidget::rhai`) plus:
//!
//! - `draw(tree)` and `draw_rgb(tree, r, g, b)`, colour components 0 to 1,
//!   any number of times, and `draw(tree, #{role})`, `role` `"cut"` (the
//!   default), `"score"` or `"engrave"` for 2D export
//! - `bounds(lower, upper)`, two 3-element arrays, at most once
//! - `resolution(n)`, the export resolution in cells per world unit
//! - the public functions of the `.rhai` files in `--prelude DIR`, without
//!   an `import`; the files, joined in name order, make one module, so
//!   their `private fn`s are shared between them
//! - `import "name" as m;`, resolved relative to the importing file, trying
//!   `name` when it has an extension, else `name.keycap`, `name.fidget` and
//!   `name.rhai`; `import "keycap/name" as m;` is the prelude's module
//!   `modules/name.rhai`, wherever the importing file is
//! - `text(string)` and `text(string, options)`, the outline of a string
//!   in a font, as OpenSCAD's `text()` draws it
//! - `svg(path)` and `svg(path, options)`, the shapes of an SVG file in
//!   millimetres, as OpenSCAD's `import()` takes them
//!
//! `fidget` is what fidget's own viewer runs: fidget's bindings, `draw`
//! and `draw_rgb` any number of times, and imports, trying `name.fidget`
//! and `name.rhai`.  A script that calls one of keycap's functions fails
//! with an error that says so.
//!
//! # Requests and replies
//!
//! Every request has an integer `id` and an `op`; every reply has the same
//! `id` and either the op's fields, `error` (the request was malformed or
//! failed), or `cancelled: true`.  Lines and columns are 1-based, columns
//! counted in characters as Rhai counts them.  A region is
//! `{"lower": [x, y, z], "upper": [x, y, z]}`.
//!
//! ## `load`
//!
//! `{"id", "op": "load", "source", "path", "dialect", "overrides"}`:
//! evaluates the script and keeps what it draws as the scene; `path` is
//! the script's file or null, `dialect` `keycap` (the default) or
//! `fidget`.  On failure the previous scene stays loaded; a new one
//! cancels the renders read before the load, which show the old one.
//!
//! `overrides`, `{"NAME": VALUE}` and optional, runs the script with other
//! values for its top-level constants, such as one design's variants: each
//! `const NAME = ...;` outside any block or function has VALUE instead.  A
//! number written without a point or an exponent is an integer, any other
//! a float; strings, booleans and arrays are themselves, objects Rhai's
//! maps and null `()`.  A name that is no top-level `const` of the script
//! is an error that names it.  The values are replaced on the syntax tree,
//! so lines and columns stay the script's own.
//!
//! The reply:
//!
//! - `loaded`: whether the script ran
//! - `shapes`: `{"line", "column", "color"}` per `draw`, `color` an RGB
//!   triple or null, plus `"file"` when drawn from another file
//! - `bounds`: `{"script": REGION or null, "fitted": REGION or null,
//!   "loose": REASON or null}`; a fitted coordinate is null where the
//!   shapes are unbounded on that side, and `loose` says why the fitted
//!   bounds may be far looser than the shapes, or miss sides they have
//! - `resolution`: the script's `resolution(n)` or null
//! - `functions`: the functions the script defines, and those of the
//!   modules it imports under a name, as `docs` lists the others, under
//!   the names the script calls them by (`keycap::body`), `source`
//!   `script` or `import`, `file` the imported file's name; also when the
//!   script fails, as far as it ran
//! - `output`: the lines `print` and `debug` wrote
//! - `files`: the absolute paths of the files the script read besides
//!   itself, imported scripts, SVG files and font files, whether it ran or
//!   not, for a client to reload when they change
//! - `diagnostics`: `{"severity", "line", "column", "message", "trace"}`,
//!   the error's innermost location first; `trace` lists the call sites
//!   outward as `{"line", "column", "message"}`; any of these has `"file"`
//!   when it is not in the script itself; warnings mark a script that
//!   draws nothing, shapes that are provably empty or, without the
//!   script's bounds, unbounded on every axis, shapes that reach out of
//!   the script's bounds, and a `fidget` script that runs past the 50,000
//!   operations at which fidget's own tools stop it; notes, in the keycap
//!   dialect only, mark a call of a fidget built-in that has a better
//!   keycap call, which the note names, unless a line of the script reads
//!   `// keycap: no-prefer`
//! - `ms`: the time taken
//!
//! ## `render`
//!
//! `{"id", "op": "render", "output", "width", "height", "view", "bounds",
//! "backend", "reproducible", "camera", "slice", "background"}` writes a
//! binary PPM to `output`, through a temporary file renamed into place.
//!
//! - `view`: `shaded` and `heightmap` look at the scene in 3D, cut to the
//!   region as `mesh` cuts it; `sdf` (the distance field coloured as
//!   halfspace does) and `mono` (inside or outside) slice it in 2D
//! - `bounds`: `script` or `fitted`, the region shown; `script` falls back
//!   to `fitted` when the script sets none
//! - `backend`: `gpu` or `cpu`; `gpu` falls back to `cpu` without a usable
//!   adapter, for shapes the GPU cannot evaluate, and for a frame that lost
//!   the GPU's device, and so does every later frame of that scene
//! - `reproducible`: whether a `gpu` frame is to be the same bytes in every
//!   run, as `cpu` frames are; its ambient occlusion then comes from the
//!   CPU, which is slower.  False by default: the GPU finds it from samples
//!   drawn once per run, so frames do not flicker within one
//! - `camera`: `{"azimuth", "elevation", "zoom", "pan", "orthographic"}`;
//!   degrees, Z up, azimuth 0 looking from +X; zoom 1 fits the region's
//!   corners as the camera sees them (3D) or its slice (2D) to the image;
//!   `pan` is `[right, up]` in halves of the image height
//! - `slice`: `{"axis", "offset", "tilt"}`, the plane normal to `axis` at
//!   `offset`; the image's right and up are (x, y) for `z`, (x, z) for `y`
//!   and (y, z) for `x`.  `tilt`, `[right, up]` in degrees, `[0, 0]` by
//!   default, turns that plane about the region's centre: about the image's
//!   right, then about its turned up, by the right-hand rule; the image's
//!   right and up turn with it, `offset` runs along its turned normal, and
//!   zoom 1 is the level plane's, so that a slice keeps its scale as it
//!   tilts
//! - `background`: the RGB triple of empty pixels in 3D views, 0 to 1,
//!   dark grey by default
//!
//! An axis of fitted bounds that is unbounded on one side runs from its
//! bounded side as far as the widest bounded axis is wide, or 20 when
//! none is; unbounded on both, it is that wide, centred on 0.  Each pixel
//! shows what lies at its centre; on a tilted slice, `probe` reads it in
//! the model's own coordinates.  The reply has the `backend` and `bounds`
//! used, `ms`, `scale`,
//! the world units a pixel spans at the focus, `empty`, whether no pixel
//! shows the inside of a shape, and `fallback`, why a frame asked of the
//! GPU was rendered on the CPU.
//!
//! ## `probe`
//!
//! `{"id", "op": "probe", "x", "y"}`: the pixel of the last frame answered
//! at `x` and `y`, counted from its top left.  The reply has `position`, the point
//! at the pixel's centre on the slice or on the surface seen there (null
//! when there is none), `value`, the field there, and `shape`, the index in
//! `load`'s `shapes` of the shape whose field is lowest there (null with
//! `position`).
//!
//! ## `mesh`
//!
//! `{"id", "op": "mesh", "output", "bounds", "resolution", "tolerance"}`
//! writes a binary STL of the shapes' union cut to the region, with cells
//! no larger than 1/`resolution`; a null `resolution` falls back to the
//! script's, then to 256 cells across.  The mesh is simplified to within
//! `tolerance`, in units, of the mesher's surface, a tenth of a cell when
//! it is null, unsimplified when it is 0.  The scene as loaded then is
//! exported on threads of its own, at a lower priority, while later
//! requests are answered; a newer `mesh` or `trace` cancels it, and one
//! that would take more memory than is free stops with an error.  As it
//! goes, it reports each stage on a line of its own, `{"id", "progress"}`,
//! `progress` one of `octree` (sampling the shapes, most of the time),
//! `triangles`, `simplifying`, with `tolerance`, and `writing`.  The reply
//! has `triangles`, `meshed` (the triangles before simplifying),
//! `tolerance`, `bounds` and `ms`; a cancelled export leaves `output` as
//! it was.
//!
//! ## `trace`
//!
//! `{"id", "op": "trace", "output", "format", "bounds", "slice",
//! "resolution", "tolerance", "kerf"}` writes the outlines of the shapes
//! on the plane of `slice`, `{"axis", "offset", "tilt"}` as `render` has
//! it, as `format`, `svg` or `dxf`, in millimetres, in the plane's right
//! and up; without `slice`, the plane is across Z through the middle of
//! the region.  Each role's shapes are
//! traced as their union, cut to the region, on a grid of cells no larger
//! than 1/`resolution` (the script's when null, else 1024 cells across the
//! region), and fitted with lines and circular arcs within `tolerance`,
//! a tenth of a cell when null, a line between every two points when 0.
//! The shapes to cut grow by half the `kerf`, 0 by default.  It runs as
//! `mesh` does, its stages `grid`, `contours` and `simplifying` for each
//! role in turn, then `writing`.  The reply has `outlines`, `lines`,
//! `arcs`, `tolerance`, `bounds`, `slice` and `ms`.
//!
//! ## `cancel`
//!
//! `{"id", "op": "cancel"}` cancels the export waiting or running, as soon
//! as it is read.  The reply has `stopped`, whether there was one; the
//! export's own reply is then `cancelled: true`, unless it was writing
//! already.
//!
//! ## `eval`
//!
//! `{"id", "op": "eval", "source", "path", "dialect", "overrides",
//! "expression"}` runs the script, with `overrides` as `load` takes them,
//! keeping no scene, then `expression` in its scope.  The
//! reply has `output` and either `value`, a tree summarised as its value at
//! the origin and its fitted bounds, or `diagnostics` as `load` has them:
//! positioned in the expression when they are in it, in the script
//! otherwise.
//!
//! ## `docs`
//!
//! `{"id", "op": "docs", "dialect"}`: what scripts in `dialect` can call.
//! The reply has `shapes`,
//! `{"name", "doc", "signatures", "fields": [{"name", "type", "default", "doc"}]}`,
//! and `functions`, `{"name", "signatures", "types", "doc", "source",
//! "category"}` with `source` one of `fidget`, `rhai`, `prelude` and
//! `keycap`, and `category` a heading to group them under.  `types`, the
//! names a function's signatures use, is there only when it has some.
//! Signatures are in the manual's notation ("Reading signatures") where
//! the shape or doc comment gives types.  In the keycap dialect, a fidget
//! built-in with a better keycap call has `prefer`, that call, and `why`,
//! in a line; an entry that describes other names too lists them in
//! `aliases`, and each of them has a copy of it.
//!
//! `modules` describes the prelude's modules' functions as `functions`
//! does, under the names their headers import them as, `screws::hole`,
//! with `source` `module`.  `sections` are the files that describe them
//! all, a section of the reference each, `{"file", "kind", "names",
//! "module"}`: `file` its path in keycap's repository, `kind` what its
//! functions make, `names` its entries in order, and `module` a module's
//! name.  Every entry the reference has carries its `file` and `kind`.

mod arcs;
mod bounds;
mod camera;
mod contour;
mod diagnostic;
mod docs;
mod drawing;
mod gpu;
mod math;
mod mesh;
mod outline;
mod prefer;
mod protocol;
mod render;
mod reproject;
mod scene;
mod script;
mod server;
mod shade;
mod simplify;
mod ssao;
mod svg;
mod text;

use std::path::PathBuf;
use std::time::Duration;

const USAGE: &str = "usage: keycap-server [--prelude DIR] [--threads N] [--gpu-budget MS]";

fn main() {
    let mut prelude = None;
    let mut threads = None;
    let mut budget = gpu::BUDGET;
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--prelude") => match args.next() {
                Some(dir) => prelude = Some(PathBuf::from(dir)),
                None => fail("--prelude needs a directory"),
            },
            Some("--threads") => match args.next().and_then(|n| n.to_str()?.parse().ok()) {
                Some(n) if n > 0 => threads = Some(n),
                _ => fail("--threads needs a positive number"),
            },
            Some("--gpu-budget") => match args.next().and_then(|n| n.to_str()?.parse().ok()) {
                Some(ms) if ms > 0 => budget = Duration::from_millis(ms),
                _ => fail("--gpu-budget needs a positive number of milliseconds"),
            },
            Some("--help" | "-h") => {
                println!("{USAGE}");
                return;
            }
            Some("--version") => {
                println!("keycap-server {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            _ => fail(&format!("unexpected argument {arg:?}")),
        }
    }
    if let Err(error) = render::pool(threads) {
        fail(&error);
    }
    server::run(prelude.as_deref(), threads, budget);
}

fn fail(message: &str) -> ! {
    eprintln!("keycap-server: {message}\n{USAGE}");
    std::process::exit(2);
}
