// SPDX-License-Identifier: MPL-2.0

//! Regions of space: the script's bounds, bounds fitted to the shapes by
//! interval arithmetic, and the region a view or a mesh covers.

use std::collections::BinaryHeap;
use std::rc::Rc;

use fidget::context::Tree;
use fidget::eval::{Function, TracingEvaluator};
use fidget::jit::{JitFunction, JitShape};
use fidget::shape::{ShapeTape, ShapeTracingEval};
use fidget::types::Interval;
use fidget::var::Var;
use serde::Serialize;

use crate::protocol::BoundsChoice;

/// An axis-aligned box, every side known.
#[derive(Serialize, Clone, Copy, Debug, PartialEq)]
pub struct Box3 {
    pub lower: [f64; 3],
    pub upper: [f64; 3],
}

impl Box3 {
    pub fn center(&self) -> [f64; 3] {
        std::array::from_fn(|i| (self.lower[i] + self.upper[i]) / 2.0)
    }

    pub fn size(&self) -> [f64; 3] {
        std::array::from_fn(|i| self.upper[i] - self.lower[i])
    }
}

/// Bounds fitted to shapes; a side is `None` where the shapes reach the
/// edge of the search, which is taken as unbounded.
#[derive(Serialize, Clone, Copy, Debug, PartialEq)]
pub struct Fitted {
    pub lower: [Option<f64>; 3],
    pub upper: [Option<f64>; 3],
}

impl Fitted {
    /// Grows every bounded side by a few percent of its axis, so that
    /// surfaces do not touch the edge of a view or a mesh.
    pub fn padded(&self) -> Fitted {
        let widest = (0..3)
            .filter_map(|i| Some(self.upper[i]? - self.lower[i]?))
            .fold(0.0, f64::max);
        let mut out = *self;
        for i in 0..3 {
            let extent = match (self.lower[i], self.upper[i]) {
                (Some(lower), Some(upper)) => upper - lower,
                _ => widest,
            };
            let pad = (0.03 * extent).max(0.01 * widest).max(1e-6);
            out.lower[i] = self.lower[i].map(|v| v - pad);
            out.upper[i] = self.upper[i].map(|v| v + pad);
        }
        out
    }

    /// Whether no side is bounded.
    pub fn unbounded(&self) -> bool {
        self.lower.iter().chain(&self.upper).all(Option::is_none)
    }
}

/// Half the side of the region shown when nothing bounds the shapes, as
/// large as a small part.
const FALLBACK: f64 = 10.0;

/// The region a view or a mesh covers: the script's bounds when asked for
/// and set, otherwise the padded fitted ones.  Unbounded axes are centred on
/// 0, or reach from their one known side, as wide as the widest bounded
/// axis, or [`FALLBACK`] each way when none is.
pub fn region(
    choice: BoundsChoice,
    script: Option<Box3>,
    fitted: Option<Fitted>,
) -> (Box3, BoundsChoice) {
    if let (BoundsChoice::Script, Some(script)) = (choice, script) {
        return (script, BoundsChoice::Script);
    }
    let fitted = fitted.map(|f| f.padded()).unwrap_or(Fitted {
        lower: [Some(-FALLBACK); 3],
        upper: [Some(FALLBACK); 3],
    });
    let widest = (0..3)
        .filter_map(|i| Some(fitted.upper[i]? - fitted.lower[i]?))
        .fold(0.0, f64::max);
    let widest = if widest > 0.0 { widest } else { 2.0 * FALLBACK };
    let mut out = Box3 {
        lower: [0.0; 3],
        upper: [0.0; 3],
    };
    for i in 0..3 {
        (out.lower[i], out.upper[i]) = match (fitted.lower[i], fitted.upper[i]) {
            (Some(lower), Some(upper)) => (lower, upper),
            (Some(lower), None) => (lower, lower + widest),
            (None, Some(upper)) => (upper - widest, upper),
            (None, None) => (-widest / 2.0, widest / 2.0),
        };
    }
    (out, BoundsChoice::Fitted)
}

// --- Fitting ---

