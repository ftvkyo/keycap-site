// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: arrays, repetition and recursion.
//
// kind: pattern
//
// The `*_array` functions union real copies: any shape, cost growing with
// the count, and each copy may differ, made by a function of its index.
// The `repeat*` functions fold space so one copy serves every cell: constant
// cost, but each copy must stay inside its cell, and every copy is the
// same.
//
// Spacing comes before the count, and copies start at the original and go
// along `step`, as OpenSCAD loops place them; `#{center: true}` centres
// them on the original instead.

// --- Copies ---

/// linear_array(shape: Shape | ((i: number) => Shape), step: Vec3 | Vec2, n: number, opts: #{ center?: bool } = #{}): Shape
///
/// `n` copies of a shape in a row, `step` apart, the first on the original.
///
/// - `shape`: the shape, or a function that makes copy `i`, an integer from 0
/// - `step`: the offset from each copy to the next, `[dx, dy]` or `[dx, dy, dz]`
/// - `n`: the number of copies
/// - `opts`:
///   - `center`: `true` to centre the row on the original
///
/// With a function, the copies may differ.
/// It makes each copy where the original would be, and the row moves the copy into place.
///
/// Notes:
/// - Field: exact outside; inside too, where the copies do not overlap.
/// - The cost grows with `n`; `repeat_grid` costs one copy, for copies that are all the same.
///
/// See also: `grid_array`, `polar_array`, `arrange_row`, `repeat_grid`.
///
/// Example: a plate with four holes along it, 10 apart.
/// ```
/// let plate = cuboid([45, 12, 3]);
/// let holes = cylinder(1.7, 4)
///     .linear_array([10, 0], 4, #{center: true});
/// plate.difference(holes)
/// ```
/// Example: a test plate of holes that grow by 0.1 mm along the row.
/// ```
/// let plate = cuboid([45, 12, 3]);
/// let holes = linear_array(
///     |i| cylinder(1.5 + 0.05 * i, 4),
///     [10, 0],
///     4,
///     #{center: true}
/// );
/// plate.difference(holes)
/// ```
fn linear_array(shape, step, n, opts) {
    _opts(opts, ["center"], "linear_array");
    let s = _vec3(step, "linear_array: step", 0.0);
    let n = _count(n, "linear_array: n");
    let c = if _opt(opts, "center", false) { (n - 1) * 0.5 } else { 0.0 };
    let out = [];
    for i in 0..n {
        let k = i - c;
        out.push(move(_copy(shape, i), [s[0] * k, s[1] * k, s[2] * k]));
    }
    union(out)
}

