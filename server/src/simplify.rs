// SPDX-License-Identifier: MPL-2.0

//! Mesh simplification: half-edge collapses, the cheapest by quadric error
//! (Garland and Heckbert) first, each made only while the simplified
//! surface stays within a tolerance of the mesher's.
//!
//! A collapse moves no vertex, so the vertices left are the mesher's, on
//! the surface; the removed ones are kept as points, each attached to the
//! triangle nearest to it, and a collapse is refused once a point near it
//! would be further than the tolerance from every triangle it leaves, or
//! a triangle it changes would be further from the mesher's triangles.  A
//! collapse is refused as well if it would change the topology, turn a
//! triangle over or leave a sliver, so a closed manifold stays one.
//!
//! Collapses are made in passes over the vertices, each pass allowing a
//! higher quadric error, which orders them nearly as a queue would at a
//! fraction of the cost.  A large mesh is cut into blocks simplified side
//! by side, their borders fixed, twice, the second time with the blocks
//! shifted to take in the first time's borders, and then simplified
//! whole, where only the corners of the blocks have anything left to try.

use fidget::mesh::Mesh;
use fidget::render::{CancelToken, ThreadPool};
use rayon::prelude::*;

type Vec3 = [f64; 3];

/// No point, or no triangle
const NONE: u32 = u32::MAX;

/// The least cosine of the angle a triangle may turn by in one collapse
const MIN_TURN_COS: f64 = 0.5;

/// Below this quality (1 for an equilateral triangle, 0 for a degenerate
/// one) a collapse may only improve a triangle.
const MIN_QUALITY: f64 = 0.02;

/// The quadric errors the passes allow, as mean squared distances in
/// squared tolerances; the last is repeated while it pays.
const PASSES: [f64; 11] = [
    0.0,
    1.0 / 4096.0,
    1.0 / 1024.0,
    1.0 / 256.0,
    1.0 / 64.0,
    1.0 / 16.0,
    1.0 / 4.0,
    1.0,
    4.0,
    16.0,
    f64::INFINITY,
];

/// The last pass is repeated until it removes fewer than this share of the
/// triangles left.
const MIN_PASS_GAIN: f64 = 0.01;

/// About how many blocks a mesh large enough is split into, several for
/// each thread
const BLOCKS: f64 = 64.0;

/// Meshes with fewer triangles are simplified whole.
const MIN_SPLIT: usize = 100_000;

/// `mesh` with as few triangles as keep it within `tolerance` of itself,
/// or `None` once cancelled.
pub fn simplify(
    mesh: &Mesh,
    tolerance: f64,
    threads: &ThreadPool,
    cancel: &CancelToken,
) -> Option<Mesh> {
    let positions: Vec<Vec3> = mesh
        .vertices
        .iter()
        .map(|v| [v.x, v.y, v.z].map(f64::from))
        .collect();
    let triangles: Vec<[u32; 3]> = mesh
        .triangles
        .iter()
        .map(|t| [t.x, t.y, t.z].map(|i| i as u32))
        .collect();
    let surface = threads.run(|| Surface::new(&positions, &triangles, tolerance));
    let settings = Settings {
        tolerance_squared: tolerance * tolerance,
        surface: &surface,
        cancel,
    };

    let mut pieces = Pieces {
        settled: vec![false; positions.len()],
        triangles: triangles.clone(),
        attached: Vec::new(),
    };
    // The second round's blocks are shifted by half a block, so that the
    // first round's borders are inside them.
    if pieces.triangles.len() >= MIN_SPLIT {
        for shift in [0.0, 0.5] {
            pieces = round(&positions, pieces, shift, &settings, threads)?;
        }
    }
    let mut whole = Simplifier::new(&settings, positions.clone(), pieces.triangles, None);
    for (t, p) in pieces.attached {
        whole.attach(t, p);
    }
    for (v, settled) in pieces.settled.into_iter().enumerate() {
        if settled {
            whole.settle(v);
        }
    }
    whole.run().then(|| whole.mesh())
}

/// What every simplification of one mesh shares
struct Settings<'a> {
    tolerance_squared: f64,
    surface: &'a Surface<'a>,
    cancel: &'a CancelToken,
}

// --- Blocks ---

/// A mesh between rounds, in the whole mesh's vertices
struct Pieces {
    triangles: Vec<[u32; 3]>,
    /// Points and the triangles they are on
    attached: Vec<(u32, u32)>,
    /// Per vertex, whether it has nothing left to try
    settled: Vec<bool>,
}

/// The triangles within one block, on vertices of their own
struct Part {
    /// Per vertex, its index in the whole mesh
    vertices: Vec<u32>,
    triangles: Vec<[u32; 3]>,
    /// Points and the triangles they are on
    attached: Vec<(u32, u32)>,
    /// Per vertex, whether it is on a triangle across the block's border
    border: Vec<bool>,
    /// Per vertex, whether it has nothing left to try
    settled: Vec<bool>,
}

