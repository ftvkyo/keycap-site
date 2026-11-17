// SPDX-License-Identifier: MPL-2.0

//! `svg`: the shapes of an SVG file, in millimetres, as OpenSCAD's
//! `import()` takes them.
//!
//! usvg resolves the file (units, transforms, CSS, `<use>`, text) to paths
//! on a canvas of the document's size, at 96 pixels to the inch.  Like
//! OpenSCAD, every closed subpath counts as an area whatever its paint, so
//! that outlines drawn as strokes in Inkscape or KiCad import filled, and
//! open subpaths count as their stroke.  OpenSCAD 2021.01 fills every
//! path even-odd; here a filled path keeps its own `fill-rule`, and only a
//! path without a fill is filled even-odd.  Paths overlap as a union.

use std::path::Path;

use fidget::context::Tree;
use i_overlay::core::fill_rule::FillRule;
use kurbo::{Affine, BezPath};
use rhai::Map;
use usvg::tiny_skia_path::{self, PathSegment};
use usvg::{Group, Node};

use crate::outline::{self, Contour};
use crate::text::Fonts;

/// Millimetres per CSS pixel
const MM: f64 = 25.4 / 96.0;

/// Curves become lines no further than this from them, in millimetres.
const TOLERANCE: f64 = 0.01;

/// The width of an open subpath without a stroke, in pixels: SVG's
/// default `stroke-width`.
const STROKE: f32 = 1.0;

/// `svg`'s options, as its map gives them
pub struct Options {
    center: bool,
    id: Option<String>,
}

impl Options {
    pub fn new(map: Option<Map>) -> Result<Self, String> {
        let mut options = Options {
            center: false,
            id: None,
        };
        for (key, value) in map.into_iter().flatten() {
            match key.as_str() {
                "center" => {
                    options.center = value
                        .as_bool()
                        .map_err(|_| "svg: center must be true or false".to_owned())?;
                }
                "id" => {
                    options.id = Some(
                        value
                            .into_string()
                            .map_err(|_| "svg: id must be a string".to_owned())?,
                    );
                }
                other => {
                    return Err(format!(
                        "svg: no option {other:?}; the options are center and id"
                    ));
                }
            }
        }
        Ok(options)
    }
}

/// The shapes of the SVG file `path`, with the origin at the document's
/// bottom left corner, or their centre with `center`.
pub fn svg(fonts: &Fonts, path: &Path, options: &Options) -> Result<Tree, String> {
    let name = path.display();
    let data = std::fs::read(path).map_err(|error| format!("svg: cannot read {name}: {error}"))?;
    let mut usvg_options = usvg::Options {
        resources_dir: path.parent().map(Path::to_path_buf),
        ..usvg::Options::default()
    };
    // Reading the installed fonts takes a while; only text needs them.
    if data.windows(5).any(|w| w == b"<text") {
        *usvg_options.fontdb_mut() = fonts.system().clone();
    }
    let tree = usvg::Tree::from_data(&data, &usvg_options)
        .map_err(|error| format!("svg: cannot read {name}: {error}"))?;

    // SVG's y runs down from the top; ours up from the bottom.
    let height = f64::from(tree.size().height());
    let to_mm = Affine::new([MM, 0.0, 0.0, -MM, 0.0, height * MM]);
    let mut areas = vec![];
    match &options.id {
        Some(id) => {
            let node = tree
                .node_by_id(id)
                .ok_or_else(|| format!("svg: {name} has no element with id {id:?}"))?;
            collect(node, to_mm, &mut areas);
        }
        None => {
            for node in tree.root().children() {
                collect(node, to_mm, &mut areas);
            }
        }
    }
    let mut contours = outline::clean(&areas, FillRule::NonZero);
    if options.center {
        let mut lower = [f64::INFINITY; 2];
        let mut upper = [f64::NEG_INFINITY; 2];
        for p in contours.iter().flatten() {
            for i in 0..2 {
                lower[i] = lower[i].min(p[i]);
                upper[i] = upper[i].max(p[i]);
            }
        }
        let centre = [0, 1].map(|i| (lower[i] + upper[i]) / 2.0);
        for p in contours.iter_mut().flatten() {
            *p = [p[0] - centre[0], p[1] - centre[1]];
        }
    }
    Ok(outline::field(&contours))
}