/// How far out the search for the shapes starts; shapes reaching this far
/// are unbounded.
const SEARCH: f32 = 1e4;

/// How much coarser than the tolerance along a side the cells testing a
/// slab may stay across it: fine enough for their intervals to be tight.
const ACROSS: f32 = 4.0;

/// Interval evaluations allowed for finding one side, which only shapes
/// whose intervals stay loose under subdivision exhaust.
const BUDGET: usize = 4096;

/// Interval evaluations allowed for proving one ring about the Z axis
/// empty, in [`radius`].
const EMPTY_BUDGET: usize = 4096;

/// How far out, in millimetres, a side of fitted bounds is taken to be
/// loose rather than a part's: further than any printer reaches.
const LOOSE: f64 = 1000.0;

type Sides = [(Option<f32>, Option<f32>); 3];

/// Fits bounds to `shape`, compiled from `tree`, or `None` when it is
/// provably empty: those of [`fit_box`], and where they leave an X or Y
/// side unbounded or [`LOOSE`] away, their X and Y sides narrowed to the
/// radius about the Z axis that [`radius`] finds.  The search for it costs
/// as much as the box's again, or more, so it runs only where it may help.
pub fn fit(tree: &Tree, shape: &JitShape) -> Option<Fitted> {
    let mut fitted = fit_box(shape)?;
    let uses = Search::new(shape).uses;
    let loose = (0..2).any(|i| {
        [fitted.lower[i], fitted.upper[i]]
            .iter()
            .any(|side| side.is_none_or(|v| v.abs() > LOOSE))
    });
    if !(uses[0] && uses[1] && loose) {
        return Some(fitted);
    }
    let z = match (fitted.lower[2], fitted.upper[2]) {
        (Some(lower), Some(upper)) => Interval::new(lower as f32, upper as f32),
        _ => Interval::new(-SEARCH, SEARCH),
    };
    if let Some(r) = radius(tree, z) {
        let r = f64::from(r);
        for i in 0..2 {
            fitted.lower[i] = Some(fitted.lower[i].map_or(-r, |v| v.max(-r)));
            fitted.upper[i] = Some(fitted.upper[i].map_or(r, |v| v.min(r)));
        }
    }
    Some(fitted)
}

/// Each side of `shape`'s bounds, found by a search through cells, the
/// ones reaching furthest out first, until the shape is found or cannot be
/// ruled out at the tolerance; every cell further out is proven empty.  A
/// coarse pass from ±[`SEARCH`] finds each side to 1/4096 of the search;
/// each fine pass starts from the last one's bounds, to 1/400 of their
/// extent, until that stops shrinking.
fn fit_box(shape: &JitShape) -> Option<Fitted> {
    let mut search = Search::new(shape);
    let mut start = [Interval::new(-SEARCH, SEARCH); 3];
    search.within(&(start, search.root.clone(), f32::INFINITY))?;
    let mut tolerance = [2.0 * SEARCH / 4096.0; 3];
    let mut sides = search.sides(start, tolerance, true);
    // An axis the shape spans from end to end is one that splitting
    // cannot tighten, only multiply cells along.
    for (split, side) in search.split.iter_mut().zip(sides) {
        *split &= side != (None, None);
    }
    for pass in 0..4 {
        if sides
            .iter()
            .any(|&side| matches!(side, (Some(lower), Some(upper)) if lower > upper))
        {
            return None;
        }
        // The size of the shape, which tolerances are fractions of: its
        // widest bounded axis, or how far out its known sides are.
        let widest = (0..3)
            .filter_map(|i| Some(sides[i].1? - sides[i].0?))
            .fold(0.0f32, f32::max);
        let size = if widest > 0.0 {
            widest
        } else {
            let known = sides.iter().flat_map(|&(lower, upper)| [lower, upper]);
            known.flatten().map(f32::abs).fold(1e-3, f32::max)
        };
        let finer: [f32; 3] = std::array::from_fn(|i| {
            let extent = match sides[i] {
                (Some(lower), Some(upper)) => upper - lower,
                _ => size,
            };
            (extent / 400.0).max(size * 1e-4)
        });
        if pass > 0 && (0..3).all(|i| finer[i] * 2.0 > tolerance[i]) {
            break;
        }
        for i in 0..3 {
            let (lower, upper) = sides[i];
            start[i] = Interval::new(
                lower.map_or(-SEARCH, |v| (v - tolerance[i]).max(-SEARCH)),
                upper.map_or(SEARCH, |v| (v + tolerance[i]).min(SEARCH)),
            );
        }
        tolerance = finer;
        sides = search.sides(start, tolerance, false);
    }
    Some(Fitted {
        lower: std::array::from_fn(|i| sides[i].0.map(f64::from)),
        upper: std::array::from_fn(|i| sides[i].1.map(f64::from)),
    })
}

