// SPDX-License-Identifier: MPL-2.0

//! The outlines of a shape on a plane, for 2D export: traced by marching
//! squares on a grid, each point then moved onto the surface along its
//! edge by Newton's method, and the sharp corners the grid cuts off put
//! back where the surface's tangents meet.
//!
//! The grid decides which outlines there are; the field decides where
//! their points lie, so a coarse grid places them as exactly as a fine
//! one, and only misses features smaller than a cell.

use std::collections::HashMap;

use fidget::jit::{JitBulkFn, JitShape};
use fidget::raster::pixel::{self, DistancePixel, RawDistancePixel};
use fidget::render::ImageSize;
use fidget::shape::ShapeTape;
use fidget::types::Grad;
use nalgebra::{Matrix3, Vector3};

use crate::mesh::{Job, Stage};
use crate::outline::{Contour, Point};
use crate::{reproject, scene};

type Tape = ShapeTape<JitBulkFn<Grad>>;

/// The most corners the grid has along a side.
const MAX_SIDE: usize = 16384;

/// Newton steps each crossing is given along its edge.
const ROOT_STEPS: usize = 8;

/// A crossing whose step moves it less than this share of its edge has
/// arrived.
const ARRIVED: f64 = 1e-6;

/// Two neighbouring points whose normals turn by more than this, as a
/// cosine (10°), may have a sharp corner between them.
const TURN: f64 = 0.985;

/// The grid a shape is sampled on: `width` by `height` corners, corner
/// (i, j) at `lower + cell * (i, j)`.
pub struct Grid {
    pub lower: Point,
    pub cell: f64,
    pub width: usize,
    pub height: usize,
}

impl Grid {
    /// The grid of cells `cell` across over the rectangle from `lower` to
    /// `upper`, and a cell beyond it on every side, so that a shape cut to
    /// the rectangle leaves every corner on the grid's rim outside.
    pub fn new(lower: Point, upper: Point, cell: f64) -> Result<Grid, String> {
        // Counted as floats, as a count past `usize` would wrap when cast.
        let corners = |i: usize| ((upper[i] - lower[i]) / cell).ceil() + 3.0;
        let (width, height) = (corners(0), corners(1));
        if width.max(height) > MAX_SIDE as f64 {
            return Err(format!(
                "cells of {cell} make a grid of {width} by {height} over this region; \
                 at most {MAX_SIDE} a side is supported"
            ));
        }
        Ok(Grid {
            lower: [lower[0] - cell, lower[1] - cell],
            cell,
            width: width as usize,
            height: height as usize,
        })
    }

    fn corner(&self, i: usize, j: usize) -> Point {
        [
            self.lower[0] + self.cell * i as f64,
            self.lower[1] + self.cell * j as f64,
        ]
    }

    /// The corners of `edge`: horizontal edges, from (i, j) to (i + 1, j),
    /// have even ids, vertical ones, from (i, j) to (i, j + 1), odd.
    fn ends(&self, edge: usize) -> [(usize, usize); 2] {
        let (i, j) = ((edge / 2) % self.width, (edge / 2) / self.width);
        if edge.is_multiple_of(2) {
            [(i, j), (i + 1, j)]
        } else {
            [(i, j), (i, j + 1)]
        }
    }
}

fn horizontal(grid: &Grid, i: usize, j: usize) -> usize {
    2 * (j * grid.width + i)
}

fn vertical(grid: &Grid, i: usize, j: usize) -> usize {
    2 * (j * grid.width + i) + 1
}