/// `pieces` simplified block by block, the blocks shifted by `shift`
/// blocks, or `None` once cancelled
fn round(
    positions: &[Vec3],
    pieces: Pieces,
    shift: f64,
    settings: &Settings,
    threads: &ThreadPool,
) -> Option<Pieces> {
    let finite = positions.iter().filter(|p| p.iter().all(|c| c.is_finite()));
    let (lower, upper) = finite.fold(([f64::INFINITY; 3], [f64::NEG_INFINITY; 3]), |(l, u), p| {
        (
            [0, 1, 2].map(|i| l[i].min(p[i])),
            [0, 1, 2].map(|i| u[i].max(p[i])),
        )
    });
    let counts = blocks([0, 1, 2].map(|i| upper[i] - lower[i]));
    // An axis with one block is not shifted, so that it stays whole.
    let cells = counts.map(|n| if n > 1 && shift > 0.0 { n + 1 } else { n });
    // Vertices nowhere, in no block, keep their triangles on the border.
    let block = |v: u32| {
        let p = positions[v as usize];
        if !p.iter().all(|c| c.is_finite()) {
            return usize::MAX;
        }
        (0..3).fold(0, |index, i| {
            let along = (p[i] - lower[i]) / (upper[i] - lower[i]).max(f64::MIN_POSITIVE);
            let offset = if cells[i] > counts[i] { shift } else { 0.0 };
            let cell = ((along * counts[i] as f64 + offset) as usize).min(cells[i] - 1);
            index * cells[i] + cell
        })
    };

    // Each triangle goes to its block's part or to the border, and with
    // it its points.
    let mut parts: Vec<Part> = (0..cells.iter().product())
        .map(|_| Part {
            vertices: Vec::new(),
            triangles: Vec::new(),
            attached: Vec::new(),
            border: Vec::new(),
            settled: Vec::new(),
        })
        .collect();
    let mut border = Pieces {
        triangles: Vec::new(),
        attached: Vec::new(),
        settled: pieces.settled,
    };
    let mut local = vec![NONE; positions.len()];
    let mut place = |part: &mut Part, v: u32| {
        if local[v as usize] == NONE {
            local[v as usize] = part.vertices.len() as u32;
            part.vertices.push(v);
        }
        local[v as usize]
    };
    // Per triangle, its part and its index there, or NONE and its index
    // on the border
    let mut at = Vec::with_capacity(pieces.triangles.len());
    for &triangle in &pieces.triangles {
        let b = block(triangle[0]);
        if b == usize::MAX || triangle.iter().any(|&v| block(v) != b) {
            at.push((NONE, border.triangles.len() as u32));
            border.triangles.push(triangle);
        } else {
            let part = &mut parts[b];
            at.push((b as u32, part.triangles.len() as u32));
            let triangle = triangle.map(|v| place(part, v));
            part.triangles.push(triangle);
        }
    }
    for (t, p) in pieces.attached {
        match at[t as usize] {
            (NONE, t) => border.attached.push((t, p)),
            (b, t) => {
                let part = &mut parts[b as usize];
                let p = place(part, p);
                part.attached.push((t, p));
            }
        }
    }
    for part in &mut parts {
        part.border = vec![false; part.vertices.len()];
        part.settled = part
            .vertices
            .iter()
            .map(|&v| border.settled[v as usize])
            .collect();
    }
    for triangle in &border.triangles {
        for &v in triangle {
            let b = block(v);
            if b != usize::MAX && local[v as usize] != NONE {
                parts[b].border[local[v as usize] as usize] = true;
            }
        }
    }
    parts.retain(|part| !part.triangles.is_empty());

    let parts: Vec<Part> = threads.run(|| {
        parts
            .into_par_iter()
            .map(|part| part.simplify(positions, settings))
            .collect::<Option<_>>()
    })?;

    // Together again
    let mut pieces = border;
    for part in parts {
        let offset = pieces.triangles.len() as u32;
        let whole = |v: u32| part.vertices[v as usize];
        pieces
            .triangles
            .extend(part.triangles.iter().map(|t| t.map(whole)));
        pieces
            .attached
            .extend(part.attached.iter().map(|&(t, p)| (t + offset, whole(p))));
        for (v, &settled) in part.settled.iter().enumerate() {
            pieces.settled[whole(v as u32) as usize] = settled;
        }
    }
    Some(pieces)
}

/// How many blocks go along each axis of a box `extent` large: about
/// [`BLOCKS`] cubes, and a single one across an axis thinner than that
fn blocks(extent: Vec3) -> [usize; 3] {
    let mut thick = extent.map(|e| e > 0.0);
    let mut side = 0.0;
    for _ in 0..3 {
        let axes = thick.iter().filter(|&&t| t).count();
        let volume: f64 = (0..3).filter(|&i| thick[i]).map(|i| extent[i]).product();
        side = (volume / BLOCKS).powf(1.0 / axes.max(1) as f64);
        thick = [0, 1, 2].map(|i| thick[i] && extent[i] >= side);
    }
    if side.is_nan() || side <= 0.0 {
        return [1; 3];
    }
    extent.map(|e| ((e / side).round() as usize).max(1))
}

