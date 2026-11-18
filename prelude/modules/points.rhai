// SPDX-License-Identifier: MPL-2.0
//
// keycap module: arithmetic on lists of points.
//
// kind: math
//
//     import "keycap/points" as points;
//
// Points in, points out: the corners of a polygon moved, turned, mirrored,
// offset or combined, worked out when the script runs.  They make no
// field; `polygon`, `rounded_polygon`, `stroke` and `capsule` make one
// from the result.  A shape built from points costs far more than a
// primitive, so these are for outlines measured or traced, and for an
// outline that must be rounded exactly after it is combined.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.

// --- Point lists ---

/// regular_polygon(n: number, r: number): Vec2[]
///
/// The corners of `regular_polygon(n, r)`, anticlockwise from the one on +X.
///
/// - `n`: the number of sides, 3 or more
/// - `r`: the circumradius, from the centre to a corner
///
/// See also: `regular_polygon`, `points::star`, `rounded_polygon`.
///
/// Example: the corners of a square standing on one corner, 10 from the centre.
/// ```
/// points::regular_polygon(4, 10)
/// ```
/// Example: a flange with six bolt holes, one at each corner of a hexagon.
/// ```
/// let holes = points::regular_polygon(6, 22)
///     .map(|p| circle(2).move(p));
/// circle(30).difference(union(holes))
/// ```
fn regular_polygon(n, r) {
    _points_regular_polygon(n, r)
}

private fn _points_regular_polygon(n, r) {
    if type_of(n) != "i64" || n < 3 {
        throw `points::regular_polygon: n must be an integer of at least 3, got ${n}`;
    }
    let r = _num(r, "points::regular_polygon: r");
    let out = [];
    for i in 0..n {
        let a = 360.0 * i / n;
        out.push([r * cosd(a), r * sind(a)]);
    }
    out
}

/// star(n: number, r: [number, number]): Vec2[]
///
/// The corners of `star(n, r)`, anticlockwise from the point on +X, points and inner corners in turn.
///
/// - `n`: the number of points, 2 or more
/// - `r`: `[outer, inner]`, the radius of the points and that of the inner corners
///
/// See also: `star`, `points::regular_polygon`, `points::union`.
///
/// Example: the corners of a star of 2 points, a rhombus.
/// ```
/// points::star(2, [10, 5])
/// ```
fn star(n, r) {
    _points_star(n, r)
}

private fn _points_star(n, r) {
    if type_of(n) != "i64" || n < 2 {
        throw `points::star: n must be an integer of at least 2, got ${n}`;
    }
    let r = _pair(r, "points::star: r");
    let ro = _num(r[0], "points::star: r");
    let ri = _num(r[1], "points::star: r");
    let out = [];
    for i in 0..n {
        let a = 360.0 * i / n;
        let b = a + 180.0 / n;
        out.push([ro * cosd(a), ro * sind(a)]);
        out.push([ri * cosd(b), ri * sind(b)]);
    }
    out
}

/// bezier(points: Vec2[] | Vec3[], n: number): Vec2[] | Vec3[]
///
/// Points along a Bézier curve, for an outline that follows the curve.
///
/// - `points`: the control points, 2D or 3D, as for `bezier_point`
/// - `n`: the number of steps, 1 or more
///
/// There are `n + 1` points, at evenly spaced values of the curve's parameter `t`, from the first control point to the last.
/// They are not evenly spaced along the curve.
///
/// Notes:
/// - A `polygon` through them has straight edges, so it is only as smooth as `n` makes it.
///
/// See also: `bezier_point`, `bezier_stroke`, `polygon`.
///
/// References:
/// - [Bézier curve, Wikipedia](https://en.wikipedia.org/wiki/B%C3%A9zier_curve)
///
/// From OpenSCAD: `bezier3(points, n)` is `points::bezier(points, n)`.
///
/// Example: the points of a curve from three control points, in two steps.
/// ```
/// points::bezier([[0, 0], [10, 20], [20, 0]], 2)
/// ```
/// Example: a fin with a curved back, its outline a curve closed by a straight base.
/// ```
/// let curve = [[0, 0], [5, 30], [30, 25], [40, 0]];
/// polygon(points::bezier(curve, 24))
/// ```
fn bezier(points, n) {
    _points_bezier(points, n)
}