// Both `linear_array(shape, step, n)` and the method form
// `shape.linear_array(step, n, opts)`, which Rhai cannot tell apart by
// their number of arguments: as a method, `opts` is the map of options.
fn linear_array(step, n, opts) {
    if type_of(opts) == "map" { linear_array(this, step, n, opts) } else { linear_array(step, n, opts, #{}) }
}

/// grid_array(shape: Shape | ((i: number[]) => Shape), step: Vec3 | Vec2, counts: Vec3 | Vec2, opts: #{ center?: bool } = #{}): Shape
///
/// Copies of a shape on a grid, the first on the original.
///
/// - `shape`: the shape, or a function that makes the copy at `[i, j, k]`, its place along X, Y and Z in integers from 0
/// - `step`: the spacing along each axis, `[dx, dy]` or `[dx, dy, dz]`
/// - `counts`: the number of copies along each axis, `[nx, ny]` or `[nx, ny, nz]`
/// - `opts`:
///   - `center`: `true` to centre the grid on the original
///
/// With a function, the copies may differ, as for `linear_array`.
///
/// Notes:
/// - Field: exact outside; inside too, where the copies do not overlap.
/// - The cost grows with the number of copies; `repeat_grid` costs one copy, for copies that are all the same.
///
/// See also: `linear_array`, `repeat_grid`, `hex_grid`.
///
/// Example: a plate with six holes, three by two.
/// ```
/// let plate = cuboid([50, 30, 3]);
/// let holes = cylinder(1.7, 4)
///     .grid_array([20, 15], [3, 2], #{center: true});
/// plate.difference(holes)
/// ```
fn grid_array(shape, step, counts, opts) {
    _opts(opts, ["center"], "grid_array");
    let s = _vec3(step, "grid_array: step", 0.0);
    let n = _counts(counts, "grid_array: counts");
    let c = if _opt(opts, "center", false) { n.map(|v| (v - 1.0) * 0.5) } else { [0.0, 0.0, 0.0] };
    let out = [];
    for i in 0..n[0].to_int() {
        for j in 0..n[1].to_int() {
            for k in 0..n[2].to_int() {
                let copy = _copy(shape, [i, j, k]);
                out.push(move(copy, [s[0] * (i - c[0]), s[1] * (j - c[1]), s[2] * (k - c[2])]));
            }
        }
    }
    union(out)
}

// Both `grid_array(shape, step, counts)` and the method form; see
// `linear_array`.
fn grid_array(step, counts, opts) {
    if type_of(opts) == "map" { grid_array(this, step, counts, opts) } else { grid_array(step, counts, opts, #{}) }
}

/// polar_array(shape: Shape | ((i: number) => Shape), n: number): Shape
/// polar_array(shape: Shape | ((i: number) => Shape), angle: number, n: number, opts: #{ center?: bool } = #{}): Shape
///
/// `n` copies of a shape turned about the Z axis, evenly round the circle or `angle` degrees apart, the first on the original.
///
/// - `shape`: the shape, usually away from the axis, or a function that makes copy `i`, an integer from 0
/// - `angle`: the turn from each copy to the next, in degrees, anticlockwise looking down; `360 / n` without it
/// - `n`: the number of copies
/// - `opts`:
///   - `center`: `true` to centre the arc of copies on the original
///
/// With a function, the copies may differ, as for `linear_array`.
///
/// Notes:
/// - Field: exact outside; inside too, where the copies do not overlap.
/// - The cost grows with `n`; `repeat_polar` costs one copy, for copies that are all the same.
///
/// See also: `repeat_polar`, `linear_array`, `kaleidoscope`.
///
/// From OpenSCAD: `for (a = [0 : 30 : 359]) rotate(a)` is `polar_array(shape, 12)`.
///
/// Example: a flange with six holes round its centre.
/// ```
/// let ring = cylinder(1.7, 10).move([20, 0]).polar_array(6);
/// cylinder(28, [0, 4])
///     .difference(cylinder(10, 10))
///     .difference(ring)
/// ```
fn polar_array(shape, n) {
    // As a method, `shape.polar_array(angle, n)`: a shape is never a
    // number.
    if _is_number(shape) {
        return polar_array(this, shape, n, #{});
    }
    let n = _count(n, "polar_array: n");
    polar_array(shape, 360.0 / n, n, #{})
}

fn polar_array(shape, angle, n, opts) {
    _opts(opts, ["center"], "polar_array");
    let step = _num(angle, "polar_array: angle");
    let n = _count(n, "polar_array: n");
    let c = if _opt(opts, "center", false) { (n - 1) * 0.5 } else { 0.0 };
    let out = [];
    for i in 0..n {
        out.push(rotate_z(_copy(shape, i), step * (i - c)));
    }
    union(out)
}

// Both `polar_array(shape, angle, n)` and the method form; see
// `linear_array`.
fn polar_array(angle, n, opts) {
    if type_of(opts) == "map" { polar_array(this, angle, n, opts) } else { polar_array(angle, n, opts, #{}) }
}

/// arrange_row(shapes: Shape[], step: Vec3 | Vec2): Shape
///
/// Different shapes in a row, `step` apart, the first where it is.
///
/// - `shapes`: the shapes, each made where the row starts
/// - `step`: the offset from each shape to the next, `[dx, dy]` or `[dx, dy, dz]`
///
/// Notes:
/// - Field: exact outside; inside too, where the shapes do not overlap.
///
/// See also: `linear_array`.
///
/// Example: three parts laid out along X for one print, 15 apart.
/// ```
/// let parts = [cuboid(10), sphere(5), cylinder(5, 10)];
/// arrange_row(parts, [15, 0])
/// ```
fn arrange_row(shapes, step) {
    if type_of(shapes) != "array" || shapes.is_empty() {
        throw `arrange_row: shapes must be a list of shapes, got ${shapes}`;
    }
    let s = _vec3(step, "arrange_row: step", 0.0);
    let out = [];
    for i in 0..shapes.len() {
        out.push(move(_tree(shapes[i]), [s[0] * i, s[1] * i, s[2] * i]));
    }
    union(out)
}

// Copy `i` of an array: the shape, or what the function makes of `i`.
fn _copy(shape, i) {
    if type_of(shape) == "Fn" { _tree(shape.call(i)) } else { _tree(shape) }
}

// --- Repetition ---

/// repeat(shape: Shape, step: Vec3 | Vec2): Shape
///
/// A shape repeated without end on a grid, a copy centred on every multiple of `step`, at the cost of one copy.
///
/// - `shape`: the shape, centred on the origin
/// - `step`: the size of a cell, `[dx, dy]` or `[dx, dy, dz]`
///
/// Space is folded into the cell around the origin, so every cell sees the same copy.
/// To place the grid, move the result, not the shape.
/// A 0 in `step` leaves that axis alone.
/// The repetition is endless: intersect it with something finite.
///
/// Notes:
/// - Field: exact, as long as the shape stays inside its cell with some margin.
/// - Costs one evaluation of the shape, however many copies there are.
///
/// See also: `repeat_grid`, `grid_array`, `hex_grid`, `repeat_x`.
///
/// References:
/// - Inigo Quilez, [Domain repetition](https://iquilezles.org/articles/sdfrepetition/)
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/), `pMod1` and `pMod3`
///
/// Example: a perforated sheet, its holes 5 apart.
/// ```
/// let plate = cuboid([42, 32, 2]);
/// let holes = cylinder(1.5, 3).repeat([5, 5]);
/// plate.difference(holes)
/// ```
fn repeat(shape, step) {
    let s = _vec3(step, "repeat: step", 0.0);
    let p = [x, y, z];
    let q = [];
    for i in 0..3 {
        q.push(if s[i] > 0.0 { p[i] - s[i] * round(p[i] / s[i]) } else { p[i] });
    }
    remap(_tree(shape), q[0], q[1], q[2])
}

/// repeat_grid(shape: Shape, step: Vec3 | Vec2, counts: Vec3 | Vec2, opts: #{ center?: bool } = #{}): Shape
///
/// Copies of a shape on a grid, the first on the original, at the cost of one copy.
///
/// - `shape`: the shape, centred on the origin
/// - `step`: the spacing along each axis, `[dx, dy]` or `[dx, dy, dz]`
/// - `counts`: the number of copies along each axis, `[nx, ny]` or `[nx, ny, nz]`
/// - `opts`:
///   - `center`: `true` to centre the grid on the origin
///
/// It is `repeat` limited to `counts` cells: space is folded into the nearest of them.
/// To place the grid, move the result, not the shape.
/// A 0 in `step` leaves that axis alone.
///
/// Notes:
/// - Field: exact, as long as the shape stays inside its cell with some margin; outside the grid, the distance to the copy in the nearest cell at its edge.
/// - Costs one evaluation of the shape, however many copies there are.
///
/// See also: `grid_array`, `repeat`, `hex_grid`.
///
/// References:
/// - Inigo Quilez, [Domain repetition](https://iquilezles.org/articles/sdfrepetition/), "Limited repetition"
///
/// Example: a plate with 60 holes, ten by six.
/// ```
/// let plate = cuboid([55, 35, 2]);
/// let holes = cylinder(1.5, 3)
///     .repeat_grid([5, 5], [10, 6], #{center: true});
/// plate.difference(holes)
/// ```
fn repeat_grid(shape, step, counts, opts) {
    _opts(opts, ["center"], "repeat_grid");
    let s = _vec3(step, "repeat_grid: step", 0.0);
    let n = _counts(counts, "repeat_grid: counts");
    let centred = _opt(opts, "center", false);
    let p = [x, y, z];
    let q = [];
    for i in 0..3 {
        if s[i] > 0.0 && n[i] > 1.0 {
            let c = if centred { (n[i] - 1.0) * 0.5 } else { 0.0 };
            let k = clamp(round(p[i] / s[i] + c), 0.0, n[i] - 1.0);
            q.push(p[i] - s[i] * (k - c));
        } else {
            q.push(p[i]);
        }
    }
    remap(_tree(shape), q[0], q[1], q[2])
}

// Both `repeat_grid(shape, step, counts)` and the method form; see
// `linear_array`.
fn repeat_grid(step, counts, opts) {
    if type_of(opts) == "map" { repeat_grid(this, step, counts, opts) } else { repeat_grid(step, counts, opts, #{}) }
}

/// repeat_polar(shape: Shape, n: number): Shape
/// repeat_polar(shape: Shape, angle: number, n: number, opts: #{ center?: bool } = #{}): Shape
///
/// `n` copies of a shape turned about the Z axis, evenly round the circle or `angle` degrees apart, the first on the original, at the cost of one copy.
///
/// - `shape`: the shape, centred on the +X axis
/// - `angle`: the turn from each copy to the next, in degrees, anticlockwise looking down; `360 / n` without it
/// - `n`: the number of copies
/// - `opts`:
///   - `center`: `true` to centre the arc of copies on the original
///
/// Space is folded into the wedge around +X, `angle` degrees wide, so every wedge sees the same copy.
///
/// Notes:
/// - Field: exact, as long as the shape stays inside its wedge with some margin; past the ends of an arc, the distance to the end copy within a quarter turn of it, and a bound further round.
/// - Costs one evaluation of the shape, however many copies there are.
/// - Fitted bounds do not see where an arc of copies ends; intersect it with something finite, or set `bounds`.
///
/// See also: `polar_array`, `kaleidoscope`, `repeat`.
///
/// References:
/// - Inigo Quilez, [Domain repetition](https://iquilezles.org/articles/sdfrepetition/), "Rotational and Rectangular Repetition"
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/), `pModPolar`
///
/// Example: a knob with 24 ribs round its side.
/// ```
/// let teeth = cuboid([4, 2, 10]).move([18, 0, 5]).repeat_polar(24);
/// cylinder(18, [0, 10], #{round: [0, 2]}).union(teeth)
/// ```
fn repeat_polar(shape, n) {
    // As a method, `shape.repeat_polar(angle, n)`.
    if _is_number(shape) {
        return repeat_polar(this, shape, n, #{});
    }
    let sector = 2.0 * PI / _count(n, "repeat_polar: n");
    let a = _atan2_narrow(y, x);
    // The clamp changes nothing but tells interval arithmetic the wedge's
    // limits, so fitted bounds see where the copies end.
    let a = clamp(a - sector * round(a / sector), -0.5 * sector, 0.5 * sector);
    let r = _hypot(x, y);
    remap(_tree(shape), r * _cos_poly(a), r * _sin_poly(a), z)
}

fn repeat_polar(shape, angle, n, opts) {
    _opts(opts, ["center"], "repeat_polar");
    let step = _num(angle, "repeat_polar: angle") * (PI / 180.0);
    let n = _count(n, "repeat_polar: n");
    let c = (n - 1) * 0.5;
    // Angles from the arc's middle, so that the arc's ends are as far
    // from atan2's cut, behind it, as they can be.
    let mid = if _opt(opts, "center", false) { 0.0 } else { step * c };
    let a = _atan2_narrow(y * cos(mid) - x * sin(mid), x * cos(mid) + y * sin(mid));
    let k = clamp(round(a / step + c), 0.0, n - 1.0);
    // Past the arc's ends, a point more than a quarter turn from the end
    // copy is turned back to a quarter turn, nearer the copy: the field
    // there stays below the distance, and interval arithmetic sees that
    // the copies lie on one side of the axis.
    let quarter = max(0.5 * PI, 0.5 * abs(step));
    let a = clamp(a - step * (k - c), -quarter, quarter);
    let r = _hypot(x, y);
    remap(_tree(shape), r * _cos_poly(a), r * _sin_poly(a), z)
}

// Both `repeat_polar(shape, angle, n)` and the method form; see
// `linear_array`.
fn repeat_polar(angle, n, opts) {
    if type_of(opts) == "map" { repeat_polar(this, angle, n, opts) } else { repeat_polar(angle, n, opts, #{}) }
}

/// hex_grid(shape: Shape, step: number, opts: #{ rings?: number } = #{}): Shape
///
/// Copies of a shape on a hexagonal lattice, `step` between neighbours, the first on the original, at the cost of one copy.
///
/// - `shape`: the shape, centred on the origin
/// - `step`: the distance between neighbouring copies; rows run along X
/// - `opts`:
///   - `rings`: the number of rings of copies around the original, which end the lattice in a hexagon; endless without it
///
/// Each copy has a hexagonal cell, `step` across its flats, with its corners on ±Y.
/// A copy fills its cell when it is `hexagon_af(step).rotate_z(90)`, "af" for across flats.
/// With `rings: n`, there are 3n(n + 1) + 1 copies.
///
/// Notes:
/// - Field: exact, as long as the shape stays inside its cell with some margin; past the last ring, approx (the distance to a copy on the ring, up to a quarter of `step` more than to the nearest).
/// - Costs one evaluation of the shape, however many copies there are.
///
/// See also: `repeat`, `repeat_grid`, `hexagon_af`.
///
/// References:
/// - [Hexagonal lattice, Wikipedia](https://en.wikipedia.org/wiki/Hexagonal_lattice)
/// - Red Blob Games, [Hexagonal grids](https://www.redblobgames.com/grids/hexagons/), for finding the nearest cell
///
/// Example: a honeycomb of 37 holes in a disc.
/// ```
/// let holes = cylinder(4, 4, #{sides: 6})
///     .hex_grid(10, #{rings: 3});
/// cylinder(25, 3).difference(holes)
/// ```
fn hex_grid(shape, step, opts) {
    _opts(opts, ["rings"], "hex_grid");
    let d = _num(step, "hex_grid: step");
    let h = d * sqrt(3.0) * 0.5;
    // The point in the lattice's own coordinates, along +X and along the
    // neighbour at 60 degrees.
    let v = y / h;
    let u = x / d - v * 0.5;
    if "rings" in opts {
        let n = opts.rings;
        if type_of(n) != "i64" || n < 0 {
            throw `hex_grid: rings must be an integer, 0 or more, got ${n}`;
        }
        if n == 0 {
            return _tree(shape);
        }
        // A point past the last ring is drawn back along its line to the
        // origin, onto the hexagon through the last ring's cells.
        let far = max(abs(u), max(abs(v), abs(u + v)));
        let k = n / max(far, n.to_float());
        u = u * k;
        v = v * k;
    }
    // The nearest cell: each of the three coordinates of a hexagonal
    // lattice rounded, and the one that moved most put back from the other
    // two, so that they still sum to 0.
    let w = -u - v;
    let ru = round(u);
    let rv = round(v);
    let rw = round(w);
    let du = abs(ru - u);
    let dv = abs(rv - v);
    let dw = abs(rw - w);
    let fix_u = _less(dv, du) * _less(dw, du);
    let fix_v = (1.0 - fix_u) * _less(dw, dv);
    let iu = ru + fix_u * (-rv - rw - ru);
    let iv = rv + fix_v * (-ru - rw - rv);
    remap(_tree(shape), x - d * (iu + iv * 0.5), y - h * iv, z)
}

// Both `hex_grid(shape, step)` and the method form; see `linear_array`.
fn hex_grid(step, opts) {
    if type_of(opts) == "map" { hex_grid(this, step, opts) } else { hex_grid(step, opts, #{}) }
}

/// kaleidoscope(shape: Shape, n: number): Shape
///
/// A shape's part in a wedge, mirrored and repeated around the Z axis as a kaleidoscope does, at the cost of one copy.
///
/// - `shape`: the shape; only its part between +X and `180 / n` degrees anticlockwise from it counts
/// - `n`: the number of mirrored pairs, 1 or more
///
/// The wedge is mirrored across X, and the pair repeated `n` times around Z.
/// The result has `n` mirror planes through the Z axis, one of them along X.
/// For a shape that is symmetric across X already, it is `repeat_polar(shape, n)` without the seams between copies.
/// With `n` = 1, it mirrors the shape's +Y half onto -Y, as `symmetric_y`.
///
/// Notes:
/// - Field: exact outside, for a shape in the wedge.
///   Inside, near the wedge's sides, only where the shape reaches past them at least as far as its nearest surface is from them, as for `symmetric_x`.
/// - Costs one evaluation of the shape, however many copies there are.
///
/// See also: `repeat_polar`, `symmetric_y`, `recurse`.
///
/// References:
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/), `pModPolar` and `pMirror`
///
/// Example: a six-fold snowflake from one bar and one branch.
/// ```
/// let spoke = rect([20, 2]).move([10, 0]);
/// let barb = rect([6, 1.5]).rotate_z(60).move([12, 2.5]);
/// union(spoke, barb).kaleidoscope(6)
/// ```
fn kaleidoscope(shape, n) {
    _count(n, "kaleidoscope: n");
    let sector = 2.0 * PI / n;
    let a = _atan2_narrow(y, x);
    // Folded into the wedge from -180 / n to 180 / n degrees, then
    // mirrored into its upper half.  The clamp changes nothing but tells
    // interval arithmetic the wedge's limits.
    let a = clamp(abs(a - sector * round(a / sector)), 0.0, 0.5 * sector);
    let r = _hypot(x, y);
    remap(_tree(shape), r * _cos_poly(a), r * _sin_poly(a), z)
}

// --- Recursion ---

/// recurse(levels: number, f: (level: number, inner: Shape | ()) => Shape): Shape
///
/// A shape built in levels, each from the one inside it, for fractals and nested designs.
///
/// - `levels`: the number of levels, 1 or more
/// - `f`: makes level `level`, an integer from 0 at the innermost, out of `inner`, the level inside it; at level 0, `inner` is `()`
///
/// A Rhai closure cannot call itself, and a script function cannot see the script's `let`s, so `recurse` is the recursion for closures.
/// When a fold such as `kaleidoscope` or `repeat_polar` places the inner level's copies, each level costs one copy of it, however many copies it has.
///
/// Notes:
/// - Field: as `f` makes it, level by level.
///
/// See also: `kaleidoscope`, `repeat_polar`, `repeat`.
///
/// References:
/// - [Koch snowflake, Wikipedia](https://en.wikipedia.org/wiki/Koch_snowflake)
///
/// Example: a Koch snowflake: on the middle of every edge, a triangle a third the size, three levels deep.
/// ```
/// let bumps = recurse(3, |level, inner| {
///     let r = 10.0 / 3.0 ** (2 - level);
///     let t = regular_polygon(3, r).rotate_z(180);
///     if level == 0 { t } else {
///         union(t, inner.move([r * 2.0 / 3.0, 0]).kaleidoscope(6))
///     }
/// });
/// let hub = star(6, [30, 30 / sqrt(3.0)]);
/// union(hub, bumps.move([20, 0]).kaleidoscope(6))
/// ```
fn recurse(levels, f) {
    if type_of(levels) != "i64" || levels < 1 {
        throw `recurse: levels must be a positive integer, got ${levels}`;
    }
    let inner = ();
    for level in 0..levels {
        inner = f.call(level, inner);
    }
    inner
}

// --- Method forms ---

// Rhai calls a script function as a method only through `this`, so each
// function above whose first argument is a shape gets a twin for
// `shape.f(...)`.

fn linear_array(step, n) { linear_array(this, step, n, #{}) }
fn grid_array(step, counts) { grid_array(this, step, counts, #{}) }
fn polar_array(n) { polar_array(this, n) }
fn repeat(step) { repeat(this, step) }
fn repeat_grid(step, counts) { repeat_grid(this, step, counts, #{}) }
fn repeat_polar(n) { repeat_polar(this, n) }
fn hex_grid(step) { hex_grid(this, step, #{}) }
fn kaleidoscope(n) { kaleidoscope(this, n) }