impl Part {
    /// The part simplified with its border fixed, or `None` once cancelled
    fn simplify(self, positions: &[Vec3], settings: &Settings) -> Option<Part> {
        let local = self
            .vertices
            .iter()
            .map(|&v| positions[v as usize])
            .collect();
        let mut simplifier = Simplifier::new(settings, local, self.triangles, Some(self.border));
        for (t, p) in self.attached {
            simplifier.attach(t, p);
        }
        for (v, &settled) in self.settled.iter().enumerate() {
            if settled {
                simplifier.settle(v);
            }
        }
        if !simplifier.run() {
            return None;
        }
        let mut index = vec![NONE; simplifier.triangles.len()];
        let mut triangles = Vec::with_capacity(simplifier.live);
        for (t, &triangle) in simplifier.triangles.iter().enumerate() {
            if simplifier.alive[t] {
                index[t] = triangles.len() as u32;
                triangles.push(triangle);
            }
        }
        let mut attached = Vec::new();
        for (t, &first) in simplifier.first_point.iter().enumerate() {
            let mut p = first;
            while p != NONE {
                attached.push((index[t], p));
                p = simplifier.next_point[p as usize];
            }
        }
        let settled = (0..self.vertices.len())
            .map(|v| simplifier.is_settled(v))
            .collect();
        Some(Part {
            vertices: self.vertices,
            triangles,
            attached,
            border: Vec::new(),
            settled,
        })
    }
}

// --- Quadrics ---

/// The sum of the squared distances to planes, each weighted by its
/// triangle's area: a symmetric 4×4 matrix, its upper triangle by rows,
/// and the areas' sum.
#[derive(Clone, Copy, Default)]
struct Quadric([f64; 11]);

impl Quadric {
    fn triangle(p: [Vec3; 3]) -> Self {
        let cross = normal(p);
        let length = norm(cross);
        if length.is_nan() || length == 0.0 {
            return Quadric::default();
        }
        let [a, b, c] = cross.map(|v| v / length);
        let d = -dot([a, b, c], p[0]);
        let q = [
            a * a,
            a * b,
            a * c,
            a * d,
            b * b,
            b * c,
            b * d,
            c * c,
            c * d,
            d * d,
            1.0,
        ];
        Quadric(q.map(|q| q * length / 2.0))
    }

    fn add(&mut self, other: &Quadric) {
        for (a, b) in self.0.iter_mut().zip(other.0) {
            *a += b;
        }
    }

    fn sum(&self, other: &Quadric) -> Quadric {
        let mut sum = *self;
        sum.add(other);
        sum
    }

    /// The mean squared distance of `p` from the planes
    fn error(&self, [x, y, z]: Vec3) -> f64 {
        let q = &self.0;
        if q[10] == 0.0 {
            return 0.0;
        }
        let sum = q[0] * x * x
            + q[4] * y * y
            + q[7] * z * z
            + 2.0 * (q[1] * x * y + q[2] * x * z + q[5] * y * z)
            + 2.0 * (q[3] * x + q[6] * y + q[8] * z)
            + q[9];
        sum.max(0.0) / q[10]
    }
}

// --- Collapses ---

struct Simplifier<'a> {
    settings: &'a Settings<'a>,
    positions: Vec<Vec3>,
    triangles: Vec<[u32; 3]>,
    /// Per triangle, whether it is still in the mesh
    alive: Vec<bool>,
    /// Per vertex, the triangles round it
    around: Vec<Vec<u32>>,
    quadrics: Vec<Quadric>,
    removed: Vec<bool>,
    /// Vertices no collapse touches: on a border, nowhere, or with
    /// surroundings that are not a disc
    fixed: Vec<bool>,
    /// Per vertex, whether its surroundings changed since its collapses
    /// were last tried
    dirty: Vec<bool>,
    /// Per vertex, the error up to which its collapses were all refused
    refused_up_to: Vec<f64>,
    /// Per triangle, the first point attached to it, a removed vertex
    first_point: Vec<u32>,
    /// Per removed vertex, the next point attached to the same triangle
    next_point: Vec<u32>,
    /// Triangles left
    live: usize,
    /// Per vertex, the last `mark` it was marked with
    marks: Vec<u32>,
    mark: u32,
    scratch: Scratch,
}

/// A collapse's working lists, kept between collapses
#[derive(Default)]
struct Scratch {
    /// A vertex's collapses and their errors
    candidates: Vec<(f64, u32)>,
    gone: Vec<u32>,
    moved: Vec<u32>,
    /// The triangles round `to` after
    after: Vec<u32>,
    /// Their corners
    corners: Vec<[Vec3; 3]>,
    /// Points to place
    attached: Vec<u32>,
    /// The triangles they go on
    nearest: Vec<u32>,
}