/// How far from the Z axis the shape `tree` reaches within the heights
/// `z`, or `None` when the search cannot tell.
///
/// A shape that turns about the Z axis, such as a twisted extrusion or a
/// polar array, has intervals in X and Y that stay loose however finely
/// they are split: a cell's corner turned by a range of angles covers a
/// range of places.  In polar coordinates, a cell of radius, angle and
/// height turned so is still a small piece of a ring, far from the axis.
///
/// Proving that a ring holds nothing still takes cells of a small angle
/// and height, as many at every radius, so the search proves rings empty
/// from [`SEARCH`] inwards, each half as far out as the last, then halves
/// the gap to the first it cannot prove empty, a few times.
fn radius(tree: &Tree, z: Interval) -> Option<f32> {
    let (r, a, h) = Tree::axes();
    let polar = tree.remap_xyz(r.clone() * a.clone().cos(), r * a.sin(), h);
    let shape = crate::scene::jit(&polar).ok()?;
    let mut search = Search::new(&shape);
    let turn = std::f32::consts::TAU;
    let height = if z.width() < 2.0 * SEARCH {
        z.width().max(1e-3)
    } else {
        1.0
    };
    let mut empty = |inner: f32, outer: f32| {
        let ring = [
            Interval::new(inner, outer),
            Interval::new(-turn / 2.0, turn / 2.0),
            z,
        ];
        let finest = [(outer - inner) / 4.0, turn / 1024.0, height / 1024.0];
        search.empty(ring, finest)
    };
    // Nothing lies beyond `outer`.
    let mut outer = SEARCH;
    while outer > 1e-3 && empty(outer / 2.0, outer) {
        outer /= 2.0;
    }
    if outer >= SEARCH {
        return None;
    }
    let mut inner = outer / 2.0;
    for _ in 0..5 {
        let middle = (inner + outer) / 2.0;
        if empty(middle, outer) {
            outer = middle;
        } else {
            inner = middle;
        }
    }
    Some(outer)
}

/// Whether interval arithmetic gives `shape` NaN far out, along some axis
/// it depends on, which keeps a fit from proving any side there.  fidget's
/// intervals are NaN for a division by one that holds 0, and for `sqrt`,
/// `ln` or `acos` of one that reaches out of their domain, even when the
/// values themselves never do; `min` and `max` pass NaN on.
pub fn nan_far_out(shape: &JitShape) -> bool {
    let mut search = Search::new(shape);
    let far = Interval::new(SEARCH / 2.0, SEARCH);
    (0..3).filter(|&axis| search.uses[axis]).any(|axis| {
        [far, -far].into_iter().any(|slab| {
            let mut cell = [Interval::new(-SEARCH, SEARCH); 3];
            cell[axis] = slab;
            search
                .eval
                .eval(&search.root.tape, cell[0], cell[1], cell[2])
                .is_ok_and(|(value, _)| value.has_nan())
        })
    })
}

type IntervalEval = <JitFunction as Function>::IntervalEval;

/// The shape as the cells within one region see it: simplified to the
/// branches of its `min`s and `max`s that matter there, which for a large
/// tree, such as an SVG file's thousands of edges, is a small part of it.
struct Level {
    shape: JitShape,
    tape: ShapeTape<<IntervalEval as TracingEvaluator>::Tape>,
}