/// The outlines where `shape` crosses zero on the plane at `z`, sampled on
/// `grid`, each closed and running counterclockwise around the inside:
/// outlines counterclockwise, holes clockwise.  `None` once cancelled.
pub fn trace(
    shape: &JitShape,
    grid: &Grid,
    z: f64,
    job: &Job,
) -> Result<Option<Vec<Contour>>, String> {
    (job.progress)(Stage::Grid);
    let Some(pixels) = sample(shape, grid, z, job)? else {
        return Ok(None);
    };
    (job.progress)(Stage::Contours);
    let inside: Vec<bool> = pixels.iter().map(|p| p.inside()).collect();
    let tape = shape.grad_slice_tape(Default::default());
    let at = |p: Point| Vector3::new(p[0] as f32, p[1] as f32, z as f32);

    let (mut steps, saddles) = march(grid, &inside);
    let centres: Vec<Vector3<f32>> = saddles
        .iter()
        .map(|&(i, j)| {
            let p = grid.corner(i, j);
            at([p[0] + grid.cell / 2.0, p[1] + grid.cell / 2.0])
        })
        .collect();
    let centres = reproject::fields(&tape, &centres, job.threads);
    for (&cell, centre) in saddles.iter().zip(centres) {
        let joined = centre.is_some_and(|g| g.v < 0.0);
        steps.extend(saddle(grid, &inside, cell, joined));
    }
    if job.cancel.is_cancelled() {
        return Ok(None);
    }

    let mut index = HashMap::new();
    for &(from, _) in &steps {
        index.insert(from, index.len());
    }
    let mut edges = vec![0; index.len()];
    for (&edge, &i) in &index {
        edges[i] = edge;
    }
    let crossings = crossings(&tape, grid, z, &edges, &pixels, job);
    let steps: Vec<(usize, usize)> = steps
        .iter()
        .filter_map(|(from, to)| Some((index[from], *index.get(to)?)))
        .collect();
    let corners = corners(&tape, grid, z, &crossings, &steps, job);

    // Each crossing starts one step and ends another, so following them
    // from any step comes back to it.
    let mut next = vec![None; crossings.len()];
    for (s, &(from, _)) in steps.iter().enumerate() {
        next[from] = Some(s);
    }
    let mut done = vec![false; steps.len()];
    let mut contours = vec![];
    for start in 0..steps.len() {
        let mut contour = vec![];
        let mut at = Some(start);
        while let Some(s) = at.filter(|&s| !done[s]) {
            done[s] = true;
            contour.push(crossings[steps[s].0].0);
            contour.extend(corners[s]);
            at = next[steps[s].1];
        }
        contour.dedup_by(|a, b| distance(*a, *b) < grid.cell * 1e-6);
        if contour.len() >= 3 {
            contours.push(contour);
        }
    }
    Ok(Some(contours))
}

/// The shape's value at every corner of the grid, or only its side where
/// fidget finds a whole region inside or outside; `None` once cancelled.
fn sample(
    shape: &JitShape,
    grid: &Grid,
    z: f64,
    job: &Job,
) -> Result<Option<Vec<RawDistancePixel>>, String> {
    let size = ImageSize::new(grid.width as u32, grid.height as u32);
    // fidget evaluates pixel (i, j) at the screen point (i, j), which this
    // takes to the grid's corner (i, j).
    #[rustfmt::skip]
    let screen_to_model = Matrix3::new(
        grid.cell, 0.0,       grid.lower[0],
        0.0,       grid.cell, grid.lower[1],
        0.0,       0.0,       1.0,
    );
    let world_to_screen = size
        .screen_to_world()
        .cast::<f64>()
        .try_inverse()
        .ok_or("the grid has no area")?;
    let config = pixel::RenderConfig {
        image_size: size,
        world_to_model: (screen_to_model * world_to_screen).cast(),
        pixel_perfect: false,
        z: z as f32,
    };
    let eval = pixel::EvalConfig {
        tile_sizes: None,
        threads: Some(job.threads),
        cancel: job.cancel.clone(),
    };
    let image = pixel::render(scene::bound(shape.clone())?, &config, &eval);
    Ok(image.map(|image| image.take().0))
}

// --- Marching squares ---

