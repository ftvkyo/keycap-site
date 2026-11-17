// SPDX-License-Identifier: MPL-2.0

//! A traced contour as lines and circular arcs within a tolerance of its
//! points: a laser follows an arc as one smooth move, where thousands of
//! short lines slow it down and its software with it.
//!
//! The fit is greedy: from each end it takes the longest line or arc that
//! passes within the tolerance of every point up to its own end, an arc
//! only where it reaches further than a line.  Arcs turn through at most a
//! half turn; a contour that is a whole circle becomes two half circles.

use crate::contour::distance;
use crate::outline::{Contour, Point};

/// The most an arc may turn between two of its points, in radians: past
/// that, its points are too few to tell it from a sharp corner, since an
/// arc fits any three points.
const MAX_STEP: f64 = std::f64::consts::PI / 6.0;

/// How many times closer than the tolerance the lines and arcs of the
/// model itself fit, its points being on its surface.
const STRICT: f64 = 10.0;

/// One piece of a path, from where the one before ended to `to`: a line
/// when `bulge` is 0, otherwise an arc, `bulge` the tangent of a quarter
/// of the angle it turns through, positive counterclockwise, as DXF has
/// it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Segment {
    pub to: Point,
    pub bulge: f64,
}

impl Segment {
    /// The radius of the arc from `from`, infinite for a line.
    pub fn radius(&self, from: Point) -> f64 {
        let chord = distance(from, self.to);
        chord * (1.0 + self.bulge * self.bulge) / (4.0 * self.bulge.abs())
    }
}

/// A closed path: from `start` along its segments, the last of which ends
/// at `start`.
pub struct Path {
    pub start: Point,
    pub segments: Vec<Segment>,
}

/// `contour` as lines and arcs that stray from its points by no more than
/// `tolerance`; a line through every point when that is 0.
pub fn fit(contour: &Contour, tolerance: f64) -> Path {
    let n = contour.len();
    if tolerance == 0.0 {
        let segments = (1..=n).map(|k| Segment {
            to: contour[k % n],
            bulge: 0.0,
        });
        return Path {
            start: contour[0],
            segments: segments.collect(),
        };
    }
    if let Some(centre) = whole_circle(contour, tolerance) {
        let bulge = if crate::contour::area(contour) > 0.0 {
            1.0
        } else {
            -1.0
        };
        let start = contour[0];
        let opposite = [2.0 * centre[0] - start[0], 2.0 * centre[1] - start[1]];
        return Path {
            start,
            segments: vec![
                Segment {
                    to: opposite,
                    bulge,
                },
                Segment { to: start, bulge },
            ],
        };
    }
    // From where the closest segment from the first point ends, a corner or
    // where a line meets an arc, so that the path's last segment does not
    // run on into its first.
    let (first, _) = longest_segment(&|k| contour[k % n], 0, n, tolerance / STRICT);
    let at = |k: usize| contour[(first + k) % n];
    let start = at(0);

    let mut segments = vec![];
    let mut i = 0;
    while i < n {
        let (end, bulge) = segment(&at, i, n, tolerance);
        segments.push(Segment { to: at(end), bulge });
        i = end;
    }
    Path { start, segments }
}

/// The segment from point `i`, ending at point `last` at the furthest: the
/// longest line or arc within `tolerance` of the points it spans, or
/// within [`STRICT`] times less when that reaches nearly as far.  A
/// segment that fits so closely is a line or an arc of the model itself,
/// which then ends where the model's does, rather than strays into the
/// next one as far as the tolerance allows and bends the arc there out of
/// its radius.
fn segment(at: &impl Fn(usize) -> Point, i: usize, last: usize, tolerance: f64) -> (usize, f64) {
    let loose = longest_segment(at, i, last, tolerance);
    let strict = longest_segment(at, i, last, tolerance / STRICT);
    if (strict.0 - i) * 4 >= (loose.0 - i) * 3 {
        strict
    } else {
        loose
    }
}

/// The longest line or arc from point `i`, ending at point `last` at the
/// furthest, that passes within `tolerance` of the points it spans: where
/// it ends, and its bulge.
fn longest_segment(
    at: &impl Fn(usize) -> Point,
    i: usize,
    last: usize,
    tolerance: f64,
) -> (usize, f64) {
    let line = longest(i, last, 1, |e| fits_line(at, i, e, tolerance)).unwrap_or(i + 1);
    let curve = longest(i, last, 2, |e| arc(at, i, e, tolerance).is_some());
    match curve {
        Some(end) if end > line => (end, arc(at, i, end, tolerance).unwrap_or(0.0)),
        _ => (line, 0.0),
    }
}

