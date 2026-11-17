// SPDX-License-Identifier: MPL-2.0

//! Moves the vertices fidget's mesher leaves off the surface back onto it.
//!
//! When fidget's octree merges eight leaf cells into one, it solves the
//! merged cell's QEF from Hermite data that leaves some of the children's
//! intersections out, and keeps the vertex wherever in the merged cell it
//! lands; on a small curved feature, such as a round end on a thin plate,
//! that can be ten cells off the surface.  Such a vertex is taken along the
//! field's gradient onto the surface by Newton's method, or part of the
//! way, as far as that brings its triangles nearer the surface without
//! turning one over to face against the field.

use fidget::jit::{JitBulkFn, JitShape};
use fidget::mesh::Mesh;
use fidget::render::ThreadPool;
use fidget::shape::ShapeTape;
use fidget::types::Grad;
use nalgebra::Vector3;
use rayon::prelude::*;

type Tape = ShapeTape<JitBulkFn<Grad>>;

/// Vertices further from the surface than this, in leaf cells, by the
/// field's own estimate, are moved.
const MAX_OFF: f32 = 1.0;

/// A point this close to the surface, in leaf cells, has arrived.
const ARRIVED: f32 = 1.0 / 64.0;

/// Newton steps a point is given to arrive
const STEPS: usize = 8;

/// How far a vertex may move, in its estimated distance from the surface:
/// on a field far from a distance, Newton's method can run along the
/// surface to a point that is no nearer.
const REACH: f32 = 2.0;

/// The shares of its way a vertex tries, in turn, until its triangles
/// allow one
const SHARES: [f32; 3] = [1.0, 0.5, 0.25];

/// A move must bring the furthest of a vertex's triangles' points from the
/// surface to this share of its distance or nearer: a vertex on a sharp
/// edge of a field far from a distance moves onto one side of the edge,
/// and its triangles then cut across it about as far.
const GAIN: f32 = 0.75;

/// Rounds of moves: a vertex held back by its triangles gets closer each
/// round.
const ROUNDS: usize = 4;

/// Moves the vertices of `mesh` further than a cell, `cell` across, from
/// the surface of `shape` onto it.
pub fn reproject(mesh: &mut Mesh, shape: &JitShape, cell: f64, threads: &ThreadPool) {
    let tape = shape.grad_slice_tape(Default::default());
    for _ in 0..ROUNDS {
        if round(mesh, &tape, cell as f32, threads) == 0 {
            break;
        }
    }
}

/// One round of moves; returns how many vertices moved.
fn round(mesh: &mut Mesh, tape: &Tape, cell: f32, threads: &ThreadPool) -> usize {
    // The last of a triangle's vertices is the intersection it was made
    // around, on an octree edge and so on the surface; the others are cell
    // vertices, which the QEF places.
    let mut placed = vec![false; mesh.vertices.len()];
    for t in &mesh.triangles {
        placed[t.x] = true;
        placed[t.y] = true;
    }
    let placed: Vec<usize> = (0..placed.len()).filter(|&v| placed[v]).collect();
    let at: Vec<Vector3<f32>> = placed.iter().map(|&v| mesh.vertices[v]).collect();
    let (off, reach): (Vec<usize>, Vec<f32>) = placed
        .iter()
        .zip(fields(tape, &at, threads))
        .filter_map(|(&v, g)| Some((v, distance(&g?))))
        .filter(|&(_, d)| d > MAX_OFF * cell)
        .map(|(v, d)| (v, d * REACH))
        .unzip();
    if off.is_empty() {
        return 0;
    }

    let mut around: Vec<Vec<usize>> = vec![Vec::new(); off.len()];
    let mut slot = vec![usize::MAX; mesh.vertices.len()];
    for (i, &v) in off.iter().enumerate() {
        slot[v] = i;
    }
    for (t, triangle) in mesh.triangles.iter().enumerate() {
        for &v in triangle.iter() {
            if slot[v] != usize::MAX {
                around[slot[v]].push(t);
            }
        }
    }
    let mut points: Vec<Vector3<f32>> = off.iter().map(|&v| mesh.vertices[v]).collect();

    // Newton's method on all of them at once, each stopping once arrived.
    let mut arrived = vec![false; off.len()];
    for step in 0..=STEPS {
        let moving: Vec<usize> = (0..off.len()).filter(|&i| !arrived[i]).collect();
        let at: Vec<Vector3<f32>> = moving.iter().map(|&i| points[i]).collect();
        for (&i, g) in moving.iter().zip(fields(tape, &at, threads)) {
            let Some(g) = g else { continue };
            if distance(&g) <= ARRIVED * cell {
                arrived[i] = true;
            } else if step < STEPS {
                let gradient = Vector3::new(g.dx, g.dy, g.dz);
                points[i] -= gradient * (g.v / gradient.norm_squared());
            }
        }
    }

    // One vertex at a time, so that each sees where its neighbours went.  A
    // move must bring the vertex's triangles nearer the surface, and may
    // turn one over only to face along the field.
    let mut moved = 0;
    for (i, &v) in off.iter().enumerate() {
        let start = mesh.vertices[v];
        if !arrived[i] || (points[i] - start).norm() > reach[i] {
            continue;
        }
        let before = Fan::measure(mesh, v, &around[i], tape, threads);
        let to = SHARES.into_iter().find(|&share| {
            mesh.vertices[v] = start + (points[i] - start) * share;
            let after = Fan::measure(mesh, v, &around[i], tape, threads);
            after.off <= before.off * GAIN
                && after
                    .triangles
                    .iter()
                    .zip(&before.triangles)
                    .all(|(&(normal, along), &(was, _))| along || normal.dot(&was) > 0.0)
        });
        match to {
            Some(_) => moved += 1,
            None => mesh.vertices[v] = start,
        }
    }
    moved
}

