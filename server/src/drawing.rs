// SPDX-License-Identifier: MPL-2.0

//! 2D export: the outlines of each role's shapes on a plane, as lines and
//! arcs, written as an SVG for laser cutters' own software or as a DXF
//! for CAD.
//!
//! Both are in millimetres, +Y up as in the model, and hold one group or
//! layer per role, in the colour laser software takes for it.  Each shape
//! is its holes, then its outline, and shapes inside holes come before the
//! shapes around them, so that a laser following the file in order cuts a
//! part loose last.

use std::io::Write;
use std::path::Path;

use fidget::context::Tree;
use fidget::jit::JitShape;
use fidget::var::Var;

use crate::arcs::{self, Path as Outline};
use crate::bounds::Box3;
use crate::contour::{self, Grid};
use crate::mesh::{Job, Stage};
use crate::outline::Point;
use crate::protocol::{Format, Slice};
use crate::render;
use crate::scene::{self, Orientation, Scene};
use crate::script::Role;
// Coordinates to a tenth of a micrometre
use crate::server::number;

/// One role's shapes, each its holes and then its outline.
pub struct Layer {
    pub role: Role,
    pub shapes: Vec<Vec<Outline>>,
}

/// What an export wrote.
pub struct Exported {
    pub outlines: usize,
    pub lines: usize,
    pub arcs: usize,
}

/// The union of each role's shapes the scene draws, turned so that the
/// plane of `slice` through `region` lies in xy and cut to the rectangle
/// from `lower` to `upper` on it; the shapes to cut grown by half the
/// `kerf`.
pub fn shapes(
    scene: &Scene,
    slice: Slice,
    region: &Box3,
    lower: Point,
    upper: Point,
    kerf: f64,
) -> Result<Vec<(Role, JitShape)>, String> {
    let (z, orientation) = (slice.offset, Orientation::of(&slice, region));
    let plane = Box3 {
        lower: [lower[0], lower[1], z - 1.0],
        upper: [upper[0], upper[1], z + 1.0],
    };
    let mut shapes = vec![];
    for role in Role::ALL {
        let drawn = scene.drawn.iter().filter(|d| d.role == role);
        let trees: Vec<Tree> = drawn.map(|d| d.tree.clone()).collect();
        if trees.is_empty() {
            continue;
        }
        let mut tree = scene.orient(&scene::union(trees), orientation);
        // Grown by the field's slope along the plane times half the kerf:
        // a 2D distance field grows by that much, and a slice of a solid,
        // whose field rises more slowly along the plane than across the
        // surface, about as much.
        if role == Role::Cut && kerf > 0.0 {
            let slope = (tree.deriv(Var::X).square() + tree.deriv(Var::Y).square()).sqrt();
            tree -= slope * (kerf / 2.0) as f32;
        }
        shapes.push((role, scene::jit(&scene::cut(&tree, &plane))?));
    }
    Ok(shapes)
}

/// Writes the outlines of `shapes` on `grid` at `z`, within `tolerance` of
/// the surface unless that is 0, to `output` as `format`, or returns
/// `None` once cancelled; a cancelled export leaves `output` as it was.
pub fn export(
    shapes: &[(Role, JitShape)],
    grid: &Grid,
    z: f64,
    tolerance: f64,
    format: Format,
    output: &Path,
    job: &Job,
) -> Result<Option<Exported>, String> {
    let mut layers = vec![];
    let mut extent = [[f64::INFINITY; 2], [f64::NEG_INFINITY; 2]];
    for (role, shape) in shapes {
        let Some(contours) = contour::trace(shape, grid, z, job)? else {
            return Ok(None);
        };
        for p in contours.iter().flatten() {
            for i in 0..2 {
                extent[0][i] = extent[0][i].min(p[i]);
                extent[1][i] = extent[1][i].max(p[i]);
            }
        }
        if tolerance > 0.0 {
            (job.progress)(Stage::Simplifying);
        }
        let shapes: Vec<Vec<Outline>> = contour::nest(contours)
            .iter()
            .map(|shape| shape.iter().map(|c| arcs::fit(c, tolerance)).collect())
            .collect();
        if !shapes.is_empty() {
            layers.push(Layer {
                role: *role,
                shapes,
            });
        }
    }
    // An empty drawing would only replace a good one.
    if layers.is_empty() {
        return Err("nothing to export: no outline crosses the plane within the bounds".into());
    }
    if job.cancel.is_cancelled() {
        return Ok(None);
    }

    (job.progress)(Stage::Writing);
    render::write_atomically(output, |file| match format {
        Format::Svg => write_svg(file, &layers, extent),
        Format::Dxf => write_dxf(file, &layers),
    })?;
    let outlines = layers.iter().flat_map(|l| l.shapes.iter().flatten());
    let segments = outlines.clone().flat_map(|o| &o.segments);
    let arcs = segments.clone().filter(|s| s.bulge != 0.0).count();
    Ok(Some(Exported {
        outlines: outlines.count(),
        lines: segments.count() - arcs,
        arcs,
    }))
}

