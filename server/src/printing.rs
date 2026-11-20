// SPDX-License-Identifier: MPL-2.0

//! 3MF export for FDM slicers: a coarse mesh of the shapes, for what
//! slicers still need a mesh for -- placing and previewing a part, its
//! seams and painting -- with layer heights from the field's slopes, as
//! PrusaSlicer and OrcaSlicer read them, and the layers themselves,
//! traced from the field at the heights the slicer will cut, for a slicer
//! plugin to put in place of the ones it cuts from the mesh.
//!
//! The part stands on z = 0, centred on the origin in x and y, as a
//! slicer places its layers: the mesh's lowest point and the middle of
//! its footprint.  The layers are in the same coordinates.

use std::io::Write;
use std::path::Path;

use fidget::jit::JitShape;
use fidget::mesh::Mesh;

use crate::bounds::Box3;
use crate::contour::Grid;
use crate::layers::{self, Heights, Layer};
use crate::mesh::{self, Job, Stage};
use crate::outline::Point;
use crate::render;
// Coordinates to a tenth of a micrometre
use crate::server::number;
use crate::zip::Zip;

/// The depth of the octree the coarse mesh is made on: 128 cells across.
const MESH_DEPTH: u8 = 7;

/// How far the coarse mesh may stray from the surface as it is simplified,
/// in millimetres: well under a nozzle's width, so that seams and paint
/// land where the layers are.
pub const MESH_TOLERANCE: f64 = 0.02;

/// What an export wrote.
pub struct Exported {
    pub triangles: usize,
    pub layers: usize,
    pub points: usize,
}

/// Writes the 3MF of `shape`, the union cut to `region`, to `output`, its
/// object `name`, its layers as `heights` allows and traced on a grid of
/// `cell`s, or returns `None` once cancelled; a cancelled export leaves
/// `output` as it was.
pub fn export(
    shape: &JitShape,
    region: &Box3,
    cell: f64,
    heights: &Heights,
    name: &str,
    output: &Path,
    job: &Job,
) -> Result<Option<Exported>, String> {
    let Some((mut mesh, _)) = mesh::build(shape, region, MESH_DEPTH, MESH_TOLERANCE, job)? else {
        return Ok(None);
    };
    let (lower, upper) = extent(&mesh);
    let shift = [
        (lower[0] + upper[0]) / 2.0,
        (lower[1] + upper[1]) / 2.0,
        lower[2],
    ];
    let top = upper[2] - lower[2];
    for v in &mut mesh.vertices {
        for i in 0..3 {
            v[i] = (f64::from(v[i]) - shift[i]) as f32;
        }
    }

    // Levelness sampled twice per thinnest layer, on the mesh's cells
    let step = heights.min / 2.0;
    let samples: Vec<f64> = (0..(top / step).ceil() as usize)
        .map(|i| (i as f64 + 0.5) * step)
        .collect();
    let footprint = [region.lower, region.upper].map(|c| [c[0], c[1]]);
    let coarse = Grid::new(footprint[0], footprint[1], mesh::cell(region, MESH_DEPTH))?;
    let at: Vec<f64> = samples.iter().map(|z| z + shift[2]).collect();
    let Some(levels) = layers::levelness(shape, &coarse, &at, job)? else {
        return Ok(None);
    };
    let allowed: Vec<(f64, f64)> = samples
        .iter()
        .zip(levels)
        .map(|(&z, level)| (z, heights.allowed(level)))
        .collect();
    let profile = layers::profile(&layers::plan(&allowed, heights, top), top);
    let middles: Vec<f64> = layers::slicer_layers(&profile, heights, top)
        .iter()
        .map(|[lo, hi]| (lo + hi) / 2.0 + shift[2])
        .collect();
    let grid = Grid::new(footprint[0], footprint[1], cell)?;
    let Some(mut stack) = layers::slice(shape, &grid, &middles, job)? else {
        return Ok(None);
    };
    for layer in &mut stack {
        layer.z -= shift[2];
        for p in layer.shapes.iter_mut().flatten().flatten() {
            *p = [p[0] - shift[0], p[1] - shift[1]];
        }
    }
    if job.cancel.is_cancelled() {
        return Ok(None);
    }

    (job.progress)(Stage::Writing);
    let profile = layers::profile_line(1, &profile);
    let mut sidecar = vec![];
    write_sidecar(&mut sidecar, name, top, heights, &hull(&mesh), &stack)
        .map_err(|e| e.to_string())?;
    let mut model = vec![];
    write_model(&mut model, name, &mesh).map_err(|e| e.to_string())?;
    let entries: [(&str, &[u8]); 6] = [
        ("[Content_Types].xml", CONTENT_TYPES.as_bytes()),
        ("_rels/.rels", RELS.as_bytes()),
        ("3D/3dmodel.model", &model),
        // OrcaSlicer reads only the first, PrusaSlicer only the second.
        ("Metadata/layer_heights_profile.txt", profile.as_bytes()),
        (
            "Metadata/Slic3r_PE_layer_heights_profile.txt",
            profile.as_bytes(),
        ),
        ("Metadata/keycap_layers.json", &sidecar),
    ];
    render::write_atomically(output, |file| {
        let mut zip = Zip::new(file);
        for (name, data) in entries {
            zip.add_deflated(name, data)?;
        }
        zip.finish().map(drop)
    })?;
    let contours = stack.iter().flat_map(|l| l.shapes.iter().flatten());
    Ok(Some(Exported {
        triangles: mesh.triangles.len(),
        layers: stack.len(),
        points: contours.map(Vec::len).sum(),
    }))
}