private fn _points_bezier(points, n) {
    if type_of(n) != "i64" || n < 1 {
        throw `points::bezier: n must be an integer of at least 1, got ${n}`;
    }
    let out = [];
    for i in 0..=n {
        out.push(bezier_point(points, i.to_float() / n));
    }
    out
}

// --- Moving and turning ---

/// move(points: Outline, v: Vec2 | Vec3): Outline
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | Vec3 | [number, number, #{ arc?: number, round?: number }]
///
/// Points moved by a vector.
///
/// - `points`: the points, 2D or 3D; or a list of such lists, the loops of an outline, as `points::union` gives them
/// - `v`: the move; a 2D `v` moves 3D points along X and Y only
///
/// See also: `move`, `points::rotate`, `points::scale`.
///
/// Example: two points moved 10 along X.
/// ```
/// points::move([[0, 0], [1, 2]], [10, 0])
/// ```
fn move(points, v) {
    _points_move(points, v)
}

private fn _points_move(points, v) {
    let v = _array(v, "points::move: v");
    _points_each(points, "points::move", |p| {
        let q = p;
        for i in 0..min(p.len(), v.len()) {
            if _is_number(q[i]) {
                q[i] += v[i];
            }
        }
        q
    })
}

/// rotate(points: Outline, angle: number): Outline
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | Vec3 | [number, number, #{ arc?: number, round?: number }]
///
/// Points turned about the Z axis, as `rotate_z` turns shapes.
///
/// - `points`: the points, 2D or 3D; or a list of such lists, the loops of an outline, as `points::union` gives them
/// - `angle`: the turn, in degrees, anticlockwise looking down
///
/// See also: `rotate_z`, `points::move`, `points::scale`.
///
/// Example: a point on +X turned a quarter turn.
/// ```
/// points::rotate([[10, 0]], 90)
/// ```
fn rotate(points, angle) {
    _points_rotate(points, angle)
}

private fn _points_rotate(points, angle) {
    let a = _num(angle, "points::rotate: angle");
    let c = cosd(a);
    let s = sind(a);
    _points_each(points, "points::rotate", |p| {
        let q = p;
        q[0] = p[0] * c - p[1] * s;
        q[1] = p[0] * s + p[1] * c;
        q
    })
}

/// scale(points: Outline, s: number | Vec2 | Vec3): Outline
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | Vec3 | [number, number, #{ arc?: number, round?: number }]
///
/// Points scaled about the origin.
///
/// - `points`: the points, 2D or 3D; or a list of such lists, the loops of an outline, as `points::union` gives them
/// - `s`: one factor for every axis, or one for each
///
/// A polygon through scaled points keeps an exact field.
/// `scale` on the polygon itself leaves only a bound when it scales the axes differently.
/// Arcs and corners' own radii in a map scale with X and Y, which must then scale alike.
///
/// Notes:
/// - A negative factor mirrors the points and keeps their order, so an outline through them goes round the other way; `points::mirror` keeps it going the same way.
///
/// See also: `scale`, `points::move`, `points::mirror`.
///
/// From OpenSCAD: `scale([2, 1]) polygon(points)` is `polygon(points::scale(points, [2, 1]))`.
///
/// Example: two points stretched to twice their distance along X.
/// ```
/// points::scale([[1, 1], [2, -1]], [2, 1])
/// ```
fn scale(points, s) {
    _points_scale(points, s)
}

private fn _points_scale(points, s) {
    let what = "points::scale";
    let s = if _is_number(s) { [s.to_float(), s.to_float(), s.to_float()] } else { _array(s, `${what}: s`) };
    let sx = s[0];
    let sy = if s.len() > 1 { s[1] } else { 1.0 };
    _points_each(points, what, |p| {
        let q = p;
        for i in 0..min(p.len(), s.len()) {
            if _is_number(q[i]) {
                q[i] *= s[i];
            }
        }
        if p.len() == 3 && type_of(p[2]) == "map" {
            if abs(sx) != abs(sy) {
                throw `${what}: an arc or a corner's radius at ${p} cannot follow X and Y scaled apart, ${s}`;
            }
            if "arc" in q[2] {
                q[2].arc *= if sx * sy < 0.0 { -abs(sx) } else { abs(sx) };
            }
            if "round" in q[2] {
                q[2].round *= abs(sx);
            }
        }
        q
    })
}

/// mirror(points: Outline, line: "x" | "y" | [Vec2, Vec2]): Outline
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | Vec3 | [number, number, number] | [number, number, #{ arc?: number, round?: number }]
///
/// Points mirrored across a line, in reverse order, so that an outline through them goes round the same way.
///
/// - `points`: the points, 2D or 3D; or a list of such lists, the loops of an outline, as `polygon` takes them
/// - `line`: `"x"` mirrors across X, negating each X; `"y"` across Y; `[a, b]` across the line through the points `a` and `b`
///
/// An arc `#{arc: a}` stays on the edge it bends, which now starts from the point after it, and turns the same way relative to the outline.
/// A corner's own radius stays with its point, as does a third coordinate.
///
/// See also: `reflect`, `symmetric_x`, `points::scale`.
///
/// From OpenSCAD: `mirror([1, 0]) polygon(points)` is `polygon(points::mirror(points, "x"))`.
///
/// Example: a symmetric outline, its right half given and its left half mirrored onto it.
/// ```
/// let half = [[0, 0], [15, 0], [10, 20], [0, 25]];
/// polygon(half + points::mirror(half, "x"))
/// ```
/// Example: a tab and its mirror image across the diagonal, a bulging end on each.
/// ```
/// let tab = [[2, 0], [12, 0, #{arc: 3}], [12, 4], [2, 4]];
/// union(rounded_polygon(tab, 0.5), rounded_polygon(points::mirror(tab, [[0, 0], [1, 1]]), 0.5))
/// ```
fn mirror(points, line) {
    _points_mirror(points, line)
}

private fn _points_mirror(points, line) {
    let what = "points::mirror";
    let line = if type_of(line) == "string" && line == "x" {
        [[0.0, 0.0], [0.0, 1.0]]
    } else if type_of(line) == "string" && line == "y" {
        [[0.0, 0.0], [1.0, 0.0]]
    } else if type_of(line) == "array" && line.len() == 2 {
        [_vec2(line[0], `${what}: line`), _vec2(line[1], `${what}: line`)]
    } else {
        throw `${what}: line must be "x", "y" or two points [a, b], got ${line}`;
    };
    let o = line[0];
    let d = [line[1][0] - o[0], line[1][1] - o[1]];
    if d[0] == 0.0 && d[1] == 0.0 {
        throw `${what}: the line's two points are the same point, ${o}`;
    }
    let several = _points_several(points, what);
    let loops = (if several { points } else { [points] }).map(|ring| _points_mirror_loop(ring, o, d, what));
    if several { loops } else { loops[0] }
}

// A loop mirrored across the line through `o` along `d`, last point
// first.  Mirroring and reversing each turn an arc the other way, so it
// keeps its sign, and moves to the point its edge now starts from; a
// point keeps its own radius, which an arc moving to it puts in the map
// as `round`.
private fn _points_mirror_loop(ring, o, d, what) {
    if type_of(ring) != "array" {
        throw `${what}: a loop must be an array of points, got ${ring}`;
    }
    let n = ring.len();
    let out = [];
    for j in 0..n {
        let p = ring[n - 1 - j];
        let before = ring[(2 * n - 2 - j) % n];
        let third = if type_of(p) == "array" && p.len() == 3 { p[2] } else if type_of(p) == "Vec3" { p.z } else { () };
        let at = _vec2(if type_of(p) == "array" && p.len() == 3 { [p[0], p[1]] } else { p }, `${what}: a point`);
        let t = 2.0 * ((at[0] - o[0]) * d[0] + (at[1] - o[1]) * d[1]) / (d[0] * d[0] + d[1] * d[1]);
        let q = [2.0 * o[0] + t * d[0] - at[0], 2.0 * o[1] + t * d[1] - at[1]];
        let arc = if type_of(before) == "array" && before.len() == 3 && type_of(before[2]) == "map" { _opt(before[2], "arc", ()) } else { () };
        if type_of(arc) != "()" || type_of(third) == "map" {
            let m = #{};
            if type_of(arc) != "()" {
                m.arc = arc;
            }
            let k = if type_of(third) == "map" { _opt(third, "round", ()) } else { third };
            if type_of(k) != "()" {
                m.round = k;
            }
            out.push(if m.is_empty() { q } else { q + [m] });
        } else if type_of(third) != "()" {
            out.push(q + [third]);
        } else {
            out.push(q);
        }
    }
    out
}

// Whether `points` is a list of loops rather than one list of points.
private fn _points_several(points, what) {
    if type_of(points) != "array" {
        throw `${what}: points must be an array of points, got ${type_of(points)}`;
    }
    !points.is_empty() && type_of(points[0]) == "array" && !points[0].is_empty() && type_of(points[0][0]) == "array"
}

// The points of a list, or of a list of loops, each through `f` as an
// array of floats, a map of an arc and a radius kept as it is.
private fn _points_each(points, what, f) {
    if _points_several(points, what) {
        return points.map(|ring| _points_each(ring, what, f));
    }
    points.map(|p| {
        let q = if type_of(p) == "array" && p.len() == 3 && type_of(p[2]) == "map" {
            _vec2([p[0], p[1]], `${what}: a point`) + [p[2]]
        } else {
            _array(p, `${what}: a point`)
        };
        f.call(q)
    })
}

// --- Offsets ---

/// miter_offset(points: Vec2[], d: number): Vec2[]
///
/// The corners of a polygon moved so that its edges move outwards by `d` and its corners stay sharp.
///
/// - `points`: the corners, each `[x, y]`, as in `polygon`, either way round
/// - `d`: the distance; a negative one moves the edges inwards
///
/// Every edge moves `d` along its outward normal, and each corner goes to where its two edges now meet.
///
/// Notes:
/// - A sharp corner moves further than `d`, by `d / sin(a / 2)` for a corner of angle `a`.
/// - A `d` large enough to make an edge vanish leaves a polygon that crosses itself.
///
/// See also: `offset`, `polygon`, `points::union`.
///
/// References:
/// - [Parallel curve, Wikipedia](https://en.wikipedia.org/wiki/Parallel_curve)
///
/// From OpenSCAD: `offset(delta = d) polygon(points)` is `polygon(points::miter_offset(points, d))`.
///
/// Example: a pocket 0.3 mm larger than a triangular part all round, its corners still sharp.
/// ```
/// let tri = [[-10, -8], [12, -8], [-10, 8]];
/// rect([40, 30]).difference(polygon(points::miter_offset(tri, 0.3)))
/// ```
fn miter_offset(points, d) {
    _points_miter_offset(points, d)
}

private fn _points_miter_offset(points, d) {
    let d = _num(d, "points::miter_offset: d");
    let v = [];
    for p in points {
        v.push(_vec2(p, "points::miter_offset: a point"));
    }
    let n = v.len();
    // Twice the signed area: positive when the points run anticlockwise.
    let area = 0.0;
    for i in 0..n {
        let a = v[i];
        let b = v[(i + 1) % n];
        area += a[0] * b[1] - b[0] * a[1];
    }
    if area < 0.0 {
        d = -d;
    }
    let normals = [];
    for i in 0..n {
        let a = v[i];
        let b = v[(i + 1) % n];
        let ex = b[0] - a[0];
        let ey = b[1] - a[1];
        let l = sqrt(ex * ex + ey * ey);
        normals.push([ey / l, -ex / l]);
    }
    let out = [];
    for i in 0..n {
        let n1 = normals[(i + n - 1) % n];
        let n2 = normals[i];
        let k = d / (1.0 + n1[0] * n2[0] + n1[1] * n2[1]);
        out.push([v[i][0] + (n1[0] + n2[0]) * k, v[i][1] + (n1[1] + n2[1]) * k]);
    }
    out
}

// --- Combinations ---

/// union(a: Outline, b: Outline): Point[][]
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | [number, number, #{ arc: number }]
///
/// The union of two outlines, as new points.
///
/// - `a`, `b`: the outlines, each a list of points as `polygon` takes them, either way round, or a list of such lists for an outline of several parts or with holes
///
/// The result is a list of loops, anticlockwise round each part and clockwise round each hole.
/// `polygon`, `rounded_polygon` and the combinations here take it as it is.
/// An edge that is an arc stays one, `[x, y, #{arc: r}]` as in `rounded_polygon`.
/// Outlines that share an edge leave no seam there: two squares side by side make one rectangle.
///
/// Shapes combined with `union` have a field that is only a bound inside, where they overlap.
/// A polygon through the result's points has an exact field instead, so its offsets come out right, and `rounded_polygon` can round the corners where the outlines meet.
/// Combine shapes, not points, unless the result is to be rounded or offset so.
///
/// Each edge is cut where the other outline meets it.
/// A piece is kept by whether its middle lies inside the other outline, outside it, or along one of its edges.
/// The kept pieces are then joined into loops.
///
/// Notes:
/// - The points are exact to about a millionth of the outlines' size.
/// - The outlines must not cross themselves.
/// - Parts that meet at a single point come out as loops of their own.
/// - About `n * m` steps for outlines of `n` and `m` edges, when the script runs.
///
/// See also: `points::intersection`, `points::difference`, `union`, `rounded_polygon`.
///
/// References:
/// - [Boolean operations on polygons, Wikipedia](https://en.wikipedia.org/wiki/Boolean_operations_on_polygons)
/// - [Greiner-Hormann clipping algorithm, Wikipedia](https://en.wikipedia.org/wiki/Greiner%E2%80%93Hormann_clipping_algorithm), a related method
///
/// From OpenSCAD: `union() { polygon(a); polygon(b); }` is `polygon(points::union(a, b))`.
///
/// Example: an L of two bars, its inner corner rounded by 3.
/// ```
/// let bar = [[0, 0], [40, 0], [40, 10], [0, 10]];
/// let upright = [[0, 0], [10, 0], [10, 30], [0, 30]];
/// rounded_polygon(points::union(bar, upright), 1, #{concave: 3})
/// ```
fn union(a, b) {
    _polygon_clip(a, b, "union", "points::union")
}

/// intersection(a: Outline, b: Outline): Point[][]
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | [number, number, #{ arc: number }]
///
/// The intersection of two outlines, as new points.
///
/// - `a`, `b`: the outlines, as for `points::union`
///
/// The result is as for `points::union`: loops that `polygon` and `rounded_polygon` take as they are, and an empty list when the outlines do not overlap.
///
/// Notes:
/// - About `n * m` steps for outlines of `n` and `m` edges, when the script runs.
///
/// See also: `points::union`, `points::difference`, `intersection`.
///
/// From OpenSCAD: `intersection() { polygon(a); polygon(b); }` is `polygon(points::intersection(a, b))`.
///
/// Example: a lens where two discs overlap, each a loop of two half circles, its tips rounded.
/// ```
/// let disc = [[6, -10, #{arc: 10}], [6, 10, #{arc: 10}]];
/// rounded_polygon(points::intersection(disc, points::mirror(disc, "x")), 1)
/// ```
fn intersection(a, b) {
    _polygon_clip(a, b, "intersection", "points::intersection")
}

/// difference(a: Outline, b: Outline): Point[][]
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | [number, number, #{ arc: number }]
///
/// The outline `a` without `b`, as new points.
///
/// - `a`: the outline to cut from, as for `points::union`
/// - `b`: the outline to cut away
///
/// The result is as for `points::union`; a `b` inside `a` leaves a hole, a loop of its own.
///
/// Notes:
/// - About `n * m` steps for outlines of `n` and `m` edges, when the script runs.
///
/// See also: `points::union`, `points::intersection`, `difference`.
///
/// From OpenSCAD: `difference() { polygon(a); polygon(b); }` is `polygon(points::difference(a, b))`.
///
/// Example: a plate with a round notch, its corners then rounded, the notch's too.
/// ```
/// let plate = [[-20, -10], [20, -10], [20, 10], [-20, 10]];
/// let notch = [[8, 10, #{arc: 8}], [-8, 10, #{arc: 8}]];
/// rounded_polygon(points::difference(plate, notch), 2)
/// ```
fn difference(a, b) {
    _polygon_clip(a, b, "difference", "points::difference")
}
