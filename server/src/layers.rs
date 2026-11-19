// SPDX-License-Identifier: MPL-2.0

//! Layer stacks for 3D printing: the outlines of the shapes on level
//! planes, one per layer, as a slicer would cut them from a mesh.
//!
//! They are traced from the field by `contour`, so they have no facets:
//! their points lie on the surface at the layer's own height, whatever
//! the grid that finds them.

use std::io::Write;

use fidget::jit::JitShape;

use crate::contour::{self, Grid};
use crate::mesh::{Job, Stage};
use crate::outline::Contour;
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
    // One stage for the stack, not two for every layer
    let quiet = Job {
        progress: &|_| {},
        ..*job
    };
    let mut layers = vec![];
    for &z in zs {
        let Some(contours) = contour::trace(shape, grid, z, &quiet)? else {
            return Ok(None);
        };
        let shapes = contour::nest(contours)
            .into_iter()
            .map(|mut shape| {
                // `nest` puts the outline last.
                shape.rotate_right(1);
                shape
            })
            .collect();
        layers.push(Layer { z, shapes });
    }
    Ok(Some(layers))
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
    for (i, layer) in layers.iter().enumerate() {
        let separator = if i + 1 < layers.len() { "," } else { "" };
        writeln!(
            file,
            r#"{{"z": {}, "shapes": {}}}{separator}"#,
            number(layer.z),
            shapes_json(&layer.shapes)
        )?;
    }
    writeln!(file, "]}}")
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
}