impl<'a> Simplifier<'a> {
    fn new(
        settings: &'a Settings<'a>,
        positions: Vec<Vec3>,
        triangles: Vec<[u32; 3]>,
        fixed: Option<Vec<bool>>,
    ) -> Self {
        let mut around = vec![Vec::new(); positions.len()];
        let mut quadrics = vec![Quadric::default(); positions.len()];
        for (t, &triangle) in triangles.iter().enumerate() {
            let quadric = Quadric::triangle(triangle.map(|v| positions[v as usize]));
            for v in triangle {
                around[v as usize].push(t as u32);
                quadrics[v as usize].add(&quadric);
            }
        }
        let mut fixed = fixed.unwrap_or_else(|| vec![false; positions.len()]);
        for (v, fixed) in fixed.iter_mut().enumerate() {
            *fixed = *fixed || !is_disc(v as u32, &around[v], &triangles);
        }
        for triangle in &triangles {
            if triangle
                .iter()
                .any(|&v| !positions[v as usize].iter().all(|c| c.is_finite()))
            {
                for &v in triangle {
                    fixed[v as usize] = true;
                }
            }
        }
        Simplifier {
            settings,
            alive: vec![true; triangles.len()],
            removed: vec![false; positions.len()],
            fixed,
            dirty: vec![true; positions.len()],
            refused_up_to: vec![-1.0; positions.len()],
            first_point: vec![NONE; triangles.len()],
            next_point: vec![NONE; positions.len()],
            live: triangles.len(),
            marks: vec![0; positions.len()],
            mark: 0,
            scratch: Scratch::default(),
            positions,
            triangles,
            around,
            quadrics,
        }
    }

    /// Attaches point `p`, a vertex removed before, to triangle `t`.
    fn attach(&mut self, t: u32, p: u32) {
        self.next_point[p as usize] = self.first_point[t as usize];
        self.first_point[t as usize] = p;
    }

    /// Whether every collapse of `v` was refused, all its surroundings
    /// unchanged since
    fn is_settled(&self, v: usize) -> bool {
        !self.removed[v] && !self.dirty[v] && self.refused_up_to[v] == f64::INFINITY
    }

    fn settle(&mut self, v: usize) {
        self.dirty[v] = false;
        self.refused_up_to[v] = f64::INFINITY;
    }

    /// Makes every pass; false once cancelled.
    fn run(&mut self) -> bool {
        let squared = self.settings.tolerance_squared;
        for threshold in PASSES {
            if !self.pass(threshold * squared) {
                return false;
            }
        }
        loop {
            let before = self.live;
            if !self.pass(f64::INFINITY) {
                return false;
            }
            if ((before - self.live) as f64) < before as f64 * MIN_PASS_GAIN {
                return true;
            }
        }
    }

    /// Tries the collapses of every vertex up to `threshold`, cheapest
    /// first; false once cancelled.
    fn pass(&mut self, threshold: f64) -> bool {
        let mut scratch = std::mem::take(&mut self.scratch);
        for v in 0..self.positions.len() {
            if v % 4096 == 0 && self.settings.cancel.is_cancelled() {
                return false;
            }
            if self.removed[v] || self.fixed[v] {
                continue;
            }
            // Collapses refused while nothing round them changed are not
            // tried again.
            let tried = if self.dirty[v] {
                -1.0
            } else {
                self.refused_up_to[v]
            };
            if tried >= threshold {
                continue;
            }
            scratch.candidates.clear();
            for &t in &self.around[v] {
                let n = self.next(t, v as u32);
                if self.fixed[n as usize] {
                    continue;
                }
                let error = self.quadrics[v]
                    .sum(&self.quadrics[n as usize])
                    .error(self.positions[n as usize]);
                if error > tried && error <= threshold {
                    scratch.candidates.push((error, n));
                }
            }
            scratch
                .candidates
                .sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
            let mut collapsed = None;
            for i in 0..scratch.candidates.len() {
                let to = scratch.candidates[i].1;
                if self.collapse(v as u32, to, &mut scratch) {
                    collapsed = Some(to);
                    break;
                }
            }
            match collapsed {
                Some(to) => {
                    for &t in &self.around[to as usize] {
                        for u in self.triangles[t as usize] {
                            self.dirty[u as usize] = true;
                        }
                    }
                }
                None => {
                    self.dirty[v] = false;
                    self.refused_up_to[v] = threshold;
                }
            }
        }
        self.scratch = scratch;
        true
    }

