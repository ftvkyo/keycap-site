// SPDX-License-Identifier: MPL-2.0

//! Exact distance fields of filled outlines, behind `text` and `svg`.
//!
//! An outline is a set of polygons that neither cross nor overlap, as
//! [`clean`] leaves them.  Its field is the distance to the nearest edge,
//! negative where a ray from the point crosses the edges a nonzero number of
//! times, counted with their direction.  Both are minimums and sums over
//! every edge, which a tree evaluates at every point; a hierarchy of boxes
//! around contours and runs of their edges lets interval arithmetic leave
//! out the ones that cannot matter to a region, so that the tapes fidget
//! simplifies for a tile keep only the edges near it, and a region away
//! from the edges is seen to be inside or outside without them.
//!
//! fidget's tape keeps a node that two places use in a register from the
//! first to the last, and the GPU has 255 registers.  So the distances and
//! the winding number share no node but the coordinates, and each box takes
//! nodes of its own from those, so that the same glyph twice, or two
//! glyphs at the same height, share none either.  The GPU also simplifies
//! a tape by its last 512 choices (`min`, `max`, `and`) alone, so only the
//! edges' `min` and the boxes choose; each edge's clamp and test is
//! arithmetic.

use fidget::context::Tree;
use i_overlay::core::fill_rule::FillRule;
use i_overlay::float::simplify::SimplifyShape;
use kurbo::{BezPath, PathEl};

pub type Point = [f64; 2];

/// A closed polygon, its last point joined to its first
pub type Contour = Vec<Point>;

/// Edges per leaf of the hierarchy: fewer adds boxes, more evaluates edges
/// a box would have ruled out.  32 renders text and KiCad's drill holes
/// fastest, a glyph or a hole being one leaf or two.
const LEAF: usize = 32;

/// The value of an outline with no edges: far outside everywhere.
const EMPTY: f32 = 1e9;

/// The polygons `contours` fill under `rule`, as polygons that neither
/// cross nor overlap, outlines one way round and holes the other.
pub fn clean(contours: &[Contour], rule: FillRule) -> Vec<Contour> {
    let contours: Vec<Contour> = contours.iter().filter(|c| c.len() >= 3).cloned().collect();
    if contours.is_empty() {
        return vec![];
    }
    contours
        .simplify_shape(rule)
        .into_iter()
        .flatten()
        .collect()
}

/// The closed subpaths of `path` and its open ones, with curves replaced by
/// lines no further than `tolerance` from them.
pub fn flatten(path: &BezPath, tolerance: f64) -> (Vec<Contour>, Vec<Contour>) {
    let mut closed = vec![];
    let mut open = vec![];
    let mut current: Contour = vec![];
    let finish = |current: &mut Contour, into: &mut Vec<Contour>| {
        let points = std::mem::take(current);
        if points.len() >= 2 {
            into.push(points);
        }
    };
    kurbo::flatten(path, tolerance, |element| match element {
        PathEl::MoveTo(p) => {
            finish(&mut current, &mut open);
            current.push([p.x, p.y]);
        }
        PathEl::LineTo(p) => current.push([p.x, p.y]),
        PathEl::ClosePath => finish(&mut current, &mut closed),
        // flatten emits lines only
        PathEl::QuadTo(..) | PathEl::CurveTo(..) => {}
    });
    finish(&mut current, &mut open);
    (closed, open)
}