impl Level {
    fn new(shape: JitShape) -> Rc<Self> {
        let tape = shape.interval_tape(Default::default());
        Rc::new(Level { shape, tape })
    }
}

/// Tapes no longer than this are evaluated as they are, rather than
/// simplified for each cell.
const SIMPLE: usize = 64;

/// A cell's shape is simplified again once the cell is this many times
/// smaller than where it was last tried, so that cells on the way down do
/// not each pay for a pass over a long tape that saves little.
const SIMPLIFY_EVERY: f32 = 8.0;

/// The volume of `cell`, as its log2; NaN-free for cells of any width.
fn log_volume(cell: [Interval; 3]) -> f32 {
    cell.iter()
        .map(|i| i.width().max(f32::MIN_POSITIVE).log2())
        .sum()
}

/// A cell to look into, the shape as its parent saw it, and the log2 of the
/// volume where that shape was last simplified.
type Cell = ([Interval; 3], Rc<Level>, f32);

/// A cell ranked by how far out it reaches.
struct Ranked(f32, Cell);

impl PartialEq for Ranked {
    fn eq(&self, other: &Self) -> bool {
        self.0.total_cmp(&other.0).is_eq()
    }
}

impl Eq for Ranked {}

impl PartialOrd for Ranked {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Ranked {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.0.total_cmp(&other.0)
    }
}

struct Search {
    root: Rc<Level>,
    eval: ShapeTracingEval<IntervalEval>,
    workspace: <JitFunction as Function>::Workspace,
    /// Which axes the shape depends on; it is unbounded along the others.
    uses: [bool; 3],
    /// Which axes cells are split along
    split: [bool; 3],
}

impl Search {
    fn new(shape: &JitShape) -> Self {
        let root = Level::new(shape.clone());
        let uses = [Var::X, Var::Y, Var::Z].map(|v| root.tape.vars().get(&v).is_some());
        Search {
            root,
            eval: JitShape::new_interval_eval(),
            workspace: Default::default(),
            uses,
            split: uses,
        }
    }

    /// `None` when the cell is provably outside the shape; otherwise the
    /// cell's children's shape and log2 volume, as `Cell` has them: the
    /// shape simplified for the cell, when it is time to try and that
    /// leaves a quarter of it, worth compiling.  A failed or NaN
    /// evaluation proves nothing.
    fn within(&mut self, (b, level, tried): &Cell) -> Option<(Rc<Level>, f32)> {
        let Ok((value, trace)) = self.eval.eval(&level.tape, b[0], b[1], b[2]) else {
            return Some((level.clone(), *tried));
        };
        if value.lower() > 0.0 {
            return None;
        }
        let size = level.shape.size();
        let volume = log_volume(*b);
        let Some(trace) =
            trace.filter(|_| size > SIMPLE && volume <= tried - SIMPLIFY_EVERY.log2())
        else {
            return Some((level.clone(), *tried));
        };
        let simpler = (level.shape)
            .simplify(trace, Default::default(), &mut self.workspace)
            .ok()
            .filter(|shape| shape.size() * 4 < size);
        Some((simpler.map_or_else(|| level.clone(), Level::new), volume))
    }

    /// Whether the point `p` is inside the shape `level` holds.
    fn inside(&mut self, level: &Level, p: [f32; 3]) -> bool {
        let at = p.map(|v| Interval::new(v, v));
        self.eval
            .eval(&level.tape, at[0], at[1], at[2])
            .is_ok_and(|(value, _)| value.upper() <= 0.0)
    }

    /// Every side of the shape within `start`.
    fn sides(&mut self, start: [Interval; 3], tolerance: [f32; 3], coarse: bool) -> Sides {
        std::array::from_fn(|axis| {
            if !self.uses[axis] {
                return (None, None);
            }
            // Slabs too wide for their intervals to be tight make a shape
            // look unbounded; finer cells across them tell.
            let mut side = |upper| {
                let side = self.side(start, axis, upper, tolerance, coarse);
                match side {
                    None if coarse => self.side(start, axis, upper, tolerance, false),
                    _ => side,
                }
            };
            (side(false), side(true))
        })
    }