/// The furthest end from `from + least` to `last` for which `fits` holds,
/// found by steps that double while it does and halve once it does not;
/// `fits` is taken to hold up to some end and fail beyond it.
fn longest(from: usize, last: usize, least: usize, fits: impl Fn(usize) -> bool) -> Option<usize> {
    let mut good = from + least;
    if good > last || !fits(good) {
        return None;
    }
    let mut step = 1;
    loop {
        let next = (good + step).min(last);
        if next == good {
            return Some(good);
        }
        if fits(next) {
            good = next;
            step *= 2;
        } else if step == 1 {
            return Some(good);
        } else {
            step /= 2;
        }
    }
}

/// Whether the line from point `i` to point `e` passes within `tolerance`
/// of the points between them.
fn fits_line(at: &impl Fn(usize) -> Point, i: usize, e: usize, tolerance: f64) -> bool {
    let (a, b) = (at(i), at(e));
    (i + 1..e).all(|k| to_segment(at(k), a, b) <= tolerance)
}

fn to_segment(p: Point, a: Point, b: Point) -> f64 {
    let ab = [b[0] - a[0], b[1] - a[1]];
    let length2 = ab[0] * ab[0] + ab[1] * ab[1];
    if length2 == 0.0 {
        return distance(p, a);
    }
    let t = (((p[0] - a[0]) * ab[0] + (p[1] - a[1]) * ab[1]) / length2).clamp(0.0, 1.0);
    distance(p, [a[0] + ab[0] * t, a[1] + ab[1] * t])
}