/// The exact field of the area `contours` enclose, contours as [`clean`]
/// leaves them.
pub fn field(contours: &[Contour]) -> Tree {
    let mut lower = [f64::INFINITY; 2];
    let mut upper = [f64::NEG_INFINITY; 2];
    for p in contours.iter().flatten() {
        for i in 0..2 {
            lower[i] = lower[i].min(p[i]);
            upper[i] = upper[i].max(p[i]);
        }
    }
    if !(lower[0] < upper[0] && lower[1] < upper[1]) {
        return Tree::constant(EMPTY);
    }
    // The rays run along the outline's shorter side, so that they cross
    // few of its edges: up through a line of text, not along it.
    let along = usize::from(upper[0] - lower[0] > upper[1] - lower[1]);
    let swap = |p: &Point| if along == 0 { *p } else { [p[1], p[0]] };
    let axes = if along == 0 {
        Axes::new(Tree::x(), Tree::y())
    } else {
        Axes::new(Tree::y(), Tree::x())
    };
    let parts: Vec<Part> = contours
        .iter()
        .filter_map(|c| {
            let next = c.iter().cycle().skip(1);
            let edges: Vec<Edge> = c
                .iter()
                .zip(next)
                .map(|(p, q)| Edge::new(swap(p), swap(q)))
                .filter(|e| e.e != [0.0, 0.0])
                .collect();
            (!edges.is_empty()).then(|| run(&axes, &edges))
        })
        .collect();
    let Some(outline) = gather(&axes, parts) else {
        return Tree::constant(EMPTY);
    };
    // 1 where the winding number is at least a half, 0 elsewhere: a ray
    // through a corner can sum its edges' halves to exactly a half, and a
    // sign of 0 there would leave the field 0 with no gradient.
    let inside = (outline.winding.abs().compare(0.5f32) + 1.0f32).min(1.0f32);
    let distance = outline.distance2.sqrt() * (1.0f32 - inside * 2.0f32);
    // Outside its box the field is above this bound, which interval
    // arithmetic sees sooner than the field itself.
    let bound = |a: &Tree, lo: f64, hi: f64| (lo as f32 - a.clone()).max(a.clone() - hi as f32);
    let (u, v) = (&axes.u, &axes.v);
    let [lu, lv] = swap(&lower);
    let [uu, uv] = swap(&upper);
    distance.max(bound(u, lu, uu).max(bound(v, lv, uv)))
}

/// The coordinates the field is built in: `u` along the rays, `v` across
/// them, so that every ray runs towards +u.
struct Axes {
    u: Tree,
    v: Tree,
}

impl Axes {
    fn new(u: Tree, v: Tree) -> Self {
        Axes { u, v }
    }

    /// The axes moved to `centre`, as the part there measures distances in
    /// them.  Parts lie side by side along `v`, so `u` takes in a 0 made
    /// from `v` there, by a comparison that always comes out the same: `u`
    /// less a height alone would be one node for every part at that height.
    fn moved(&self, centre: Point) -> Axes {
        let v = self.v.clone() - centre[1] as f32;
        let zero = v.compare(1e30f32) + 1.0f32;
        let u = self.u.clone() + zero - centre[0] as f32;
        Axes::new(u, v)
    }

    /// `u` as the part at `centre` counts windings in it: exactly `u`, with
    /// a 0 as `moved`'s from a node of `v` that is not `moved`'s.
    fn own_u(&self, centre: Point) -> Tree {
        let near = Tree::constant(centre[1] as f32) - self.v.clone();
        self.u.clone() + (near.compare(1e30f32) + 1.0f32)
    }

    /// 1 between `lo` and `hi` across the rays, half that on either, 0
    /// past them, so that a ray through a corner counts it once.
    fn across(&self, lo: f64, hi: f64) -> Tree {
        (self.v.compare(lo as f32) - self.v.compare(hi as f32)) * 0.5f32
    }
}

/// One edge of a contour, from `p` to `p + e`, in (u, v)
struct Edge {
    p: Point,
    e: Point,
}

impl Edge {
    fn new(p: Point, q: Point) -> Self {
        Edge {
            p,
            e: [q[0] - p[0], q[1] - p[1]],
        }
    }

    fn end(&self) -> Point {
        [self.p[0] + self.e[0], self.p[1] + self.e[1]]
    }