fn extent(mesh: &Mesh) -> ([f64; 3], [f64; 3]) {
    let mut lower = [f64::INFINITY; 3];
    let mut upper = [f64::NEG_INFINITY; 3];
    for v in &mesh.vertices {
        for i in 0..3 {
            lower[i] = lower[i].min(f64::from(v[i]));
            upper[i] = upper[i].max(f64::from(v[i]));
        }
    }
    (lower, upper)
}

/// The convex hull of the mesh's footprint, counterclockwise: a slicer
/// centres a part turned about z on the middle of its turned footprint,
/// which a plugin finds from this.
fn hull(mesh: &Mesh) -> Vec<Point> {
    let mut points: Vec<Point> = mesh
        .vertices
        .iter()
        .map(|v| [f64::from(v[0]), f64::from(v[1])])
        .collect();
    points.sort_by(|a, b| a[0].total_cmp(&b[0]).then(a[1].total_cmp(&b[1])));
    points.dedup();
    let turns_left = |o: Point, a: Point, b: Point| {
        (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]) > 0.0
    };
    // Andrew's monotone chain: the lower half, then the upper.
    let mut hull: Vec<Point> = vec![];
    for pass in [
        &points[..],
        &points.iter().rev().copied().collect::<Vec<_>>(),
    ] {
        let start = hull.len();
        for &p in pass {
            while hull.len() >= start + 2
                && !turns_left(hull[hull.len() - 2], hull[hull.len() - 1], p)
            {
                hull.pop();
            }
            hull.push(p);
        }
        hull.pop();
    }
    hull
}

// --- 3MF ---

const CONTENT_TYPES: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
 <Default Extension="txt" ContentType="text/plain"/>
 <Default Extension="json" ContentType="application/json"/>
</Types>
"#;

const RELS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
"#;

/// Writes the model part of the 3MF: `mesh` as one object, `name`, in
/// millimetres.
fn write_model(file: &mut impl Write, name: &str, mesh: &Mesh) -> std::io::Result<()> {
    writeln!(file, r#"<?xml version="1.0" encoding="UTF-8"?>"#)?;
    writeln!(
        file,
        r#"<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">"#
    )?;
    writeln!(file, r#" <metadata name="Application">keycap</metadata>"#)?;
    writeln!(file, " <resources>")?;
    writeln!(
        file,
        r#"  <object id="1" name="{}" type="model">"#,
        escape(name)
    )?;
    writeln!(file, "   <mesh>\n    <vertices>")?;
    for v in &mesh.vertices {
        let [x, y, z] = [v[0], v[1], v[2]].map(|c| number(f64::from(c)));
        writeln!(file, r#"     <vertex x="{x}" y="{y}" z="{z}"/>"#)?;
    }
    writeln!(file, "    </vertices>\n    <triangles>")?;
    for t in &mesh.triangles {
        writeln!(
            file,
            r#"     <triangle v1="{}" v2="{}" v3="{}"/>"#,
            t[0], t[1], t[2]
        )?;
    }
    writeln!(
        file,
        "    </triangles>\n   </mesh>\n  </object>\n </resources>"
    )?;
    writeln!(file, " <build>\n  <item objectid=\"1\"/>\n </build>")?;
    writeln!(file, "</model>")
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Writes the layers for a plugin to find, as JSON: the part's `name`,
/// `height` and footprint's `hull`, the `first_layer_height` the profile
/// requires, and the `layers` as `layers::write_json` has them, `z` each
/// one's middle, where the slicer cuts it.
fn write_sidecar(
    file: &mut impl Write,
    name: &str,
    height: f64,
    heights: &Heights,
    hull: &[Point],
    layers: &[Layer],
) -> std::io::Result<()> {
    let hull: Vec<String> = hull.iter().flatten().map(|&v| number(v)).collect();
    writeln!(file, r#"{{"unit": "mm", "objects": [{{"#)?;
    writeln!(
        file,
        r#""object_id": 1, "name": {},"#,
        serde_json::Value::from(name)
    )?;
    writeln!(
        file,
        r#""height": {}, "first_layer_height": {},"#,
        number(height),
        number(heights.first)
    )?;
    writeln!(file, r#""hull": [{}],"#, hull.join(","))?;
    writeln!(file, r#""layers": ["#)?;
    layers::write_layers(file, layers)?;
    writeln!(file, "]}}]}}")
}

#[cfg(test)]
mod test {
    use nalgebra::Vector3;

    use super::*;

    /// The footprint's hull goes round its corners counterclockwise,
    /// leaving out the points inside and along its sides.
    #[test]
    fn a_hull_of_corners() {
        let mut mesh = Mesh::new();
        for (x, y) in [(0, 0), (2, 0), (1, 1), (2, 2), (0, 2), (1, 0), (1, 2)] {
            mesh.vertices.push(Vector3::new(x as f32, y as f32, 0.0));
        }
        assert_eq!(
            hull(&mesh),
            [[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]]
        );
    }
}