/// The bulge of the arc from point `i` through the one halfway to point
/// `e`, when it turns through at most a half turn and passes within
/// `tolerance` of every point between them, on their side of its chord.
fn arc(at: &impl Fn(usize) -> Point, i: usize, e: usize, tolerance: f64) -> Option<f64> {
    let (a, m, b) = (at(i), at((i + e) / 2), at(e));
    let (centre, r) = circle(a, m, b)?;
    let chord = distance(a, b);
    // Which side of the chord the arc is on, and the centre is not, short
    // of a half turn
    let side = |p: Point| (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
    let bulges = side(m);
    if chord == 0.0 || side(centre) * bulges > 0.0 {
        return None;
    }
    let fits = (i + 1..e).all(|k| {
        let p = at(k);
        (distance(p, centre) - r).abs() <= tolerance && side(p) * bulges >= -tolerance * chord
    });
    let step = 2.0 * r * (MAX_STEP / 2.0).sin();
    let fits = fits && (i..e).all(|k| distance(at(k), at(k + 1)) <= step);
    // The arc's height over its chord
    let height = r - (r * r - chord * chord / 4.0).max(0.0).sqrt();
    // A point on the left of the chord makes the arc turn clockwise.
    fits.then(|| -bulges.signum() * 2.0 * height / chord)
}

/// The centre and radius of the circle through `a`, `b` and `c`, unless
/// they are in line; worked out from `a`, for the precision.
fn circle(a: Point, b: Point, c: Point) -> Option<(Point, f64)> {
    let (b, c) = ([b[0] - a[0], b[1] - a[1]], [c[0] - a[0], c[1] - a[1]]);
    let d = 2.0 * (b[0] * c[1] - b[1] * c[0]);
    let scale = (b[0] * b[0] + b[1] * b[1]).max(c[0] * c[0] + c[1] * c[1]);
    if d.abs() <= 1e-12 * scale {
        return None;
    }
    let (b2, c2) = (b[0] * b[0] + b[1] * b[1], c[0] * c[0] + c[1] * c[1]);
    let centre = [(c[1] * b2 - b[1] * c2) / d, (b[0] * c2 - c[0] * b2) / d];
    Some((
        [a[0] + centre[0], a[1] + centre[1]],
        centre[0].hypot(centre[1]),
    ))
}

/// The centre of the circle the whole contour lies on, within
/// `tolerance`, if it does.
fn whole_circle(contour: &Contour, tolerance: f64) -> Option<Point> {
    let n = contour.len();
    if n < 8 {
        return None;
    }
    let (centre, r) = circle(contour[0], contour[n / 3], contour[2 * n / 3])?;
    contour
        .iter()
        .all(|&p| (distance(p, centre) - r).abs() <= tolerance)
        .then_some(centre)
}

#[cfg(test)]
mod test {
    use std::f64::consts::{FRAC_PI_2, TAU};

    use super::*;

    /// `n` points round the arc of radius `r` about `centre` from angle
    /// `from` through `turn`, the last one short of its end.
    fn arc_points(centre: Point, r: f64, from: f64, turn: f64, n: usize) -> Contour {
        (0..n)
            .map(|i| from + turn * i as f64 / n as f64)
            .map(|a| [centre[0] + r * a.cos(), centre[1] + r * a.sin()])
            .collect()
    }

    /// Points `steps` apart along `path`'s segments, which a bulge turns
    /// round its centre.
    fn along(path: &Path, steps: usize) -> Vec<Point> {
        let mut points = vec![];
        let mut from = path.start;
        for segment in &path.segments {
            let to = segment.to;
            for i in 0..steps {
                let u = i as f64 / steps as f64;
                points.push(if segment.bulge == 0.0 {
                    [
                        from[0] + (to[0] - from[0]) * u,
                        from[1] + (to[1] - from[1]) * u,
                    ]
                } else {
                    let r = segment.radius(from);
                    let chord = distance(from, to);
                    let height = segment.bulge * chord / 2.0;
                    let middle = [(from[0] + to[0]) / 2.0, (from[1] + to[1]) / 2.0];
                    // Left of the chord for an arc counterclockwise
                    let left = [(from[1] - to[1]) / chord, (to[0] - from[0]) / chord];
                    let across = segment.bulge.signum() * r - height;
                    let c = [middle[0] + left[0] * across, middle[1] + left[1] * across];
                    let start = (from[1] - c[1]).atan2(from[0] - c[0]);
                    let a = start + 4.0 * segment.bulge.atan() * u;
                    [c[0] + r * a.cos(), c[1] + r * a.sin()]
                });
            }
            from = to;
        }
        points
    }

    /// A whole circle is two half circles, counterclockwise for an outline
    /// and clockwise for a hole.
    #[test]
    fn a_circle_is_two_halves() {
        let mut circle = arc_points([1.0, 2.0], 5.0, 0.3, TAU, 300);
        for bulge in [1.0, -1.0] {
            let path = fit(&circle, 0.01);
            assert_eq!(path.segments.len(), 2);
            let mut from = path.start;
            for segment in &path.segments {
                assert_eq!(segment.bulge, bulge);
                assert!((segment.radius(from) - 5.0).abs() < 1e-9);
                from = segment.to;
            }
            assert_eq!(from, path.start);
            circle.reverse();
        }
    }

    /// A rectangle with round corners is four lines and four quarter
    /// circles.
    #[test]
    fn a_rounded_rectangle_is_lines_and_arcs() {
        let (w, h, r) = (6.0, 4.0, 1.5);
        let mut contour = vec![];
        let corners = [
            [w - r, -h + r],
            [w - r, h - r],
            [-w + r, h - r],
            [-w + r, -h + r],
        ];
        for (i, corner) in corners.into_iter().enumerate() {
            let from = -FRAC_PI_2 + FRAC_PI_2 * i as f64;
            contour.extend(arc_points(corner, r, from, FRAC_PI_2, 40));
            // The side to the next corner
            let next = corners[(i + 1) % 4];
            let end = [
                corner[0] + r * (from + FRAC_PI_2).cos(),
                corner[1] + r * (from + FRAC_PI_2).sin(),
            ];
            let to = [
                next[0] + (end[0] - corner[0]),
                next[1] + (end[1] - corner[1]),
            ];
            for k in 0..50 {
                let u = k as f64 / 50.0;
                contour.push([end[0] + (to[0] - end[0]) * u, end[1] + (to[1] - end[1]) * u]);
            }
        }
        let path = fit(&contour, 1e-3);
        let arcs: Vec<&Segment> = path.segments.iter().filter(|s| s.bulge != 0.0).collect();
        assert_eq!(path.segments.len() - arcs.len(), 4);
        assert_eq!(arcs.len(), 4);
        for s in arcs {
            assert!((s.bulge - (FRAC_PI_2 / 4.0).tan()).abs() < 1e-6, "{s:?}");
        }
    }

    /// An ellipse, which no arc fits exactly, stays within the tolerance
    /// all along its arcs, in far fewer of them than its points.
    #[test]
    fn an_ellipse_stays_within_the_tolerance() {
        let (a, b) = (6.0, 3.0);
        let contour: Contour = arc_points([0.0, 0.0], 1.0, 0.0, TAU, 2000)
            .into_iter()
            .map(|p| [a * p[0], b * p[1]])
            .collect();
        for tolerance in [0.01, 0.001] {
            let path = fit(&contour, tolerance);
            assert!(path.segments.len() < 60, "{}", path.segments.len());
            for p in along(&path, 20) {
                // The distance to the ellipse, to first order
                let f = (p[0] / a).powi(2) + (p[1] / b).powi(2) - 1.0;
                let gradient = (2.0 * p[0] / (a * a)).hypot(2.0 * p[1] / (b * b));
                let off = (f / gradient).abs();
                assert!(off <= tolerance * 1.01, "{p:?} is {off} off");
            }
        }
    }

    #[test]
    fn no_tolerance_keeps_every_point() {
        let contour = arc_points([0.0, 0.0], 2.0, 0.0, TAU, 100);
        let path = fit(&contour, 0.0);
        assert_eq!(path.segments.len(), 100);
        assert!(path.segments.iter().all(|s| s.bulge == 0.0));
    }
}
