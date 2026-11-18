// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: Bézier curves and splines.
//
// kind: 2d
//
// A point on a curve is plain arithmetic on numbers; a stroke along one is a
// field, whose nearest point on the curve Newton's method finds inside the
// tree, a fixed number of steps from where the point projects onto the
// chord.  A curve read as a graph finds its point the same way.

// --- Points ---

/// bezier_point(points: Vec2[] | Vec3[] | number[], t: Tree): Vec2 | Vec3 | Tree
///
/// The point at `t` along a Bézier curve.
///
/// - `points`: the control points, at least two: `[x, y]`, `[x, y, z]`, or plain numbers
/// - `t`: from 0 at the first point to 1 at the last
///
/// Two points make a line, three a quadratic curve, four a cubic, and so on.
/// The curve starts at the first point and ends at the last; the points between pull it towards them.
///
/// The result has as many components as the control points.
/// Plain numbers make a value that runs from the first to the last, eased along the curve.
/// A tree `t`, such as `z / 40`, gives trees: a point or a value that changes with height.
///
/// See also: `bezier_graph`, `bezier_stroke`, `catmull_rom`.
///
/// References:
/// - [Bézier curve, Wikipedia](https://en.wikipedia.org/wiki/B%C3%A9zier_curve)
/// - Pomax, [A Primer on Bézier Curves](https://pomax.github.io/bezierinfo/)
/// - [De Casteljau's algorithm, Wikipedia](https://en.wikipedia.org/wiki/De_Casteljau%27s_algorithm), which works the point out
///
/// Example: five holes along a curve, cut from a plate.
/// ```
/// let curve = [[-25, -10], [-10, 25], [10, -25], [25, 10]];
/// let holes = [0, 1, 2, 3, 4]
///     .map(|i| circle(2).move(bezier_point(curve, i / 4.0)));
/// rect([64, 40]).difference(union(holes))
/// ```
/// Example: a vase whose radius follows a Bézier curve of numbers. [view: camera front]
/// ```
/// let r = bezier_point([10, 25, 5, 12], z / 40);
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn bezier_point(points, t) {
    let t = _field(t, "bezier_point: t");
    if type_of(points) == "array" && points.len() > 0 && points.all(|q| _is_number(q)) {
        if points.len() < 2 {
            throw `bezier_point: needs at least 2 points, got ${points.len()}`;
        }
        let q = _casteljau(points.map(|v| [_float(v)]), t)[0];
        return q[q.len() - 1][0];
    }
    let p = [];
    for q in points {
        p.push(_vec3(q, "bezier_point: a point", 0.0));
    }
    if p.len() < 2 {
        throw `bezier_point: needs at least 2 points, got ${p.len()}`;
    }
    let two = points.all(|q| type_of(q) == "Vec2" || (type_of(q) == "array" && q.len() == 2));
    let dims = if two { 2 } else { 3 };
    let q = _casteljau(p, t)[0];
    let last = q[q.len() - 1];
    last.extract(0, dims)
}

/// bezier_integral(points: number[]): number[]
///
/// The control values of a Bézier curve's running total: `bezier_point(bezier_integral(points), t)` is the area under `bezier_point(points, s)` from `s` = 0 to `t`.
///
/// - `points`: the curve's control values, numbers, at least two
///
/// For a rate drawn as a curve whose total is what a field needs: layers that each turn by a curve's value turn, at a height, by the integral.
/// A curve of degree n integrates to one of degree n + 1, whose values start at 0 and each add the curve's next value over n + 1.
///
/// See also: `bezier_point`, `extrude`.
///
/// References:
/// - [Bézier curve, Wikipedia](https://en.wikipedia.org/wiki/B%C3%A9zier_curve)
///
/// Example: the integral of a constant rate of 2, the line 2 t.
/// ```
/// bezier_integral([2, 2])
/// ```
/// Example: a square that turns slowly, then fast, then slowly again, its rate of turn a Bézier curve.
/// ```
/// let twist = |t| bezier_point(bezier_integral([0, 180, 0]), t);
/// rect(20).extrude([0, 40], #{twist: twist})
/// ```
fn bezier_integral(points) {
    if type_of(points) != "array" || points.len() < 2 || !points.all(|v| _is_number(v)) {
        throw `bezier_integral: points must be at least two numbers, got ${points}`;
    }
    let n = points.len().to_float();
    let out = [0.0];
    for v in points {
        out.push(out[out.len() - 1] + v.to_float() / n);
    }
    out
}