    /// The furthest coordinate along `axis` (towards + when `upper`) of the
    /// shape within `start`, to within the tolerance and never short of
    /// it, or `None` when the shape reaches the edge of the search.
    ///
    /// The cells reaching furthest out are looked into first, each with
    /// the shape simplified for it, until one that is not provably outside
    /// is as fine as the tolerance allows, along `axis` and [`ACROSS`]
    /// times coarser across it, or holds a point of the shape within the
    /// tolerance of its outer side.  Every cell reaching further is outside.
    ///
    /// A `coarse` search, which only has to find where the shape is for a
    /// fine one, splits cells along `axis` only and leaves the shape as it
    /// is: until they are about its size, its cells hold all of it or
    /// none.
    fn side(
        &mut self,
        start: [Interval; 3],
        axis: usize,
        upper: bool,
        tolerance: [f32; 3],
        coarse: bool,
    ) -> Option<f32> {
        // How far out a coordinate is, larger outwards
        let out = |v: f32| if upper { v } else { -v };
        let outer = |cell: &[Interval; 3]| {
            out(if upper {
                cell[axis].upper()
            } else {
                cell[axis].lower()
            })
        };
        let edge = if upper {
            start[axis].upper()
        } else {
            start[axis].lower()
        };
        let simplify = if coarse {
            f32::NEG_INFINITY
        } else {
            f32::INFINITY
        };
        let mut cells =
            BinaryHeap::from([Ranked(outer(&start), (start, self.root.clone(), simplify))]);
        let mut evaluations = 0;
        while let Some(Ranked(reach, entry)) = cells.pop() {
            evaluations += 1;
            let Some((level, tried)) = self.within(&entry) else {
                continue;
            };
            let cell = entry.0;
            let middle = cell.map(Interval::midpoint);
            let coarseness = |i: usize| {
                let limit = if i == axis {
                    tolerance[i]
                } else {
                    ACROSS * tolerance[i]
                };
                cell[i].width() / limit
            };
            let split = (0..3)
                .filter(|&i| i == axis || (self.split[i] && !coarse))
                .max_by(|&i, &j| coarseness(i).total_cmp(&coarseness(j)))
                .filter(|&i| coarseness(i) > 1.0);
            let found = reach - out(middle[axis]) <= tolerance[axis] && self.inside(&level, middle);
            let Some(split) = split.filter(|_| !found && evaluations < BUDGET) else {
                let side = out(reach);
                return (side != edge || edge.abs() < SEARCH).then_some(side);
            };
            let (low, high) = cell[split].split();
            for half in [low, high] {
                let mut child = cell;
                child[split] = half;
                cells.push(Ranked(outer(&child), (child, level.clone(), tried)));
            }
        }
        // Empty, so the side is past the far one: the bounds come out
        // inside out.
        Some(if upper {
            start[axis].lower()
        } else {
            start[axis].upper()
        })
    }

    /// Whether `b` is provably outside the shape: every cell of it, split
    /// down to cells `finest` across at most, within [`EMPTY_BUDGET`]
    /// evaluations.
    fn empty(&mut self, b: [Interval; 3], finest: [f32; 3]) -> bool {
        let mut cells = vec![(b, self.root.clone(), f32::INFINITY)];
        let mut evaluations = 0;
        while let Some(entry) = cells.pop() {
            evaluations += 1;
            if evaluations > EMPTY_BUDGET {
                return false;
            }
            let Some((level, tried)) = self.within(&entry) else {
                continue;
            };
            let cell = entry.0;
            let coarseness = |i: usize| cell[i].width() / finest[i];
            let split = (0..3)
                .filter(|&i| self.split[i])
                .max_by(|&i, &j| coarseness(i).total_cmp(&coarseness(j)));
            let Some(split) = split.filter(|&i| coarseness(i) > 1.0) else {
                return false;
            };
            let (low, high) = cell[split].split();
            for half in [low, high] {
                let mut child = cell;
                child[split] = half;
                cells.push((child, level.clone(), tried));
            }
        }
        true
    }

