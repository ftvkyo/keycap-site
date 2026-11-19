// SPDX-License-Identifier: MPL-2.0

//! Layer stacks for 3D printing: the outlines of the shapes on level
//! planes, one per layer, as a slicer would cut them from a mesh.
//!
//! They are traced from the field by `contour`, so they have no facets:
//! their points lie on the surface at the layer's own height, whatever
//! the grid that finds them.  The layers' heights can come from the field
//! too, thinner where the surface is nearer level, and are then given to
//! slicers as the layer height profile PrusaSlicer and OrcaSlicer keep in
//! their 3MF projects.

use std::io::Write;

use fidget::jit::JitShape;
use nalgebra::Vector3;
use rayon::prelude::*;

use crate::contour::{self, Grid};
use crate::mesh::{Job, Stage};
use crate::outline::Contour;
use crate::reproject;
// Coordinates to a tenth of a micrometre
use crate::server::number;

/// The outlines on the plane at `z`, each shape its outline,
/// counterclockwise, and then its holes, clockwise, as slicers' polygons
/// with holes have them.
pub struct Layer {
    pub z: f64,
    pub shapes: Vec<Vec<Contour>>,
}

/// The layers of `shape` at each of `zs`, traced on `grid`, or `None`
/// once cancelled.
pub fn slice(
    shape: &JitShape,
    grid: &Grid,
    zs: &[f64],
    job: &Job,
) -> Result<Option<Vec<Layer>>, String> {
    (job.progress)(Stage::Layers);
    each_plane(shape, grid, zs, job, |z, contours| {
        let shapes = contour::nest(contours)
            .into_iter()
            .map(|mut shape| {
                // `nest` puts the outline last.
                shape.rotate_right(1);
                shape
            })
            .collect();
        Layer { z, shapes }
    })
}

/// `with` the height and the outlines of `shape` on the plane at each of
/// `zs`, traced on `grid`, the planes side by side; `None` once
/// cancelled.
fn each_plane<T: Send>(
    shape: &JitShape,
    grid: &Grid,
    zs: &[f64],
    job: &Job,
    with: impl Fn(f64, Vec<Contour>) -> T + Sync,
) -> Result<Option<Vec<T>>, String> {
    let (threads, cancel) = (job.threads, job.cancel);
    let traced = threads.run(|| {
        zs.par_iter()
            .map(|&z| {
                // One stage for the whole, not two for every plane
                let quiet = Job {
                    threads,
                    cancel,
                    progress: &|_| {},
                };
                Ok(contour::trace(shape, grid, z, &quiet)?.map(|c| with(z, c)))
            })
            .collect::<Result<Vec<_>, String>>()
    })?;
    Ok(traced.into_iter().collect())
}

/// The middles of the layers `height` thick from `bottom` up to `top`, the
/// last one ending at or past it.
pub fn uniform(bottom: f64, top: f64, height: f64) -> Vec<f64> {
    let count = ((top - bottom) / height).ceil().max(1.0) as usize;
    (0..count)
        .map(|i| bottom + (i as f64 + 0.5) * height)
        .collect()
}