    /// Collapses `from` into `to` unless that breaks a rule; whether it did.
    fn collapse(&mut self, from: u32, to: u32, scratch: &mut Scratch) -> bool {
        let Scratch {
            gone,
            moved,
            after,
            corners,
            attached,
            nearest,
            ..
        } = scratch;

        // The two triangles on the edge go; the others round `from` keep
        // their place, with `to` for `from`.
        gone.clear();
        moved.clear();
        for &t in &self.around[from as usize] {
            if self.triangles[t as usize].contains(&to) {
                gone.push(t);
            } else {
                moved.push(t);
            }
        }
        if gone.len() != 2 {
            return false;
        }
        let opposite = [gone[0], gone[1]].map(|t| self.third(t, from, to));
        if opposite[0] == opposite[1] {
            return false;
        }

        // Only the vertices opposite the edge may neighbour both ends, or
        // the collapse would pinch the surface; and a tetrahedron stays one.
        self.mark += 1;
        for &t in &self.around[to as usize] {
            for v in self.triangles[t as usize] {
                self.marks[v as usize] = self.mark;
            }
        }
        for &t in moved.iter() {
            let mut on_opposite = 0;
            for v in self.triangles[t as usize] {
                if v == from {
                    continue;
                }
                if opposite.contains(&v) {
                    on_opposite += 1;
                } else if self.marks[v as usize] == self.mark {
                    return false;
                }
            }
            if on_opposite == 2 && self.around[to as usize].len() == 3 {
                return false;
            }
        }

        // No triangle may turn over or sharply, or become a sliver; one
        // with no area yet must face as the triangles round `from` do.
        // Welding two vertices in one place changes no triangle's shape.
        let to_position = self.positions[to as usize];
        let welding = self.positions[from as usize] == to_position;
        let moving = |v: u32| {
            if v == from {
                to_position
            } else {
                self.positions[v as usize]
            }
        };
        if !welding {
            let facing = self.around[from as usize]
                .iter()
                .map(|&t| normal(self.corners(t)))
                .fold([0.0; 3], add);
            for &t in moved.iter() {
                let old = self.corners(t);
                let new = self.triangles[t as usize].map(moving);
                let [mut old_normal, new_normal] = [old, new].map(normal);
                if norm(old_normal) == 0.0 {
                    old_normal = facing;
                }
                let [old_length, new_length] = [old_normal, new_normal].map(norm);
                if new_length.is_nan()
                    || new_length == 0.0
                    || dot(old_normal, new_normal) < MIN_TURN_COS * old_length * new_length
                {
                    return false;
                }
                let new_quality = quality(new);
                if new_quality < MIN_QUALITY && new_quality < quality(old) {
                    return false;
                }
            }
        }

        // Every point the changed triangles carry, and `from` itself, must
        // stay near one of the triangles round `to` after.
        after.clear();
        after.extend(
            self.around[to as usize]
                .iter()
                .filter(|t| !gone.contains(t)),
        );
        after.extend(moved.iter());
        corners.clear();
        corners.extend(
            after
                .iter()
                .map(|&t| self.triangles[t as usize].map(moving)),
        );
        attached.clear();
        attached.push(from);
        for &t in gone.iter().chain(moved.iter()) {
            let mut p = self.first_point[t as usize];
            while p != NONE {
                attached.push(p);
                p = self.next_point[p as usize];
            }
        }
        nearest.clear();
        let squared = self.settings.tolerance_squared;
        for &p in attached.iter() {
            let position = self.positions[p as usize];
            let (i, distance) = corners
                .iter()
                .map(|&c| distance_squared(position, c))
                .enumerate()
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .expect("a vertex has triangles round it");
            if distance.is_nan() || distance > squared {
                return false;
            }
            nearest.push(after[i]);
        }

        // And the changed triangles must stay near the mesher's, at their
        // middles and their edges' middles: a fold thinner than the points
        // are apart has none under it.
        if !welding {
            for &[a, b, c] in &corners[corners.len() - moved.len()..] {
                let middles = [
                    [0, 1, 2].map(|i| (a[i] + b[i] + c[i]) / 3.0),
                    [0, 1, 2].map(|i| (a[i] + b[i]) / 2.0),
                    [0, 1, 2].map(|i| (b[i] + c[i]) / 2.0),
                    [0, 1, 2].map(|i| (c[i] + a[i]) / 2.0),
                ];
                if !middles
                    .iter()
                    .all(|&p| self.settings.surface.near(p, squared))
                {
                    return false;
                }
            }
        }

        // Make it.
        for &t in gone.iter() {
            self.alive[t as usize] = false;
            for v in self.triangles[t as usize] {
                self.around[v as usize].retain(|&u| u != t);
            }
        }
        for &t in gone.iter().chain(moved.iter()) {
            self.first_point[t as usize] = NONE;
        }
        for &t in moved.iter() {
            for v in &mut self.triangles[t as usize] {
                if *v == from {
                    *v = to;
                }
            }
        }
        for (&p, &t) in attached.iter().zip(nearest.iter()) {
            self.attach(t, p);
        }
        // Points on triangles round `to` that did not change stay put.
        self.around[to as usize].extend(moved.iter());
        self.around[from as usize] = Vec::new();
        self.removed[from as usize] = true;
        let quadric = self.quadrics[from as usize];
        self.quadrics[to as usize].add(&quadric);
        self.live -= 2;
        true
    }

    fn corners(&self, t: u32) -> [Vec3; 3] {
        self.triangles[t as usize].map(|v| self.positions[v as usize])
    }

    /// The corner of triangle `t` after `v`, going round
    fn next(&self, t: u32, v: u32) -> u32 {
        let [a, b, c] = self.triangles[t as usize];
        if a == v {
            b
        } else if b == v {
            c
        } else {
            a
        }
    }