// --- SVG ---

/// A hairline, as laser drivers that cut along strokes want them: a
/// thousandth of an inch.
const HAIRLINE: f64 = 0.0254;

/// Writes an SVG of `layers`, its page the `extent` of their points.
/// Shapes to engrave are filled, those to cut or score stroked; Y is
/// flipped, so that the drawing is the right way up.
pub fn write_svg(
    file: &mut impl Write,
    layers: &[Layer],
    [lower, upper]: [Point; 2],
) -> std::io::Result<()> {
    let (width, height) = (number(upper[0] - lower[0]), number(upper[1] - lower[1]));
    writeln!(file, r#"<?xml version="1.0" encoding="UTF-8"?>"#)?;
    writeln!(
        file,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{width}mm" height="{height}mm" viewBox="{} {} {width} {height}">"#,
        number(lower[0]),
        number(-upper[1]),
    )?;
    for layer in layers {
        let [r, g, b] = layer.role.rgb();
        let color = format!("#{r:02x}{g:02x}{b:02x}");
        let paint = match layer.role {
            Role::Engrave => format!(r#"fill="{color}" stroke="none""#),
            Role::Cut | Role::Score => {
                format!(r#"fill="none" stroke="{color}" stroke-width="{HAIRLINE}""#)
            }
        };
        writeln!(file, r#"  <g id="{}" {paint}>"#, layer.role.name())?;
        for shape in &layer.shapes {
            let d: Vec<String> = shape.iter().map(svg_path).collect();
            writeln!(file, r#"    <path d="{}"/>"#, d.join(" "))?;
        }
        writeln!(file, "  </g>")?;
    }
    writeln!(file, "</svg>")
}

/// `outline` as SVG path data, Y flipped.
fn svg_path(outline: &Outline) -> String {
    let point = |p: Point| format!("{} {}", number(p[0]), number(-p[1]));
    let mut d = format!("M {}", point(outline.start));
    let mut from = outline.start;
    for segment in &outline.segments {
        if segment.bulge == 0.0 {
            d += &format!(" L {}", point(segment.to));
        } else {
            let r = number(segment.radius(from));
            // Counterclockwise in the model is counterclockwise on the
            // page, which SVG, its Y down, calls a negative sweep.
            let sweep = u8::from(segment.bulge < 0.0);
            d += &format!(" A {r} {r} 0 0 {sweep} {}", point(segment.to));
        }
        from = segment.to;
    }
    d + " Z"
}

// --- DXF ---

/// The AutoCAD colour index of a role's layer: red, blue, and white, which
/// shows black on a light background.
fn aci(role: Role) -> u8 {
    match role {
        Role::Cut => 1,
        Role::Score => 5,
        Role::Engrave => 7,
    }
}

/// Writes an R12 DXF of `layers`, one layer per role, each outline a
/// closed polyline with its arcs as bulges.  R12 is the version every
/// reader takes; `$INSUNITS` 4 marks millimetres to those that read it.
pub fn write_dxf(file: &mut impl Write, layers: &[Layer]) -> std::io::Result<()> {
    let mut pair = |code: u16, value: &str| writeln!(file, "{code}\n{value}");
    for (code, value) in [
        (0, "SECTION"),
        (2, "HEADER"),
        (9, "$ACADVER"),
        (1, "AC1009"),
        (9, "$INSUNITS"),
        (70, "4"),
        (9, "$MEASUREMENT"),
        (70, "1"),
        (0, "ENDSEC"),
        (0, "SECTION"),
        (2, "TABLES"),
        (0, "TABLE"),
        (2, "LTYPE"),
        (70, "1"),
        (0, "LTYPE"),
        (2, "CONTINUOUS"),
        (70, "0"),
        (3, "Solid line"),
        (72, "65"),
        (73, "0"),
        (40, "0.0"),
        (0, "ENDTAB"),
        (0, "TABLE"),
        (2, "LAYER"),
    ] {
        pair(code, value)?;
    }
    pair(70, &layers.len().to_string())?;
    for layer in layers {
        pair(0, "LAYER")?;
        pair(2, layer.role.name())?;
        pair(70, "0")?;
        pair(62, &aci(layer.role).to_string())?;
        pair(6, "CONTINUOUS")?;
    }
    for (code, value) in [
        (0, "ENDTAB"),
        (0, "ENDSEC"),
        (0, "SECTION"),
        (2, "ENTITIES"),
    ] {
        pair(code, value)?;
    }
    for layer in layers {
        let name = layer.role.name();
        for outline in layer.shapes.iter().flatten() {
            for (code, value) in [(0, "POLYLINE"), (8, name), (66, "1"), (70, "1")] {
                pair(code, value)?;
            }
            for (code, value) in [(10, "0"), (20, "0"), (30, "0")] {
                pair(code, value)?;
            }
            // Each vertex carries the bulge of the segment that leaves it.
            let mut from = outline.start;
            for segment in &outline.segments {
                pair(0, "VERTEX")?;
                pair(8, name)?;
                pair(10, &number(from[0]))?;
                pair(20, &number(from[1]))?;
                pair(30, "0")?;
                if segment.bulge != 0.0 {
                    pair(42, &format!("{:.9}", segment.bulge))?;
                }
                from = segment.to;
            }
            pair(0, "SEQEND")?;
            pair(8, name)?;
        }
    }
    for (code, value) in [(0, "ENDSEC"), (0, "EOF")] {
        pair(code, value)?;
    }
    Ok(())
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::arcs::Segment;
    use crate::contour::distance;

    fn line(to: Point) -> Segment {
        Segment { to, bulge: 0.0 }
    }

    /// A plate 10 by 6 with a round hole, to cut, and a quarter-round
    /// mark to engrave.
    fn layers() -> Vec<Layer> {
        let hole = Outline {
            start: [2.0, 0.0],
            segments: vec![
                Segment {
                    to: [0.0, 0.0],
                    bulge: -1.0,
                },
                Segment {
                    to: [2.0, 0.0],
                    bulge: -1.0,
                },
            ],
        };
        let plate = Outline {
            start: [-5.0, -3.0],
            segments: vec![
                line([5.0, -3.0]),
                line([5.0, 3.0]),
                line([-5.0, 3.0]),
                line([-5.0, -3.0]),
            ],
        };
        let mark = Outline {
            start: [-4.0, 1.0],
            segments: vec![
                line([-3.0, 1.0]),
                Segment {
                    to: [-4.0, 2.0],
                    bulge: (std::f64::consts::FRAC_PI_2 / 4.0).tan(),
                },
                line([-4.0, 1.0]),
            ],
        };
        vec![
            Layer {
                role: Role::Engrave,
                shapes: vec![vec![mark]],
            },
            Layer {
                role: Role::Cut,
                shapes: vec![vec![hole, plate]],
            },
        ]
    }

    /// The outlines read back from `paths`, the `d` of each path in turn
    /// with its subpaths: SVG's Y down and arcs as radius and sweep.
    fn read_svg_paths(paths: &[&str]) -> Vec<Outline> {
        let mut outlines = vec![];
        for d in paths {
            let mut tokens = d.split_whitespace();
            let mut number = || tokens.next().and_then(|t| t.parse::<f64>().ok());
            let words = d.split_whitespace().filter(|t| t.parse::<f64>().is_err());
            let mut from = [0.0; 2];
            for command in words {
                assert_eq!(number(), None, "{command} follows its numbers");
                match command {
                    "M" => {
                        from = [number().unwrap(), -number().unwrap()];
                        outlines.push(Outline {
                            start: from,
                            segments: vec![],
                        });
                    }
                    "L" => {
                        let to = [number().unwrap(), -number().unwrap()];
                        outlines.last_mut().unwrap().segments.push(line(to));
                        from = to;
                    }
                    "A" => {
                        let r = number().unwrap();
                        assert_eq!(number(), Some(r));
                        assert_eq!((number(), number()), (Some(0.0), Some(0.0)));
                        let sweep = number().unwrap();
                        let to = [number().unwrap(), -number().unwrap()];
                        // The bulge whose arc has radius r over this chord
                        let half = distance(from, to) / 2.0;
                        let height = r - (r * r - half * half).max(0.0).sqrt();
                        let bulge = height / half * if sweep == 0.0 { 1.0 } else { -1.0 };
                        let segments = &mut outlines.last_mut().unwrap().segments;
                        segments.push(Segment { to, bulge });
                        from = to;
                    }
                    "Z" => {}
                    other => panic!("unexpected {other}"),
                }
            }
        }
        outlines
    }

    fn same(read: &[Outline], written: &[&Outline]) {
        assert_eq!(read.len(), written.len());
        for (a, b) in read.iter().zip(written) {
            assert!(distance(a.start, b.start) < 1e-4);
            assert_eq!(a.segments.len(), b.segments.len());
            for (s, t) in a.segments.iter().zip(&b.segments) {
                assert!(distance(s.to, t.to) < 1e-4, "{s:?} {t:?}");
                assert!((s.bulge - t.bulge).abs() < 1e-4, "{s:?} {t:?}");
            }
        }
    }

    #[test]
    fn svg_reads_back() {
        let layers = layers();
        let mut file = vec![];
        write_svg(&mut file, &layers, [[-5.0, -3.0], [5.0, 3.0]]).unwrap();
        let svg = String::from_utf8(file).unwrap();
        assert!(
            svg.contains(r#"width="10mm" height="6mm" viewBox="-5 -3 10 6""#),
            "{svg}"
        );
        // Engraving first, filled; cutting last, a red hairline
        let engrave = svg.find(r##"<g id="engrave" fill="#000000" stroke="none">"##);
        let cut = svg.find(r##"<g id="cut" fill="none" stroke="#ff0000" stroke-width="0.0254">"##);
        assert!(engrave.is_some() && engrave < cut, "{svg}");
        let paths: Vec<&str> = svg
            .split(r#"<path d=""#)
            .skip(1)
            .map(|p| p.split('"').next().unwrap())
            .collect();
        assert_eq!(paths.len(), 2);
        let written: Vec<&Outline> = layers
            .iter()
            .flat_map(|l| l.shapes.iter().flatten())
            .collect();
        same(&read_svg_paths(&paths), &written);
    }

    #[test]
    fn dxf_reads_back() {
        let layers = layers();
        let mut file = vec![];
        write_dxf(&mut file, &layers).unwrap();
        let dxf = String::from_utf8(file).unwrap();
        let lines: Vec<&str> = dxf.lines().collect();
        assert_eq!(lines.len() % 2, 0);
        let pairs: Vec<(u16, &str)> = lines
            .chunks(2)
            .map(|p| (p[0].parse().expect("a group code"), p[1]))
            .collect();
        let units = pairs.iter().position(|&p| p == (9, "$INSUNITS"));
        assert_eq!(units.map(|i| pairs[i + 1]), Some((70, "4")));
        assert_eq!(pairs.last(), Some(&(0, "EOF")));
        let layer_colours: Vec<(&str, &str)> = pairs
            .windows(5)
            .filter(|w| w[0] == (0, "LAYER") && w[1].0 == 2)
            .map(|w| (w[1].1, w[3].1))
            .collect();
        assert_eq!(layer_colours, [("engrave", "7"), ("cut", "1")]);

        // Each polyline's layer and closed flag, then its vertices
        let mut read: Vec<(Vec<Segment>, bool)> = vec![];
        let mut layer_of = vec![];
        let mut in_vertex = false;
        for &(code, value) in pairs.iter().skip_while(|&&p| p != (2, "ENTITIES")) {
            if (code, value) == (0, "POLYLINE") {
                read.push((vec![], false));
                continue;
            }
            let number = || value.parse::<f64>().unwrap();
            let Some((vertices, closed)) = read.last_mut() else {
                continue;
            };
            match (code, value) {
                (0, _) => in_vertex = value == "VERTEX",
                (8, layer) if !in_vertex => layer_of.push(layer),
                (70, "1") if !in_vertex => *closed = true,
                (10, _) if in_vertex => vertices.push(line([number(), 0.0])),
                (20, _) if in_vertex => vertices.last_mut().unwrap().to[1] = number(),
                (42, _) => vertices.last_mut().unwrap().bulge = number(),
                _ => {}
            }
        }
        // Layer names come once per polyline and once per SEQEND.
        assert_eq!(layer_of, ["engrave", "engrave", "cut", "cut", "cut", "cut"]);
        assert!(read.iter().all(|(_, closed)| *closed));
        // A vertex holds the bulge of the segment leaving it.
        let outlines: Vec<Outline> = read
            .into_iter()
            .map(|(vertices, _)| {
                let n = vertices.len();
                Outline {
                    start: vertices[0].to,
                    segments: (0..n)
                        .map(|k| Segment {
                            to: vertices[(k + 1) % n].to,
                            bulge: vertices[k].bulge,
                        })
                        .collect(),
                }
            })
            .collect();
        let written: Vec<&Outline> = layers
            .iter()
            .flat_map(|l| l.shapes.iter().flatten())
            .collect();
        same(&outlines, &written);
    }
}