/// bezier_graph(points: Vec2[], v: Tree): Tree
///
/// The height of a 2D Bézier curve at `v` along X: a value along a part, drawn as a curve.
///
/// - `points`: the control points `[x, y]`, at least two; the curve must run to the right all along, as it does when their `x` never decreases
/// - `v`: where to read the curve, such as `z`
///
/// The curve is read as a graph of `y` against `x`, as a curve editor draws it.
/// Before the first point it holds the first `y`, past the last point the last.
/// It suits a twist or a scale over height, or a vase's profile.
///
/// `bezier_point` of numbers moves along the curve's own parameter instead, which does not run evenly along X.
/// The `cubic-bezier(x1, y1, x2, y2)` easing of CSS, Cascading Style Sheets, is `bezier_graph([[0, 0], [x1, y1], [x2, y2], [1, 1]], t)`.
///
/// Notes:
/// - Accuracy: the curve's parameter at `v` comes from five steps of Newton's method, from the chord.
///   It is within a millionth of the range of heights, or a ten-thousandth where an end of the curve runs square to X, as CSS's `ease-in` does.
/// - About 90 operations for a cubic curve.
///
/// See also: `bezier_point`, `keyframes`.
///
/// References:
/// - [Bézier curve, Wikipedia](https://en.wikipedia.org/wiki/B%C3%A9zier_curve)
/// - [CSS easing functions, MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/CSS/easing-function)
/// - [Newton's method, Wikipedia](https://en.wikipedia.org/wiki/Newton%27s_method)
///
/// Example: a vase whose radius is drawn as a curve over its height. [view: camera front]
/// ```
/// let r = bezier_graph([[0, 12], [20, 30], [35, 4], [50, 14]], z);
/// normalize_z(hypot(x, y) - r).intersection(max(-z, z - 50))
/// ```
fn bezier_graph(points, v) {
    let p = [];
    for q in points {
        p.push(_vec2(q, "bezier_graph: a point"));
    }
    if p.len() < 2 {
        throw `bezier_graph: needs at least 2 points, got ${p.len()}`;
    }
    let x0 = p[0][0];
    let x1 = p[p.len() - 1][0];
    let c = _power_basis(p);
    for i in 0..=32 {
        if x1 <= x0 || _bezier_eval(c, i / 32.0)[2] < 0.0 {
            throw `bezier_graph: the curve must run to the right all along, got ${points}`;
        }
    }
    let v = _field(v, "bezier_graph: v");
    let s = clamp((v - x0) / (x1 - x0), 0.0, 1.0);
    for step in 0..5 {
        let e = _bezier_eval(c, s);
        // Where the curve runs straight up, a floor keeps the step finite.
        s = clamp(s - (e[0] - v) / max(e[2], 1e-6 * (x1 - x0)), 0.0, 1.0);
    }
    _bezier_eval(c, s)[1]
}

/// catmull_rom(points: Vec2[]): Vec2[][]
///
/// A smooth curve through `points`, as the cubic Bézier pieces from each point to the next.
///
/// - `points`: the points `[x, y]`, at least two
///
/// At each point, the curve runs parallel to the line between the points on either side.
/// At the two ends, it runs towards their one neighbour.
/// Each piece is four control points, for `bezier_stroke`, `bezier_point` and anything else that takes a Bézier curve.
///
/// Notes:
/// - Worked out when the script runs, from numbers.
/// - The spline is the uniform Catmull-Rom spline, the one `keyframes` uses for `"spline"`.
///
/// See also: `bezier_stroke`, `bezier_point`, `keyframes`.
///
/// References:
/// - [Catmull-Rom spline, Wikipedia](https://en.wikipedia.org/wiki/Cubic_Hermite_spline#Catmull%E2%80%93Rom_spline)
///
/// Example: a smooth stroke through four points.
/// ```
/// let through = [[0, 0], [20, 15], [40, -10], [60, 5]];
/// let pieces = catmull_rom(through);
/// union(pieces.map(|piece| bezier_stroke(piece, 2)))
/// ```
fn catmull_rom(points) {
    let p = [];
    for q in points {
        p.push(_vec2(q, "catmull_rom: a point"));
    }
    if p.len() < 2 {
        throw `catmull_rom: needs at least 2 points, got ${p.len()}`;
    }
    // The tangent at each point, from the points on either side.
    let m = [];
    for i in 0..p.len() {
        let lo = if i > 0 { i - 1 } else { i };
        let hi = if i + 1 < p.len() { i + 1 } else { i };
        let k = 1.0 / (hi - lo);
        m.push([(p[hi][0] - p[lo][0]) * k, (p[hi][1] - p[lo][1]) * k]);
    }
    let pieces = [];
    for i in 1..p.len() {
        let a = p[i - 1];
        let b = p[i];
        pieces.push([
            a,
            [a[0] + m[i - 1][0] / 3.0, a[1] + m[i - 1][1] / 3.0],
            [b[0] - m[i][0] / 3.0, b[1] - m[i][1] / 3.0],
            b,
        ]);
    }
    pieces
}