    /// The corner of triangle `t` other than `a` and `b`
    fn third(&self, t: u32, a: u32, b: u32) -> u32 {
        self.triangles[t as usize]
            .into_iter()
            .find(|&v| v != a && v != b)
            .expect("a triangle has three corners")
    }

    fn mesh(&self) -> Mesh {
        let mut index = vec![NONE; self.positions.len()];
        let mut mesh = Mesh::new();
        for (t, triangle) in self.triangles.iter().enumerate() {
            if !self.alive[t] {
                continue;
            }
            let corners = triangle.map(|v| {
                let i = &mut index[v as usize];
                if *i == NONE {
                    *i = mesh.vertices.len() as u32;
                    let [x, y, z] = self.positions[v as usize].map(|c| c as f32);
                    mesh.vertices.push(nalgebra::Vector3::new(x, y, z));
                }
                *i as usize
            });
            mesh.triangles.push(corners.into());
        }
        mesh
    }
}

/// Whether the triangles `around` vertex `v` make one fan closed round it,
/// each neighbour on two of them.
fn is_disc(v: u32, around: &[u32], triangles: &[[u32; 3]]) -> bool {
    // Each triangle is an edge of the link, the path round `v`.
    let mut link = Vec::with_capacity(around.len());
    for &t in around {
        let triangle = triangles[t as usize];
        let Some(at) = triangle.iter().position(|&u| u == v) else {
            return false;
        };
        let (next, last) = (triangle[(at + 1) % 3], triangle[(at + 2) % 3]);
        if next == v || last == v || next == last {
            return false;
        }
        link.push((next, last));
    }
    if link.len() < 3 {
        return false;
    }
    // Walking the link from `start` comes back to it after all of it, and
    // no sooner.
    let (start, mut at) = link[0];
    for step in 1..link.len() {
        let mut leaving = link.iter().filter(|(a, _)| *a == at);
        let (Some(&(_, b)), None) = (leaving.next(), leaving.next()) else {
            return false;
        };
        at = b;
        if (at == start) != (step == link.len() - 1) {
            return false;
        }
    }
    link.iter().filter(|(a, _)| *a == start).count() == 1
}

// --- The mesher's surface ---

/// The mesher's triangles in a grid of cubes, to tell whether a point is
/// near them
struct Surface<'a> {
    positions: &'a [Vec3],
    triangles: &'a [[u32; 3]],
    side: f64,
    /// The cubes with triangles, sorted, and where their triangles start
    /// in `entries`
    cubes: Vec<(u64, u32)>,
    entries: Vec<u32>,
}

impl<'a> Surface<'a> {
    fn new(positions: &'a [Vec3], triangles: &'a [[u32; 3]], tolerance: f64) -> Self {
        // Cubes about as large as the triangles, and at least twice the
        // tolerance, so that a point's neighbourhood takes 8 at most
        let edges: f64 = triangles
            .par_iter()
            .map(|t| norm(sub(positions[t[1] as usize], positions[t[0] as usize])))
            .filter(|l| l.is_finite())
            .sum();
        let side = (edges / triangles.len().max(1) as f64).max(2.0 * tolerance);
        let mut keyed: Vec<(u64, u32)> = triangles
            .par_iter()
            .enumerate()
            .flat_map_iter(|(t, triangle)| {
                let corners = triangle.map(|v| positions[v as usize]);
                let finite = corners.iter().flatten().all(|c| c.is_finite());
                let bound = |pick: fn(f64, f64) -> f64| {
                    cube(
                        side,
                        [0, 1, 2].map(|i| pick(pick(corners[0][i], corners[1][i]), corners[2][i])),
                    )
                };
                let (lower, upper) = (bound(f64::min), bound(f64::max));
                let cubes = (lower[0]..=upper[0]).flat_map(move |x| {
                    (lower[1]..=upper[1])
                        .flat_map(move |y| (lower[2]..=upper[2]).map(move |z| key([x, y, z])))
                });
                cubes.filter(move |_| finite).map(move |k| (k, t as u32))
            })
            .collect();
        keyed.par_sort_unstable();
        let mut cubes = Vec::new();
        for (i, &(k, _)) in keyed.iter().enumerate() {
            if cubes.last().is_none_or(|&(last, _)| last != k) {
                cubes.push((k, i as u32));
            }
        }
        Surface {
            positions,
            triangles,
            side,
            cubes,
            entries: keyed.into_iter().map(|(_, t)| t).collect(),
        }
    }

    /// Whether `p` is within the square root of `squared` of a triangle
    fn near(&self, p: Vec3, squared: f64) -> bool {
        let reach = squared.sqrt();
        let lower = cube(self.side, p.map(|c| c - reach));
        let upper = cube(self.side, p.map(|c| c + reach));
        for x in lower[0]..=upper[0] {
            for y in lower[1]..=upper[1] {
                for z in lower[2]..=upper[2] {
                    let k = key([x, y, z]);
                    let Ok(i) = self.cubes.binary_search_by_key(&k, |&(k, _)| k) else {
                        continue;
                    };
                    let start = self.cubes[i].1 as usize;
                    let end = self
                        .cubes
                        .get(i + 1)
                        .map_or(self.entries.len(), |c| c.1 as usize);
                    let near = self.entries[start..end].iter().any(|&t| {
                        let corners =
                            self.triangles[t as usize].map(|v| self.positions[v as usize]);
                        distance_squared(p, corners) <= squared
                    });
                    if near {
                        return true;
                    }
                }
            }
        }
        false
    }
}