/// Adds the areas `node` covers to `areas`, each path's already cleaned
/// under its own fill rule, so that a nonzero union of all of them is
/// their union.
fn collect(node: &Node, to_mm: Affine, areas: &mut Vec<Contour>) {
    match node {
        Node::Group(group) => collect_group(group, to_mm, areas),
        Node::Text(text) => collect_group(text.flattened(), to_mm, areas),
        Node::Path(path) => {
            let transform = to_mm * affine(path.abs_transform());
            // usvg drops the rule of a path it does not fill; OpenSCAD
            // fills those even-odd.
            let rule = match path.fill().map(usvg::Fill::rule) {
                Some(usvg::FillRule::NonZero) => FillRule::NonZero,
                _ => FillRule::EvenOdd,
            };
            let data = path.data();
            let (closed, open) = outline::flatten(&(transform * bez(data)), TOLERANCE);
            areas.extend(outline::clean(&closed, rule));
            if open.is_empty() {
                return;
            }
            let stroke = path.stroke().map_or_else(
                || tiny_skia_path::Stroke {
                    width: STROKE,
                    ..Default::default()
                },
                usvg::Stroke::to_tiny_skia,
            );
            // The stroker's curves as fine as the tolerance, in the path's units
            let resolution = (transform.determinant().abs().sqrt() / TOLERANCE) as f32;
            let strokes = open_subpaths(data).and_then(|open| open.stroke(&stroke, resolution));
            if let Some(strokes) = strokes {
                let (outlines, _) = outline::flatten(&(transform * bez(&strokes)), TOLERANCE);
                areas.extend(outline::clean(&outlines, FillRule::NonZero));
            }
        }
        Node::Image(_) => {}
    }
}

fn collect_group(group: &Group, to_mm: Affine, areas: &mut Vec<Contour>) {
    for child in group.children() {
        collect(child, to_mm, areas);
    }
}

fn affine(t: usvg::Transform) -> Affine {
    Affine::new([t.sx, t.ky, t.kx, t.sy, t.tx, t.ty].map(f64::from))
}

fn bez(path: &tiny_skia_path::Path) -> BezPath {
    let mut out = BezPath::new();
    let p = |p: tiny_skia_path::Point| kurbo::Point::new(f64::from(p.x), f64::from(p.y));
    for segment in path.segments() {
        match segment {
            PathSegment::MoveTo(a) => out.move_to(p(a)),
            PathSegment::LineTo(a) => out.line_to(p(a)),
            PathSegment::QuadTo(a, b) => out.quad_to(p(a), p(b)),
            PathSegment::CubicTo(a, b, c) => out.curve_to(p(a), p(b), p(c)),
            PathSegment::Close => out.close_path(),
        }
    }
    out
}

/// The subpaths of `path` that it leaves open, for stroking.
fn open_subpaths(path: &tiny_skia_path::Path) -> Option<tiny_skia_path::Path> {
    let mut out = tiny_skia_path::PathBuilder::new();
    let mut current: Vec<PathSegment> = vec![];
    let mut flush = |current: &mut Vec<PathSegment>, closed: bool| {
        if !closed {
            for segment in current.iter() {
                match *segment {
                    PathSegment::MoveTo(a) => out.move_to(a.x, a.y),
                    PathSegment::LineTo(a) => out.line_to(a.x, a.y),
                    PathSegment::QuadTo(a, b) => out.quad_to(a.x, a.y, b.x, b.y),
                    PathSegment::CubicTo(a, b, c) => out.cubic_to(a.x, a.y, b.x, b.y, c.x, c.y),
                    PathSegment::Close => {}
                }
            }
        }
        current.clear();
    };
    for segment in path.segments() {
        match segment {
            PathSegment::MoveTo(_) => {
                flush(&mut current, false);
                current.push(segment);
            }
            PathSegment::Close => flush(&mut current, true),
            _ => current.push(segment),
        }
    }
    flush(&mut current, false);
    out.finish()
}