/// Writes `layers` as JSON: `{"unit": "mm", "layers": [{"z", "shapes"}]}`,
/// each shape a list of contours and each contour its points' coordinates
/// in a flat list, `[x0, y0, x1, y1, ...]`; a layer a line.
pub fn write_json(file: &mut impl Write, layers: &[Layer]) -> std::io::Result<()> {
    writeln!(file, r#"{{"unit": "mm", "layers": ["#)?;
    write_layers(file, layers)?;
    writeln!(file, "]}}")
}

/// Writes the items of the list of `layers` that [`write_json`] writes.
pub fn write_layers(file: &mut impl Write, layers: &[Layer]) -> std::io::Result<()> {
    for (i, layer) in layers.iter().enumerate() {
        let separator = if i + 1 < layers.len() { "," } else { "" };
        writeln!(
            file,
            r#"{{"z": {}, "shapes": {}}}{separator}"#,
            number(layer.z),
            shapes_json(&layer.shapes)
        )?;
    }
    Ok(())
}

/// `shapes` as JSON lists, as [`write_json`] has them.
pub fn shapes_json(shapes: &[Vec<Contour>]) -> String {
    let list = |items: Vec<String>| format!("[{}]", items.join(","));
    list(
        shapes
            .iter()
            .map(|shape| {
                list(
                    shape
                        .iter()
                        .map(|c| list(c.iter().flatten().map(|&v| number(v)).collect()))
                        .collect(),
                )
            })
            .collect(),
    )
}

// --- Heights ---

/// The layer heights a print may use, in millimetres: the first layer's,
/// which slicers take from their settings and require of a profile, and
/// the range of the others.
#[derive(Clone, Copy, Debug)]
pub struct Heights {
    pub first: f64,
    pub min: f64,
    pub max: f64,
}

/// Layer heights are planned in micrometres, finer than printers step,
/// and divided rather than multiplied back, so that each is the number a
/// slicer reads from the profile, and their sums are the slicer's.
const STEPS: f64 = 1000.0;

/// How far below where a run of layers alike ends the profile's last pair
/// for it lies: less than any layer is thick, more than its precision.
const GAP: f64 = 1e-3;

impl Heights {
    /// How thick a layer may be where the surface's normal has `n_z` as
    /// its vertical part: by OrcaSlicer's adaptive layer heights' formula,
    /// its deviation set so that slopes of 45° and steeper take the
    /// thickest layers.
    pub fn allowed(&self, n_z: f64) -> f64 {
        let n_z = n_z.abs().min(1.0);
        let n_xy = (1.0 - n_z * n_z).sqrt();
        let height = if n_z > 1e-5 {
            self.max * (n_xy / n_z).sqrt()
        } else {
            self.max
        };
        let height = height.clamp(self.min, self.max);
        (height * STEPS).round() / STEPS
    }
}

/// How level the surface is where the plane at each of `zs` cuts it: the
/// largest vertical part of its normal at the points of the outlines
/// traced on `grid`, 0 where the plane misses the shape; `None` once
/// cancelled.
pub fn levelness(
    shape: &JitShape,
    grid: &Grid,
    zs: &[f64],
    job: &Job,
) -> Result<Option<Vec<f64>>, String> {
    (job.progress)(Stage::Heights);
    let tape = shape.grad_slice_tape(Default::default());
    each_plane(shape, grid, zs, job, |z, contours| {
        let points: Vec<Vector3<f32>> = contours
            .iter()
            .flatten()
            .map(|p| Vector3::new(p[0] as f32, p[1] as f32, z as f32))
            .collect();
        reproject::fields(&tape, &points, job.threads)
            .into_iter()
            .flatten()
            .map(|g| {
                let [dx, dy, dz] = [g.dx, g.dy, g.dz].map(f64::from);
                dz.abs() / (dx * dx + dy * dy + dz * dz).sqrt()
            })
            .fold(0.0, f64::max)
    })
}

/// The heights of the layers from 0 up to `top`: the first one's as
/// `heights` has it, and each other as thick as the thinnest that
/// `allowed`, pairs of a height and the thickness allowed there in
/// ascending order, allows within it.
pub fn plan(allowed: &[(f64, f64)], heights: &Heights, top: f64) -> Vec<f64> {
    let mut layers = vec![heights.first];
    let mut z = heights.first;
    while z < top {
        let mut height = heights.max;
        loop {
            let from = allowed.partition_point(|&(at, _)| at < z);
            let within = allowed[from..]
                .iter()
                .take_while(|&&(at, _)| at <= z + height);
            let thinnest = within.map(|&(_, h)| h).fold(height, f64::min);
            if thinnest >= height {
                break;
            }
            height = thinnest;
        }
        layers.push(height);
        z += height;
    }
    layers
}

/// The layer height profile of `layers` up to `top`, as slicers keep it:
/// pairs of a height and the layer height there, flat, which a slicer
/// interpolates between.  The layer height is constant across each run of
/// layers alike, and changes only past where the run ends, which no
/// layer's lookup reaches, so that the slicer's layers are those planned.
pub fn profile(layers: &[f64], top: f64) -> Vec<f64> {
    let mut profile = vec![];
    let mut z = 0.0;
    for run in layers.chunk_by(|a, b| a == b) {
        let height = run[0];
        let end = run.iter().fold(z, |z, h| z + h);
        profile.extend([z, height]);
        if end - GAP < top {
            profile.extend([end - GAP, height]);
        }
        z = end;
    }
    let last = layers.last().copied().unwrap_or_default();
    // A slicer requires at least three pairs, the last at the top.
    if profile.len() < 4 {
        profile.extend([top / 2.0, last]);
    }
    profile.extend([top, last]);
    profile
}

/// The layers a slicer makes of `profile` up to `top`, each as its lower
/// and upper height: OrcaSlicer's `generate_object_layers` for a part on
/// the bed, without a raft, which PrusaSlicer's matches.
pub fn slicer_layers(profile: &[f64], heights: &Heights, top: f64) -> Vec<[f64; 2]> {
    let mut layers = vec![[0.0, heights.first]];
    let mut print_z = heights.first;
    let mut slice_z = print_z + 0.5 * heights.min;
    let mut index = 0;
    while slice_z < top {
        let mut height = heights.min;
        if index < profile.len() {
            let mut next = index + 2;
            while next < profile.len() && slice_z >= profile[next] {
                index = next;
                next += 2;
            }
            let (z1, h1) = (profile[index], profile[index + 1]);
            height = h1;
            if next < profile.len() {
                let (z2, h2) = (profile[next], profile[next + 1]);
                height = h1 + (h2 - h1) * (slice_z - z1) / (z2 - z1);
            }
        }
        slice_z = print_z + 0.5 * height;
        if slice_z >= top {
            break;
        }
        layers.push([print_z, print_z + height]);
        print_z += height;
        slice_z = print_z + 0.5 * heights.min;
    }
    layers
}

/// `profile` as the line for the `object`th object, counted from 1, of
/// the files PrusaSlicer and OrcaSlicer keep it in.
pub fn profile_line(object: usize, profile: &[f64]) -> String {
    let values: Vec<String> = profile.iter().map(|v| format!("{v:.6}")).collect();
    format!("object_id={object}|{}\n", values.join(";"))
}

#[cfg(test)]
mod test {
    use fidget::context::Tree;
    use fidget::render::{CancelToken, ThreadPool};

    use super::*;
    use crate::contour::{area, distance};
    use crate::scene;

    fn slice_tree(tree: &Tree, half: f64, cell: f64, zs: &[f64]) -> Vec<Layer> {
        let shape = scene::jit(tree).expect("it compiles");
        let grid = Grid::new([-half, -half], [half, half], cell).expect("a grid");
        let cancel = CancelToken::new();
        let job = Job {
            threads: &ThreadPool::Global,
            cancel: &cancel,
            progress: &|_| {},
        };
        slice(&shape, &grid, zs, &job)
            .expect("it slices")
            .expect("not cancelled")
    }

    fn radius(p: [f64; 2]) -> f64 {
        distance(p, [0.0, 0.0])
    }

    /// As in `contour`'s tests
    const ON: f64 = 1e-5;

    /// A sphere's layers are circles as wide as it is at their heights,
    /// counterclockwise, and none above it.
    #[test]
    fn a_sphere_is_circles() {
        let (x, y, z) = Tree::axes();
        let sphere = (x.square() + y.square() + z.square()).sqrt() - 5.0;
        let zs = uniform(-5.0, 5.0, 0.4);
        let layers = slice_tree(&sphere, 6.0, 0.2, &zs);
        for layer in &layers {
            let r = (25.0 - layer.z * layer.z).sqrt();
            assert_eq!(layer.shapes.len(), 1, "at {}", layer.z);
            assert_eq!(layer.shapes[0].len(), 1);
            let outline = &layer.shapes[0][0];
            assert!(area(outline) > 0.0);
            for &p in outline {
                let off = radius(p) - r;
                assert!(off.abs() < ON, "{p:?} at {} is {off} off", layer.z);
            }
        }
        assert!(slice_tree(&sphere, 6.0, 0.2, &[5.5])[0].shapes.is_empty());
    }

    /// A torus lying flat is a ring on every layer it crosses: an outline
    /// and then a hole, each exact.
    #[test]
    fn a_torus_is_rings() {
        let (x, y, z) = Tree::axes();
        let around = (x.square() + y.square()).sqrt() - 4.0;
        let torus = (around.square() + z.square()).sqrt() - 1.5;
        for layer in slice_tree(&torus, 6.0, 0.25, &uniform(-1.5, 1.5, 0.2)) {
            let half = (2.25 - layer.z * layer.z).sqrt();
            assert_eq!(layer.shapes.len(), 1, "at {}", layer.z);
            let ring = &layer.shapes[0];
            assert_eq!(ring.len(), 2);
            assert!(area(&ring[0]) > 0.0 && area(&ring[1]) < 0.0);
            for (contour, r) in ring.iter().zip([4.0 + half, 4.0 - half]) {
                for &p in contour {
                    let off = radius(p) - r;
                    assert!(off.abs() < ON, "{p:?} at {} is {off} off", layer.z);
                }
            }
        }
    }

    /// The JSON is a layer a line, and reads back as written.
    #[test]
    fn json_reads_back() {
        let square = vec![[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
        let hole = vec![[0.25, 0.25], [0.25, 0.75], [0.75, 0.75], [0.75, 0.25]];
        let layers = [
            Layer {
                z: 0.1,
                shapes: vec![vec![square, hole]],
            },
            Layer {
                z: 0.3,
                shapes: vec![],
            },
        ];
        let mut out = vec![];
        write_json(&mut out, &layers).expect("it writes");
        let text = String::from_utf8(out).expect("UTF-8");
        assert_eq!(text.lines().count(), 4);
        let value: serde_json::Value = serde_json::from_str(&text).expect("JSON");
        assert_eq!(value["layers"][0]["z"], 0.1);
        assert_eq!(value["layers"][0]["shapes"][0][1][1], 0.25);
        assert_eq!(
            value["layers"][0]["shapes"][0][1].as_array().map(Vec::len),
            Some(8)
        );
        assert_eq!(value["layers"][1]["shapes"], serde_json::json!([]));
    }

    fn heights() -> Heights {
        Heights {
            first: 0.2,
            min: 0.08,
            max: 0.2,
        }
    }

    /// Walls take the thickest layers, slopes of 45° too, nearly level
    /// surfaces the thinnest, and those between something between.
    #[test]
    fn layers_thin_where_the_surface_levels() {
        let h = heights();
        assert_eq!(h.allowed(0.0), 0.2);
        assert_eq!(h.allowed(0.5f64.sqrt()), 0.2);
        assert_eq!(h.allowed(1.0), 0.08);
        let between = h.allowed(0.9);
        assert!(0.08 < between && between < 0.2, "{between}");
    }

    /// The layers a slicer makes of the profile are the planned ones, read
    /// back from the profile's text as a slicer reads it: a hemisphere's,
    /// which thin towards its top.
    #[test]
    fn slicers_make_the_planned_layers() {
        let h = heights();
        let top = 10.0;
        let allowed: Vec<(f64, f64)> = (0..500)
            .map(|i| {
                let z = (f64::from(i) + 0.5) * 0.02;
                (z, h.allowed(z / top))
            })
            .collect();
        let planned = plan(&allowed, &h, top);
        assert_eq!(planned[0], 0.2);
        assert_eq!(planned[1], 0.2);
        assert_eq!(*planned.last().unwrap(), 0.08);
        let line = profile_line(1, &profile(&planned, top));
        let (id, values) = line.trim_end().split_once('|').expect("object_id=1|...");
        assert_eq!(id, "object_id=1");
        let read: Vec<f64> = values.split(';').map(|v| v.parse().unwrap()).collect();
        assert!(read.len() > 4 && read.len().is_multiple_of(2));
        assert_eq!((read[0], read[1]), (0.0, 0.2));
        assert_eq!(read[read.len() - 2], top);
        let mut bottom = 0.0;
        let expected: Vec<[f64; 2]> = planned
            .iter()
            .map(|h| {
                let layer = [bottom, bottom + h];
                bottom += h;
                layer
            })
            .filter(|[lo, hi]| (lo + hi) / 2.0 < top)
            .collect();
        assert_eq!(slicer_layers(&read, &h, top), expected);
    }

    /// Layers all alike still make a profile of three pairs.
    #[test]
    fn a_profile_has_three_pairs() {
        let h = heights();
        let planned = plan(&[], &h, 1.0);
        assert_eq!(planned, [0.2; 5]);
        let profile = profile(&planned, 1.0);
        assert_eq!(profile.len(), 6);
        assert_eq!(slicer_layers(&profile, &h, 1.0).len(), 5);
    }
}