// --- Strokes ---

/// bezier_stroke(points: Vec2[], width: number | ((t: Tree) => Tree) | Key[]): Shape
///
/// Stroke along a 2D Bézier curve, with round ends.
///
/// - `points`: the control points, at least two
/// - `width`: the stroke's width, a number, a function of `t`, or keyframes in `t`; `t` runs along the curve from 0 to 1
///
/// Two points make a line, three a quadratic curve, four a cubic, and so on.
/// A function of `t` makes a stroke that tapers, such as `|t| lerp(4.0, 1.0, t)`.
/// So do keyframes, such as `[[0, 4], [0.5, 2, "spline"], [1, 1, "spline"]]`.
/// A function must give a number for a number `t`.
///
/// Notes:
/// - Field: exact to a ten-thousandth near the curve.
///   Far from it, on the inside of a bend, it can be larger than the distance, so an offset larger than the curve's radius of curvature goes wrong.
/// - With a tapering width the field is a bound, as long as the width changes slowly.
/// - The curve is split into pieces that turn at most 45 degrees, about 150 operations each.
///   Renders skip the pieces far away, so hundreds of strokes stay quick.
///
/// See also: `catmull_rom`, `bezier_point`, `stroke`.
///
/// References:
/// - [Bézier curve, Wikipedia](https://en.wikipedia.org/wiki/B%C3%A9zier_curve)
/// - Pomax, [A Primer on Bézier Curves](https://pomax.github.io/bezierinfo/)
///
/// Example: an S that tapers from 4 to 1 mm wide.
/// ```
/// let curve = [[0, 0], [20, 30], [40, -30], [60, 0]];
/// bezier_stroke(curve, |t| lerp(4.0, 1.0, t))
/// ```
fn bezier_stroke(points, width) {
    let p = [];
    for q in points {
        p.push(_vec2(q, "bezier_stroke: a point"));
    }
    if p.len() < 2 {
        throw `bezier_stroke: needs at least 2 points, got ${p.len()}`;
    }
    let half = |t| _sched(width, t, "bezier_stroke: width") * 0.5;
    // The widest the stroke gets, for the pieces' boxes.
    let reach = 0.0;
    for i in 0..=32 {
        let h = half.call(i / 32.0);
        if !_is_number(h) {
            throw "bezier_stroke: width must be a number, a function of t that gives a number for a number t, or keyframes in t";
        }
        reach = max(reach, h);
    }
    let parts = [];
    for piece in _bezier_pieces(p, 0.0, 1.0, 0) {
        parts.push(_bezier_piece(piece[0], piece[1], piece[2], half, reach));
    }
    if parts.len() == 1 { parts[0] } else { union(parts) }
}

// --- Internals ---

// The rows of de Casteljau's triangle: the first row is the curve's points,
// the last the single point at t.  Returns [left, right], the control points
// of the curve's halves before and after t.
fn _casteljau(p, t) {
    let row = p;
    let left = [row[0]];
    let right = [row[row.len() - 1]];
    while row.len() > 1 {
        let next = [];
        for i in 0..row.len() - 1 {
            let a = row[i];
            let b = row[i + 1];
            let q = [];
            for k in 0..a.len() {
                q.push(a[k] + (b[k] - a[k]) * t);
            }
            next.push(q);
        }
        row = next;
        left.push(row[0]);
        right.insert(0, row[row.len() - 1]);
    }
    [left, right]
}