/// The field and its gradient at each point, `None` where they are not
/// finite or cannot be evaluated
pub fn fields(tape: &Tape, points: &[Vector3<f32>], threads: &ThreadPool) -> Vec<Option<Grad>> {
    threads.run(|| {
        points
            .par_chunks(4096)
            .flat_map_iter(|chunk| {
                let [x, y, z] = [0, 1, 2].map(|axis| {
                    chunk
                        .iter()
                        .map(|p| {
                            let mut d = [0.0; 3];
                            d[axis] = 1.0;
                            Grad::new(p[axis], d[0], d[1], d[2])
                        })
                        .collect::<Vec<_>>()
                });
                let mut eval = JitShape::new_grad_slice_eval();
                match eval.eval(tape, &x, &y, &z) {
                    Ok(out) => out
                        .iter()
                        .map(|g| {
                            let finite = [g.v, g.dx, g.dy, g.dz].iter().all(|c| c.is_finite());
                            (finite && (g.dx, g.dy, g.dz) != (0.0, 0.0, 0.0)).then_some(*g)
                        })
                        .collect(),
                    Err(_) => vec![None; chunk.len()],
                }
            })
            .collect()
    })
}

/// The distance to the surface, to first order
fn distance(g: &Grad) -> f32 {
    g.v.abs() / Vector3::new(g.dx, g.dy, g.dz).norm()
}

/// The triangles around a vertex, as a move changes them
struct Fan {
    /// Per triangle, its normal and whether that faces along the field's
    /// gradient at its centre, or the gradient is unknown there
    triangles: Vec<(Vector3<f32>, bool)>,
    /// How far from the surface the points of its triangles that the
    /// vertex moves are at most, to first order
    off: f32,
}

impl Fan {
    fn measure(
        mesh: &Mesh,
        v: usize,
        triangles: &[usize],
        tape: &Tape,
        threads: &ThreadPool,
    ) -> Fan {
        let at = mesh.vertices[v];
        let corners: Vec<[Vector3<f32>; 3]> = triangles
            .iter()
            .map(|&t| {
                let t = mesh.triangles[t];
                [t.x, t.y, t.z].map(|u| mesh.vertices[u])
            })
            .collect();
        // Per triangle the points the vertex moves: its centre, a point
        // towards each corner, and each corner's midpoint with the vertex,
        // its own corner giving the vertex itself.
        let points: Vec<Vector3<f32>> = corners
            .iter()
            .flat_map(|c| {
                let centre = (c[0] + c[1] + c[2]) / 3.0;
                let inner = c.map(|corner| (centre + corner) / 2.0);
                let edges = c.map(|corner| (corner + at) / 2.0);
                std::iter::once(centre).chain(inner).chain(edges)
            })
            .collect();
        let fields = fields(tape, &points, threads);
        let off = fields.iter().flatten().map(distance).fold(0.0, f32::max);
        let triangles = corners
            .iter()
            .zip(fields.chunks_exact(7))
            .map(|(c, g)| {
                let normal = (c[1] - c[0]).cross(&(c[2] - c[0]));
                let along = g[0].is_none_or(|g| normal.dot(&Vector3::new(g.dx, g.dy, g.dz)) >= 0.0);
                (normal, along)
            })
            .collect();
        Fan { triangles, off }
    }
}