/// The edges of cell (i, j), counterclockwise from its bottom, each as
/// (its id, the corner it starts from), and its corners in the same order.
fn cell_edges(grid: &Grid, (i, j): (usize, usize)) -> ([usize; 4], [(usize, usize); 4]) {
    (
        [
            horizontal(grid, i, j),
            vertical(grid, i + 1, j),
            horizontal(grid, i, j + 1),
            vertical(grid, i, j),
        ],
        [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)],
    )
}

/// A step of an outline across a cell: (the edge it enters the cell by,
/// the edge it leaves by), with the inside on its left
type Step = (usize, usize);

/// A cell, as (i, j)
type Cell = (usize, usize);

/// The steps the outlines take across the cells, and the cells whose
/// diagonal corners are alike, where the outlines pass one of two ways.
///
/// Going counterclockwise round a cell, an outline enters it on an edge
/// that runs from inside to outside, and leaves on one that runs back in.
fn march(grid: &Grid, inside: &[bool]) -> (Vec<Step>, Vec<Cell>) {
    let mut steps = vec![];
    let mut saddles = vec![];
    for j in 0..grid.height - 1 {
        for i in 0..grid.width - 1 {
            let (edges, corners) = cell_edges(grid, (i, j));
            let ins = corners.map(|(i, j)| inside[j * grid.width + i]);
            let crossed = (0..4).filter(|&k| ins[k] != ins[(k + 1) % 4]).count();
            match crossed {
                2 => {
                    let enters = (0..4).find(|&k| ins[k] && !ins[(k + 1) % 4]);
                    let leaves = (0..4).find(|&k| !ins[k] && ins[(k + 1) % 4]);
                    if let (Some(enters), Some(leaves)) = (enters, leaves) {
                        steps.push((edges[enters], edges[leaves]));
                    }
                }
                4 => saddles.push((i, j)),
                _ => {}
            }
        }
    }
    (steps, saddles)
}

/// The two steps across a cell whose diagonal corners are alike: the
/// outlines enter by both edges that run from inside to outside, and leave
/// by the next edge counterclockwise when the cell's centre is inside,
/// joining its two inside corners, or the one before it otherwise.
fn saddle(grid: &Grid, inside: &[bool], cell: (usize, usize), joined: bool) -> [(usize, usize); 2] {
    let (edges, corners) = cell_edges(grid, cell);
    let (i, j) = corners[0];
    let first = if inside[j * grid.width + i] { 0 } else { 1 };
    let turn = if joined { 1 } else { 3 };
    [first, first + 2].map(|k| (edges[k], edges[(k + turn) % 4]))
}

// --- Points ---