    /// Whether a point of `b` is provably inside the shape: one at the
    /// centre of a cell, coarsest first, down to cells `finest` across.
    fn holds(&mut self, b: [Interval; 3], finest: [f32; 3]) -> bool {
        let mut cells = std::collections::VecDeque::from([(b, self.root.clone(), f32::INFINITY)]);
        let mut evaluations = 0;
        while let Some(entry) = cells.pop_front() {
            evaluations += 1;
            if evaluations > CLIP_BUDGET {
                return false;
            }
            let Some((level, tried)) = self.within(&entry) else {
                continue;
            };
            let cell = entry.0;
            if self.inside(&level, cell.map(Interval::midpoint)) {
                return true;
            }
            let coarseness = |i: usize| cell[i].width() / finest[i];
            let split = (0..3)
                .filter(|&i| self.uses[i])
                .max_by(|&i, &j| coarseness(i).total_cmp(&coarseness(j)));
            let Some(split) = split.filter(|&i| coarseness(i) > 1.0) else {
                continue;
            };
            let (low, high) = cell[split].split();
            for half in [low, high] {
                let mut child = cell;
                child[split] = half;
                cells.push_back((child, level.clone(), tried));
            }
        }
        false
    }
}

// --- Clipping ---

const SIDES: [&str; 6] = ["-x", "+x", "-y", "+y", "-z", "+z"];

/// Interval evaluations allowed for proving that a shape reaches out of
/// one side of a region.
const CLIP_BUDGET: usize = 4096;