    /// The squared distance to the edge: to its line, plus past its ends
    /// along it.  The latter is 0 exactly in the edge's span, gradient
    /// included, so near the edge the gradient is the line's, where the
    /// difference between a point and its projection would be rounding
    /// noise.  `moved` are the axes moved to `centre`.
    fn distance2(&self, moved: &Axes, centre: Point) -> Tree {
        let [pu, pv] = self.p;
        let [eu, ev] = self.e;
        let ee = eu * eu + ev * ev;
        let el = ee.sqrt();
        let wu = moved.u.clone() - (pu - centre[0]) as f32;
        let wv = moved.v.clone() - (pv - centre[1]) as f32;
        let line = wu.clone() * (ev / el) as f32 - wv.clone() * (eu / el) as f32;
        // The nearest point's place along the line, 0 and 1 at the ends
        let t = wu * (eu / ee) as f32 + wv * (ev / ee) as f32;
        let past = positive((t - 0.5f32).abs() - 0.5f32) * el as f32;
        line.square() + past.square()
    }

    /// The edge's share of the winding number: plus or minus one when the
    /// ray from the point crosses it, by the way it runs.
    fn winding(&self, axes: &Axes) -> Option<Tree> {
        let [pu, pv] = self.p;
        let [eu, ev] = self.e;
        if ev == 0.0 {
            return None;
        }
        let across = axes.across(pv.min(pv + ev), pv.max(pv + ev));
        // Where the edge meets the point's line, ahead of the point or not
        let slope = eu / ev;
        let crossing = (axes.v.clone() - pv as f32) * slope as f32 + pu as f32;
        let ahead = below(&axes.u, crossing);
        Some(across * ahead * ev.signum() as f32)
    }
}

/// Part of an outline: the squared distance to its nearest edge, the
/// winding number its edges add up to, and its box
struct Part {
    distance2: Tree,
    winding: Tree,
    lower: Point,
    upper: Point,
}

/// The box from `lower` to `upper`, as the parts behind it use it
struct Bounds {
    /// The squared distance to the box
    distance2: Tree,
    /// Zero outside the box
    inside: Tree,
}

impl Bounds {
    fn new(axes: &Axes, lower: Point, upper: Point) -> Self {
        let centre = centre(lower, upper);
        let moved = axes.moved(centre);
        let half = [0, 1].map(|i| ((upper[i] - lower[i]) * 0.5) as f32);
        let off_u = moved.u.abs() - half[0];
        let off_v = moved.v.abs() - half[1];
        let between = |a: &Tree, lo: f64, hi: f64| a.compare(lo as f32) - a.compare(hi as f32);
        Bounds {
            distance2: positive(off_u).square() + positive(off_v).square(),
            inside: between(&axes.own_u(centre), lower[0], upper[0])
                * between(&axes.v, lower[1], upper[1]),
        }
    }

    /// `distance2` behind the box.  No edge is nearer than the box, so the
    /// maximum is the part's own value; but on a region far from the box,
    /// interval arithmetic sees the box's distance there and lets a nearer
    /// part's `min` drop this one.
    fn distance2(&self, distance2: Tree) -> Tree {
        self.distance2.max(distance2)
    }
}

/// `a` where it is positive, 0 elsewhere: `max(a, 0)` as arithmetic,
/// which makes no choice.
fn positive(a: Tree) -> Tree {
    (a.clone() + a.abs()) * 0.5f32
}

/// 1 where `a` is below `b`, 0 elsewhere, without a choice.
fn below(a: &Tree, b: impl Into<Tree>) -> Tree {
    (a.compare(b) + 1.0f32).not()
}

/// The middle of the box from `lower` to `upper`
fn centre(lower: Point, upper: Point) -> Point {
    [0, 1].map(|i| (lower[i] + upper[i]) * 0.5)
}