/// Where the surface crosses each edge, and its unit normal there where
/// the field has a gradient.
///
/// Each starts where a line through its corners' values crosses zero, or
/// halfway where fidget gave only their sides, and takes Newton's steps
/// along the edge; a step that would leave the part of the edge where the
/// sign changes halves that part instead.
// TODO: evaluate each region's crossings on the shape simplified for it,
// as fidget's sampling does; a sheet with 147 slots spends most of its
// 1.7 s here, on all of its slots for every point.
fn crossings(
    tape: &Tape,
    grid: &Grid,
    z: f64,
    edges: &[usize],
    pixels: &[RawDistancePixel],
    job: &Job,
) -> Vec<(Point, Option<Point>)> {
    let value = |(i, j): (usize, usize)| match pixels[j * grid.width + i].unpack() {
        DistancePixel::Value(v) if v.is_finite() => Some(f64::from(v)),
        _ => None,
    };
    let ends: Vec<[Point; 2]> = edges
        .iter()
        .map(|&e| grid.ends(e).map(|(i, j)| grid.corner(i, j)))
        .collect();
    let starts_inside: Vec<bool> = edges
        .iter()
        .map(|&e| {
            let (i, j) = grid.ends(e)[0];
            pixels[j * grid.width + i].inside()
        })
        .collect();
    let mut t: Vec<f64> = edges
        .iter()
        .map(|&e| match grid.ends(e).map(value) {
            [Some(a), Some(b)] if a != b => (a / (a - b)).clamp(0.0, 1.0),
            _ => 0.5,
        })
        .collect();
    // The part of each edge where the sign changes, as [start, end] in t
    let mut bracket = vec![[0.0, 1.0]; edges.len()];
    let mut normals = vec![None; edges.len()];
    let along = |k: usize, t: f64| {
        let [a, b] = ends[k];
        [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
    };

    let mut moving: Vec<usize> = (0..edges.len()).collect();
    for _ in 0..ROOT_STEPS {
        let points: Vec<Vector3<f32>> = moving
            .iter()
            .map(|&k| {
                let p = along(k, t[k]);
                Vector3::new(p[0] as f32, p[1] as f32, z as f32)
            })
            .collect();
        let fields = reproject::fields(tape, &points, job.threads);
        let mut still = vec![];
        for (&k, g) in moving.iter().zip(fields) {
            let Some(g) = g else { continue };
            let (v, gx, gy) = (f64::from(g.v), f64::from(g.dx), f64::from(g.dy));
            let length = gx.hypot(gy);
            if length > 0.0 {
                normals[k] = Some([gx / length, gy / length]);
            }
            if v == 0.0 {
                continue;
            } else if (v < 0.0) == starts_inside[k] {
                bracket[k][0] = t[k];
            } else {
                bracket[k][1] = t[k];
            }
            let [a, b] = ends[k];
            let slope = gx * (b[0] - a[0]) + gy * (b[1] - a[1]);
            let next = t[k] - v / slope;
            let next = if (bracket[k][0]..=bracket[k][1]).contains(&next) {
                next
            } else {
                (bracket[k][0] + bracket[k][1]) / 2.0
            };
            if (next - t[k]).abs() > ARRIVED {
                still.push(k);
            }
            t[k] = next;
        }
        moving = still;
    }
    (0..edges.len())
        .map(|k| (along(k, t[k]), normals[k]))
        .collect()
}

/// The sharp corner within each step, where it has one: where the
/// tangents at its two ends meet, when their normals turn sharply and the
/// field finds that point nearer the surface than the middle of the step.
fn corners(
    tape: &Tape,
    grid: &Grid,
    z: f64,
    crossings: &[(Point, Option<Point>)],
    steps: &[(usize, usize)],
    job: &Job,
) -> Vec<Option<Point>> {
    let candidates: Vec<(usize, Point, Point)> = steps
        .iter()
        .enumerate()
        .filter_map(|(s, &(from, to))| {
            let ((a, na), (b, nb)) = (crossings[from], crossings[to]);
            let (na, nb) = (na?, nb?);
            if dot(na, nb) > TURN {
                return None;
            }
            let corner = tangents_meet(a, na, b, nb)?;
            let middle = [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0];
            (distance(corner, middle) < 2.0 * grid.cell).then_some((s, corner, middle))
        })
        .collect();
    let points: Vec<Vector3<f32>> = candidates
        .iter()
        .flat_map(|(_, corner, middle)| [corner, middle])
        .map(|p| Vector3::new(p[0] as f32, p[1] as f32, z as f32))
        .collect();
    let fields = reproject::fields(tape, &points, job.threads);
    let off =
        |g: &Option<Grad>| g.map(|g| f64::from(g.v.abs()) / f64::from(g.dx).hypot(f64::from(g.dy)));
    let mut corners = vec![None; steps.len()];
    for (&(s, corner, _), pair) in candidates.iter().zip(fields.chunks_exact(2)) {
        if let (Some(at_corner), Some(at_middle)) = (off(&pair[0]), off(&pair[1]))
            && at_corner < at_middle / 2.0
        {
            corners[s] = Some(corner);
        }
    }
    corners
}

/// Where the line through `a` normal to `na` meets the one through `b`
/// normal to `nb`, unless they are near parallel.
fn tangents_meet(a: Point, na: Point, b: Point, nb: Point) -> Option<Point> {
    let det = na[0] * nb[1] - na[1] * nb[0];
    if det.abs() < 1e-6 {
        return None;
    }
    let (ca, cb) = (dot(na, a), dot(nb, b));
    Some([
        (ca * nb[1] - cb * na[1]) / det,
        (na[0] * cb - nb[0] * ca) / det,
    ])
}

fn dot(a: Point, b: Point) -> f64 {
    a[0] * b[0] + a[1] * b[1]
}

pub fn distance(a: Point, b: Point) -> f64 {
    (a[0] - b[0]).hypot(a[1] - b[1])
}

// --- Nesting ---

/// Twice the area `contour` encloses: positive for an outline, which runs
/// counterclockwise, negative for a hole.
pub fn area(contour: &Contour) -> f64 {
    let next = contour.iter().cycle().skip(1);
    contour
        .iter()
        .zip(next)
        .map(|(p, q)| p[0] * q[1] - q[0] * p[1])
        .sum()
}

/// Whether `p` is inside `contour`, by the crossings of a ray along +x.
fn encloses(contour: &Contour, p: Point) -> bool {
    let next = contour.iter().cycle().skip(1);
    let mut inside = false;
    for (a, b) in contour.iter().zip(next) {
        if (a[1] > p[1]) != (b[1] > p[1]) {
            let x = a[0] + (p[1] - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
            if x > p[0] {
                inside = !inside;
            }
        }
    }
    inside
}

/// The contours grouped into shapes, each the holes in an outline and then
/// the outline, and the shapes ordered from the most deeply nested out, so
/// that a laser following them cuts a part's holes, and the parts inside
/// those, before the part comes loose.
pub fn nest(contours: Vec<Contour>) -> Vec<Vec<Contour>> {
    let areas: Vec<f64> = contours.iter().map(area).collect();
    let boxes: Vec<[Point; 2]> = contours.iter().map(bounding_box).collect();
    let within = |inner: usize, outer: usize| {
        let ([il, iu], [ol, ou]) = (boxes[inner], boxes[outer]);
        inner != outer
            && (0..2).all(|i| ol[i] <= il[i] && iu[i] <= ou[i])
            && encloses(&contours[outer], contours[inner][0])
    };
    // The contours around each, the smallest of them its parent
    let around: Vec<Vec<usize>> = (0..contours.len())
        .map(|c| (0..contours.len()).filter(|&o| within(c, o)).collect())
        .collect();
    let mut shapes: Vec<(usize, Vec<usize>)> = vec![];
    let mut shape_of = HashMap::new();
    for c in (0..contours.len()).filter(|&c| areas[c] > 0.0) {
        shape_of.insert(c, shapes.len());
        shapes.push((around[c].len(), vec![]));
    }
    for c in (0..contours.len()).filter(|&c| areas[c] <= 0.0) {
        let parent = around[c]
            .iter()
            .min_by(|&&a, &&b| areas[a].abs().total_cmp(&areas[b].abs()));
        if let Some(shape) = parent.and_then(|p| shape_of.get(p)) {
            shapes[*shape].1.push(c);
        }
    }
    for (&c, &shape) in &shape_of {
        shapes[shape].1.push(c);
    }
    shapes.sort_by_key(|(depth, _)| std::cmp::Reverse(*depth));
    let mut contours: Vec<Option<Contour>> = contours.into_iter().map(Some).collect();
    shapes
        .into_iter()
        .map(|(_, members)| {
            members
                .into_iter()
                .filter_map(|c| contours[c].take())
                .collect()
        })
        .collect()
}

fn bounding_box(contour: &Contour) -> [Point; 2] {
    let mut lower = [f64::INFINITY; 2];
    let mut upper = [f64::NEG_INFINITY; 2];
    for p in contour {
        for i in 0..2 {
            lower[i] = lower[i].min(p[i]);
            upper[i] = upper[i].max(p[i]);
        }
    }
    [lower, upper]
}

#[cfg(test)]
mod test {
    use fidget::context::Tree;
    use fidget::render::{CancelToken, ThreadPool};

    use super::*;

    fn trace_tree(tree: &Tree, lower: Point, upper: Point, cell: f64) -> Vec<Contour> {
        let shape = scene::jit(tree).expect("it compiles");
        let grid = Grid::new(lower, upper, cell).expect("a grid");
        let cancel = CancelToken::new();
        let job = Job {
            threads: &ThreadPool::Global,
            cancel: &cancel,
            progress: &|_| {},
        };
        trace(&shape, &grid, 0.0, &job)
            .expect("it traces")
            .expect("not cancelled")
    }

    fn circle(centre: Point, r: f64) -> Tree {
        let (x, y, _) = Tree::axes();
        let (dx, dy) = (x - centre[0] as f32, y - centre[1] as f32);
        (dx.square() + dy.square()).sqrt() - r as f32
    }

    fn square(half: f64) -> Tree {
        let (x, y, _) = Tree::axes();
        x.abs().max(y.abs()) - half as f32
    }

    /// Points that far from the surface are there, as far as 32-bit
    /// floats tell.
    const ON: f64 = 1e-5;

    /// A circle is one outline, counterclockwise, every point on it; even
    /// one through corners of the grid.
    #[test]
    fn a_circle_is_one_outline_on_it() {
        for (centre, r) in [([0.3, -0.2], 3.0), ([0.0, 0.0], 3.0)] {
            let contours = trace_tree(&circle(centre, r), [-4.0, -4.0], [4.0, 4.0], 0.1);
            assert_eq!(contours.len(), 1);
            assert!(area(&contours[0]) > 0.0);
            for &p in &contours[0] {
                let off = distance(p, centre) - r;
                assert!(off.abs() < ON, "{p:?} is {off} off");
            }
        }
    }

    /// A square with a round hole is an outline counterclockwise, its
    /// corners sharp, and a hole clockwise.
    #[test]
    fn a_square_with_a_hole_keeps_its_corners() {
        let shape = square(5.0).max(-circle([1.0, 0.5], 2.0));
        let contours = trace_tree(&shape, [-7.0, -7.0], [7.0, 7.0], 0.1);
        assert_eq!(contours.len(), 2);
        let (outline, hole) = if area(&contours[0]) > 0.0 {
            (&contours[0], &contours[1])
        } else {
            (&contours[1], &contours[0])
        };
        assert!(area(hole) < 0.0);
        for &p in outline {
            let off = p[0].abs().max(p[1].abs()) - 5.0;
            assert!(off.abs() < ON, "{p:?} is {off} off");
        }
        for corner in [[-5.0, -5.0], [5.0, -5.0], [5.0, 5.0], [-5.0, 5.0]] {
            let nearest = outline.iter().map(|&p| distance(p, corner));
            assert!(nearest.fold(f64::INFINITY, f64::min) < ON, "{corner:?}");
        }
        for &p in hole {
            let off = distance(p, [1.0, 0.5]) - 2.0;
            assert!(off.abs() < ON, "{p:?} is {off} off");
        }
    }

    /// An island in a hole comes first, alone, then the hole and the
    /// outline around it.
    #[test]
    fn islands_in_holes_come_first() {
        let ring = square(5.0).max(-square(3.0));
        let shape = ring.min(circle([0.0, 0.0], 1.0));
        let shapes = nest(trace_tree(&shape, [-6.0, -6.0], [6.0, 6.0], 0.1));
        assert_eq!(shapes.len(), 2);
        assert_eq!(shapes[0].len(), 1);
        assert!(distance(shapes[0][0][0], [0.0, 0.0]) < 1.0 + ON);
        let areas: Vec<f64> = shapes[1].iter().map(area).collect();
        // Twice the areas: the hole 6 across, then the outline 10 across
        assert!((areas[0] + 72.0).abs() < 1e-3, "{areas:?}");
        assert!((areas[1] - 200.0).abs() < 1e-3, "{areas:?}");
    }
}