/// The sides, as `-x`, `+z` and so on, where `shape`, fitted with
/// `fitted`, provably reaches out of `region` by more than a hundredth of
/// it.
///
/// Fitted bounds only promise that the shape lies within them; where
/// intervals stay loose, they reach out of a region that holds the whole
/// shape.  So a side counts only once a point of the shape is found past
/// it.
pub fn sides_outside(shape: &JitShape, fitted: &Fitted, region: &Box3) -> Vec<&'static str> {
    let size = region.size();
    let slack = size.map(|s| 0.01 * s.abs());
    let mut search = None;
    let mut sides = vec![];
    for i in 0..3 {
        for (upper, side) in [(false, fitted.lower[i]), (true, fitted.upper[i])] {
            let edge = if upper {
                region.upper[i] + slack[i]
            } else {
                region.lower[i] - slack[i]
            };
            let Some(side) = side.filter(|&v| if upper { v > edge } else { v < edge }) else {
                continue;
            };
            // The part of the fitted bounds past the side
            let slab: [Interval; 3] = std::array::from_fn(|j| {
                let (lower, upper) = if j == i {
                    (edge.min(side), edge.max(side))
                } else {
                    // An unbounded side reaches the region's, or a region's
                    // width past the bounded side where that lies beyond it.
                    let width = size[j].abs();
                    let (l, u) = (fitted.lower[j], fitted.upper[j]);
                    (
                        l.unwrap_or_else(|| {
                            u.map_or(region.lower[j], |u| region.lower[j].min(u - width))
                        }),
                        u.unwrap_or_else(|| {
                            l.map_or(region.upper[j], |l| region.upper[j].max(l + width))
                        }),
                    )
                };
                Interval::new(lower as f32, upper as f32)
            });
            let finest = size.map(|s| (s.abs() / 400.0).max(1e-6) as f32);
            if search
                .get_or_insert_with(|| Search::new(shape))
                .holds(slab, finest)
            {
                sides.push(SIDES[2 * i + usize::from(upper)]);
            }
        }
    }
    sides
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::scene::jit;
    use fidget::context::Tree;

    fn fitted(tree: Tree) -> Option<Fitted> {
        fit(&tree, &jit(&tree).expect("compiles"))
    }

    #[test]
    fn fits_a_sphere_from_outside() {
        let (x, y, z) = Tree::axes();
        let sphere = ((x - 1.0).square() + y.square() + z.square()).sqrt() - 2.0;
        let fitted = fitted(sphere).expect("not empty");
        for (i, (lower, upper)) in [(-1.0, 3.0), (-2.0, 2.0), (-2.0, 2.0)]
            .into_iter()
            .enumerate()
        {
            let (l, u) = (
                fitted.lower[i].unwrap_or(f64::NAN),
                fitted.upper[i].unwrap_or(f64::NAN),
            );
            assert!(l <= lower && l > lower - 0.05, "{fitted:?}");
            assert!(u >= upper && u < upper + 0.05, "{fitted:?}");
        }
    }

    #[test]
    fn leaves_unused_axes_unbounded() {
        let (x, y, _) = Tree::axes();
        let circle = (x.square() + y.square()).sqrt() - 1.0;
        let fitted = fitted(circle).expect("not empty");
        assert_eq!((fitted.lower[2], fitted.upper[2]), (None, None));
        assert!(
            fitted.upper[0].is_some_and(|u| (1.0..1.05).contains(&u)),
            "{fitted:?}"
        );
    }

    /// A square turned by a whole turn and a half as it rises: in X and Y
    /// its intervals stay loose however finely they are split, but the
    /// radius it reaches bounds it.
    #[test]
    fn fits_a_twist_by_its_radius() {
        let (x, y, z) = Tree::axes();
        let a = z.clone() * 0.25;
        let (c, s) = (a.clone().cos(), a.sin());
        let u = x.clone() * c.clone() + y.clone() * s.clone();
        let v = y * c - x * s;
        let square = (u.abs() - 3.0).max(v.abs() - 3.0);
        let twisted = square.max(z.clone().abs() - 20.0);
        let fitted = fitted(twisted).expect("not empty");
        // The square's corners are 3 √2 from the axis.
        let corner = 3.0 * std::f64::consts::SQRT_2;
        for i in 0..2 {
            let lower = fitted.lower[i].unwrap_or(f64::NAN);
            let upper = fitted.upper[i].unwrap_or(f64::NAN);
            assert!(lower <= -corner && lower > -1.5 * corner, "{fitted:?}");
            assert!(upper >= corner && upper < 1.5 * corner, "{fitted:?}");
        }
    }

    #[test]
    fn finds_nothing_in_an_empty_shape() {
        assert_eq!(fitted(Tree::constant(1.0)), None);
    }

    #[test]
    fn only_shapes_found_past_a_side_reach_out() {
        let (x, y, z) = Tree::axes();
        let sphere = |cx: f32| ((x.clone() - cx).square() + y.square() + z.square()).sqrt() - 1.0;
        let region = Box3 {
            lower: [-1.05; 3],
            upper: [1.05; 3],
        };
        let sides = |tree: Tree| {
            let shape = jit(&tree).expect("compiles");
            sides_outside(&shape, &fit(&tree, &shape).expect("not empty"), &region)
        };
        // sin² + cos² is 1, but intervals see it as up to 2, so the bounds
        // fitted to this unit sphere reach well past the region.
        let x50 = x.clone() * 50.0;
        let loose = sphere(0.0) + (x50.clone().sin().square() + x50.cos().square() - 1.0) * 0.5;
        let fitted = fit(&loose, &jit(&loose).expect("compiles")).expect("not empty");
        assert!(fitted.upper[1].is_some_and(|u| u > 1.2), "{fitted:?}");
        assert!(sides(loose).is_empty());
        assert_eq!(sides(sphere(0.5)), ["+x"]);
    }

    #[test]
    fn regions_reach_over_unbounded_axes() {
        let fitted = Fitted {
            lower: [Some(-1.0), None, Some(0.0)],
            upper: [Some(1.0), None, None],
        };
        let (region, used) = region(BoundsChoice::Script, None, Some(fitted));
        assert_eq!(used, BoundsChoice::Fitted);
        let widest = region.size()[0];
        assert!((region.lower[1] + widest / 2.0).abs() < 1e-9, "{region:?}");
        assert!(
            (region.upper[2] - region.lower[2] - widest).abs() < 1e-9,
            "{region:?}"
        );
    }
}