/// The part a run of consecutive edges makes, split in halves down to
/// leaves.  Inside its box the run's winding number is its edges'; ahead
/// of the box a ray crosses the run as often as the line between its
/// ends, and past the box not at all.
fn run(axes: &Axes, edges: &[Edge]) -> Part {
    let mut lower = [f64::INFINITY; 2];
    let mut upper = [f64::NEG_INFINITY; 2];
    for edge in edges {
        for p in [edge.p, edge.end()] {
            for i in 0..2 {
                lower[i] = lower[i].min(p[i]);
                upper[i] = upper[i].max(p[i]);
            }
        }
    }
    let centre = centre(lower, upper);
    let own = Axes::new(axes.own_u(centre), axes.v.clone());
    let (distance2, winding) = if edges.len() <= LEAF {
        let moved = axes.moved(centre);
        let distance2 = edges
            .iter()
            .map(|e| e.distance2(&moved, centre))
            .reduce(|a, b| a.min(b));
        let winding = edges
            .iter()
            .filter_map(|e| e.winding(&own))
            .reduce(|a, b| a + b);
        (
            distance2.expect("a run has edges"),
            winding.unwrap_or_else(|| Tree::constant(0.0)),
        )
    } else {
        let (first, second) = edges.split_at(edges.len() / 2);
        let (a, b) = (run(axes, first), run(axes, second));
        (a.distance2.min(b.distance2), a.winding + b.winding)
    };

    let bounds = Bounds::new(axes, lower, upper);
    let mut winding = bounds.inside.and(winding);
    let (start, end) = (edges[0].p[1], edges[edges.len() - 1].end()[1]);
    if start != end {
        let ahead = below(&own.u, lower[0] as f32);
        let ends = axes.across(start.min(end), start.max(end)) * (end - start).signum() as f32;
        winding += ahead.and(ends);
    }
    Part {
        distance2: bounds.distance2(distance2),
        winding,
        lower,
        upper,
    }
}

/// The parts, whole contours, gathered into a hierarchy of boxes: a whole
/// contour adds nothing to the winding number outside its box.
fn gather(axes: &Axes, mut parts: Vec<Part>) -> Option<Part> {
    if parts.len() <= 1 {
        return parts.pop();
    }
    let mut lower = [f64::INFINITY; 2];
    let mut upper = [f64::NEG_INFINITY; 2];
    for part in &parts {
        for i in 0..2 {
            lower[i] = lower[i].min(part.lower[i]);
            upper[i] = upper[i].max(part.upper[i]);
        }
    }
    let axis = usize::from(upper[1] - lower[1] > upper[0] - lower[0]);
    let centre = |p: &Part| p.lower[axis] + p.upper[axis];
    let half = parts.len() / 2;
    parts.select_nth_unstable_by(half, |a, b| centre(a).total_cmp(&centre(b)));
    let second = parts.split_off(half);
    let a = gather(axes, parts)?;
    let b = gather(axes, second)?;
    let bounds = Bounds::new(axes, lower, upper);
    Some(Part {
        distance2: bounds.distance2(a.distance2.min(b.distance2)),
        winding: bounds.inside.and(a.winding + b.winding),
        lower,
        upper,
    })
}

#[cfg(test)]
mod test {
    use fidget::context::Context;
    use fidget::jit::JitShape;
    use fidget::types::Interval;

    use super::*;

    fn jit(tree: &Tree) -> JitShape {
        let mut context = Context::new();
        let node = context.import(tree);
        JitShape::new(&context, node).expect("it compiles")
    }

    fn at(tree: &Tree, points: &[Point]) -> Vec<f64> {
        let shape = jit(tree);
        let tape = shape.point_tape(Default::default());
        let mut eval = JitShape::new_point_eval();
        points
            .iter()
            .map(|p| {
                let (v, _) = eval
                    .eval(&tape, p[0] as f32, p[1] as f32, 0.0)
                    .expect("it evaluates");
                f64::from(v)
            })
            .collect()
    }

    fn square(lo: f64, hi: f64) -> Contour {
        vec![[lo, lo], [hi, lo], [hi, hi], [lo, hi]]
    }

    fn circle(centre: Point, r: f64, n: u32) -> Contour {
        (0..n)
            .map(|i| {
                let a = std::f64::consts::TAU * f64::from(i) / f64::from(n);
                [centre[0] + r * a.cos(), centre[1] + r * a.sin()]
            })
            .collect()
    }