// The total turn of a control polygon, in radians; the curve turns no more.
fn _turn(p) {
    let total = 0.0;
    for i in 1..p.len() - 1 {
        let ax = p[i][0] - p[i - 1][0];
        let ay = p[i][1] - p[i - 1][1];
        let bx = p[i + 1][0] - p[i][0];
        let by = p[i + 1][1] - p[i][1];
        if (ax != 0.0 || ay != 0.0) && (bx != 0.0 || by != 0.0) {
            total += atan(ax * by - ay * bx, ax * bx + ay * by).abs();
        }
    }
    total
}

// The curve split in halves until no piece turns more than 45 degrees, as
// [points, t0, t1] with the piece's range of the whole curve's t.
fn _bezier_pieces(p, t0, t1, depth) {
    if depth >= 6 || _turn(p) <= PI / 4.0 {
        return [[p, t0, t1]];
    }
    let halves = _casteljau(p, 0.5);
    let mid = (t0 + t1) * 0.5;
    _bezier_pieces(halves[0], t0, mid, depth + 1) + _bezier_pieces(halves[1], mid, t1, depth + 1)
}

// One piece of a stroke: the curve in the power basis, Newton's method on
// the squared distance from the chord's projection, then the distance to
// the point found, less the half width there.
fn _bezier_piece(p, t0, t1, half, reach) {
    let n = p.len() - 1;
    let c = _power_basis(p);
    let ex = p[n][0] - p[0][0];
    let ey = p[n][1] - p[0][1];
    let ee = ex * ex + ey * ey;
    let s = if ee > 0.0 {
        clamp(((x - p[0][0]) * ex + (y - p[0][1]) * ey) / ee, 0.0, 1.0)
    } else {
        0.5 + 0.0 * x
    };
    for step in 0..3 {
        let v = _bezier_eval(c, s);
        let bx = v[0] - x;
        let by = v[1] - y;
        let f1 = bx * v[2] + by * v[3];
        let speed = v[2] * v[2] + v[3] * v[3];
        // Far on the inside of a bend the second derivative turns negative;
        // a floor keeps the step finite and in the right direction.
        let f2 = max(speed + bx * v[4] + by * v[5], speed * 0.1 + 1e-9);
        s = clamp(s - f1 / f2, 0.0, 1.0);
    }
    let v = _bezier_eval(c, s);
    let d = _hypot(v[0] - x, v[1] - y) - half.call(t0 + (t1 - t0) * s);
    let lo = [p[0][0], p[0][1]];
    let hi = [p[0][0], p[0][1]];
    for q in p {
        lo = [min(lo[0], q[0]), min(lo[1], q[1])];
        hi = [max(hi[0], q[0]), max(hi[1], q[1])];
    }
    max(d, _box_bound([lo[0] - reach, lo[1] - reach], [hi[0] + reach, hi[1] + reach]))
}

// The curve's coefficients in the power basis: c[k] such that the curve is
// the sum of c[k] s^k.
fn _power_basis(p) {
    let n = p.len() - 1;
    let c = [];
    let binom = 1.0;
    for k in 0..=n {
        let cx = 0.0;
        let cy = 0.0;
        let b = 1.0;
        for i in 0..=k {
            let sign = if (k - i) % 2 == 0 { 1.0 } else { -1.0 };
            cx += sign * b * p[i][0];
            cy += sign * b * p[i][1];
            b = b * (k - i) / (i + 1);
        }
        c.push([cx * binom, cy * binom]);
        binom = binom * (n - k) / (k + 1);
    }
    c
}

// The curve, its first and its second derivative at s, by Horner's rule:
// [x, y, dx, dy, ddx, ddy].
fn _bezier_eval(c, s) {
    let n = c.len() - 1;
    let px = c[n][0];
    let py = c[n][1];
    let dx = 0.0;
    let dy = 0.0;
    let ddx = 0.0;
    let ddy = 0.0;
    for k in 1..=n {
        let i = n - k;
        ddx = ddx * s + 2.0 * dx;
        ddy = ddy * s + 2.0 * dy;
        dx = dx * s + px;
        dy = dy * s + py;
        px = px * s + c[i][0];
        py = py * s + c[i][1];
    }
    [px, py, dx, dy, ddx, ddy]
}