/// The cube of side `side` that holds `p`
fn cube(side: f64, p: Vec3) -> [i32; 3] {
    p.map(|c| (c / side).floor() as i32)
}

/// A cube as one number, 21 bits an axis; far cubes that share one only
/// cost a few more distances.
fn key(cube: [i32; 3]) -> u64 {
    cube.into_iter()
        .fold(0, |k, c| (k << 21) | (c as u64 & 0x1f_ffff))
}
// --- Geometry ---

fn sub(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn add(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn dot(a: Vec3, b: Vec3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn cross(a: Vec3, b: Vec3) -> Vec3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn norm(a: Vec3) -> f64 {
    dot(a, a).sqrt()
}

/// Twice the triangle's area, along its normal
fn normal(p: [Vec3; 3]) -> Vec3 {
    cross(sub(p[1], p[0]), sub(p[2], p[0]))
}

/// 1 for an equilateral triangle, towards 0 the thinner it is
fn quality(p: [Vec3; 3]) -> f64 {
    let edges: f64 = (0..3)
        .map(|i| {
            let edge = sub(p[(i + 1) % 3], p[i]);
            dot(edge, edge)
        })
        .sum();
    if edges == 0.0 {
        return 0.0;
    }
    2.0 * 3f64.sqrt() * norm(normal(p)) / edges
}

/// The squared distance from `p` to the triangle `[a, b, c]` (Ericson,
/// Real-Time Collision Detection, 5.1.5)
fn distance_squared(p: Vec3, [a, b, c]: [Vec3; 3]) -> f64 {
    let ab = sub(b, a);
    let ac = sub(c, a);
    let ap = sub(p, a);
    let d1 = dot(ab, ap);
    let d2 = dot(ac, ap);
    let closest = if d1 <= 0.0 && d2 <= 0.0 {
        a
    } else {
        let bp = sub(p, b);
        let d3 = dot(ab, bp);
        let d4 = dot(ac, bp);
        let cp = sub(p, c);
        let d5 = dot(ab, cp);
        let d6 = dot(ac, cp);
        let vc = d1 * d4 - d3 * d2;
        let vb = d5 * d2 - d1 * d6;
        let va = d3 * d6 - d5 * d4;
        if d3 >= 0.0 && d4 <= d3 {
            b
        } else if d6 >= 0.0 && d5 <= d6 {
            c
        } else if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 {
            along(a, ab, d1 / (d1 - d3))
        } else if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 {
            along(a, ac, d2 / (d2 - d6))
        } else if va <= 0.0 && d4 - d3 >= 0.0 && d5 - d6 >= 0.0 {
            along(b, sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6)))
        } else {
            let sum = va + vb + vc;
            if sum == 0.0 {
                // Degenerate: its corners will do.
                return [a, b, c]
                    .map(|q| dot(sub(p, q), sub(p, q)))
                    .into_iter()
                    .fold(f64::INFINITY, f64::min);
            }
            let (v, w) = (vb / sum, vc / sum);
            [0, 1, 2].map(|i| a[i] + ab[i] * v + ac[i] * w)
        }
    };
    let d = sub(p, closest);
    dot(d, d)
}

fn along(a: Vec3, direction: Vec3, t: f64) -> Vec3 {
    [0, 1, 2].map(|i| a[i] + direction[i] * t)
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::scene::{bound, jit};
    use fidget::context::Tree;
    use fidget::mesh::{Octree, Settings};

    /// `tree` meshed over [-1, 1]³ with cells 2 / 2^`depth` across
    fn mesh(tree: &Tree, depth: u8) -> Mesh {
        let shape = bound(jit(tree).expect("compiles")).expect("no variables");
        let settings = Settings {
            depth,
            ..Default::default()
        };
        Octree::build(&shape, &settings)
            .expect("not cancelled")
            .walk_dual()
    }

    fn simplified(mesh: &Mesh, tolerance: f64) -> Mesh {
        simplify(mesh, tolerance, &ThreadPool::Global, &CancelToken::new()).expect("not cancelled")
    }

    fn corners(mesh: &Mesh, t: usize) -> [Vec3; 3] {
        let t = mesh.triangles[t];
        [t.x, t.y, t.z].map(|v| [0, 1, 2].map(|i| f64::from(mesh.vertices[v][i])))
    }

    /// Asserts that every edge of `mesh` is on two triangles, once each way.
    fn assert_closed(mesh: &Mesh) {
        let mut edges = std::collections::HashMap::new();
        for t in &mesh.triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                *edges.entry((a, b)).or_insert(0) += 1;
            }
        }
        for (&(a, b), &count) in &edges {
            assert_eq!(count, 1, "edge {a}-{b} is used {count} times");
            assert_eq!(edges.get(&(b, a)), Some(&1), "edge {a}-{b} has no twin");
        }
    }

    /// The furthest the vertices and the middles of the triangles and
    /// their edges are from the surface `distance` measures
    fn deviation(mesh: &Mesh, distance: impl Fn(Vec3) -> f64) -> f64 {
        (0..mesh.triangles.len())
            .flat_map(|t| {
                let [a, b, c] = corners(mesh, t);
                let middle = |p: [Vec3; 2]| [0, 1, 2].map(|i| (p[0][i] + p[1][i]) / 2.0);
                [
                    a,
                    [0, 1, 2].map(|i| (a[i] + b[i] + c[i]) / 3.0),
                    middle([a, b]),
                    middle([b, c]),
                    middle([c, a]),
                ]
            })
            .map(|p| distance(p).abs())
            .fold(0.0, f64::max)
    }

    fn volume(mesh: &Mesh) -> f64 {
        (0..mesh.triangles.len())
            .map(|t| {
                let [a, b, c] = corners(mesh, t);
                dot(a, cross(b, c)) / 6.0
            })
            .sum()
    }

    fn sphere(r: f32) -> Tree {
        let (x, y, z) = Tree::axes();
        (x.square() + y.square() + z.square()).sqrt() - r
    }

    fn sphere_distance(r: f64) -> impl Fn(Vec3) -> f64 {
        move |p| norm(p) - r
    }

    fn cuboid(half: Vec3) -> Tree {
        let (x, y, z) = Tree::axes();
        let side = |axis: Tree, h: f64| axis.abs() - h as f32;
        side(x, half[0]).max(side(y, half[1])).max(side(z, half[2]))
    }

    /// Distance from the cuboid's surface, exact on the cuboid's side of
    /// it and close enough outside it for the tolerances tested
    fn cuboid_distance(half: Vec3) -> impl Fn(Vec3) -> f64 {
        move |p| {
            let d = [0, 1, 2].map(|i| p[i].abs() - half[i]);
            let outside = norm(d.map(|v| v.max(0.0)));
            outside + d[0].max(d[1]).max(d[2]).min(0.0)
        }
    }

    #[test]
    fn curves_keep_to_the_tolerance() {
        let raw = mesh(&sphere(0.8), 6);
        for tolerance in [0.002, 0.01] {
            let simple = simplified(&raw, tolerance);
            assert_closed(&simple);
            assert!(
                simple.triangles.len() * 4 < raw.triangles.len(),
                "{} of {} triangles left",
                simple.triangles.len(),
                raw.triangles.len()
            );
            // Between the mesher's vertices, a triangle bowing off the
            // curve may go a little further.
            let off = deviation(&simple, sphere_distance(0.8));
            assert!(off <= tolerance * 1.25, "{off} off at {tolerance}");
        }
    }

    #[test]
    fn flat_faces_take_few_triangles_and_keep_their_edges() {
        // Turned off the octree's axes, so that its cells cut the faces.
        let half = [0.5, 0.3, 0.2];
        let (x, y, z) = Tree::axes();
        let (c, s) = (0.8f32, 0.6f32);
        let turned = cuboid(half).remap_xyz(x.clone() * c + y.clone() * s, y * c - x * s, z);
        let raw = mesh(&turned, 6);
        let simple = simplified(&raw, 0.005);
        assert_closed(&simple);
        assert!(
            simple.triangles.len() < 100,
            "{} triangles",
            simple.triangles.len()
        );
        let (c, s) = (f64::from(c), f64::from(s));
        let distance = cuboid_distance(half);
        let off = deviation(&simple, |p| {
            distance([p[0] * c + p[1] * s, p[1] * c - p[0] * s, p[2]])
        });
        assert!(off <= 0.006, "{off} off");
    }

    #[test]
    fn thin_walls_stay() {
        // Two cells thick, its sides a cell apart from the octree's planes
        let half = [0.7, 0.6, 0.03];
        let raw = mesh(&cuboid(half), 6);
        let simple = simplified(&raw, 0.01);
        assert_closed(&simple);
        let off = deviation(&simple, cuboid_distance(half));
        assert!(off <= 0.011, "{off} off");
        let (before, after) = (volume(&raw), volume(&simple));
        assert!(
            (after - before).abs() < before * 0.05,
            "volume {before} became {after}"
        );
    }

    #[test]
    fn large_meshes_are_simplified_in_blocks_as_well() {
        let raw = mesh(&sphere(0.9), 8);
        assert!(
            raw.triangles.len() >= MIN_SPLIT,
            "{} triangles",
            raw.triangles.len()
        );
        let simple = simplified(&raw, 0.002);
        assert_closed(&simple);
        assert!(simple.triangles.len() * 10 < raw.triangles.len());
        let off = deviation(&simple, sphere_distance(0.9));
        assert!(off <= 0.0025, "{off} off");
    }
}