    /// A square with a hole is exact inside, in the hole, outside, and on
    /// the lines through its corners.
    #[test]
    fn square_with_a_hole() {
        let contours = clean(&[square(0.0, 10.0), square(3.0, 7.0)], FillRule::EvenOdd);
        let tree = field(&contours);
        let points = [
            [1.0, 5.0],
            [5.0, 5.0],
            [-2.0, 5.0],
            [-3.0, 0.0],
            [5.0, 10.0],
            [13.0, 14.0],
            [2.0, 3.0],
            [-1.0, 7.0],
        ];
        let expected = [-1.0, 2.0, 2.0, 3.0, 0.0, 5.0, -1.0, 1.0];
        for ((v, e), p) in at(&tree, &points).iter().zip(expected).zip(points) {
            assert!((v - e).abs() < 1e-5, "{v} at {p:?}, not {e}");
        }
    }

    /// Two overlapping squares under nonzero make one outline: the edges
    /// inside it are gone, so the field there is not zero.
    #[test]
    fn overlaps_merge() {
        let contours = clean(&[square(0.0, 10.0), square(5.0, 15.0)], FillRule::NonZero);
        assert_eq!(contours.len(), 1);
        let v = at(&field(&contours), &[[6.0, 7.5]]);
        // The nearest edge is the corner the squares make, not the first's side.
        assert!((v[0] + 7.25f64.sqrt()).abs() < 1e-5, "{v:?}");
        let even_odd = clean(&[square(0.0, 10.0), square(5.0, 15.0)], FillRule::EvenOdd);
        let v = at(&field(&even_odd), &[[7.5, 7.5], [2.0, 5.0]]);
        assert!(v[0] > 0.0 && v[1] < 0.0, "{v:?}");
    }

    #[test]
    fn many_edges() {
        let tree = field(&clean(&[circle([0.0, 0.0], 10.0, 2000)], FillRule::NonZero));
        let v = at(&tree, &[[0.0, 0.0], [20.0, 0.0], [0.0, -15.0], [-3.0, 4.0]]);
        let expected = [-10.0, 10.0, 5.0, -5.0];
        for (v, e) in v.iter().zip(expected) {
            assert!((v - e).abs() < 1e-3, "{v} not {e}");
        }
    }

    /// Interval arithmetic sees that a region between contours, away from
    /// their edges, is outside, and one inside a contour inside.
    #[test]
    fn regions_away_from_edges_are_decided() {
        let holes: Vec<Contour> = (0..10)
            .flat_map(|i| (0..5).map(move |j| [f64::from(i) * 4.0, f64::from(j) * 4.0]))
            .map(|c| circle(c, 1.0, 32))
            .collect();
        let shape = jit(&field(&clean(&holes, FillRule::NonZero)));
        let tape = shape.interval_tape(Default::default());
        let mut eval = JitShape::new_interval_eval();
        let mut value = |x: [f32; 2], y: [f32; 2]| {
            let (x, y) = (Interval::new(x[0], x[1]), Interval::new(y[0], y[1]));
            let (v, _) = eval
                .eval(&tape, x, y, Interval::from(0.0))
                .expect("it evaluates");
            v
        };
        // Below a column of discs, and between two rows of them
        assert!(value([7.5, 8.5], [-4.0, -2.0]).lower() > 0.0);
        assert!(value([3.0, 13.0], [1.5, 2.5]).lower() > 0.0);

        let shape = jit(&field(&clean(&[square(0.0, 10.0)], FillRule::NonZero)));
        let tape = shape.interval_tape(Default::default());
        let (x, y) = (Interval::new(4.0, 6.0), Interval::new(3.0, 7.0));
        let (v, _) = eval
            .eval(&tape, x, y, Interval::from(0.0))
            .expect("it evaluates");
        assert!(v.upper() < 0.0, "{v:?}");
    }
}
