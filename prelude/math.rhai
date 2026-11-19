// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: math helpers for numbers and trees alike.
//
// kind: math
//
// Functions named with a leading `_` are the prelude's internals, shared by
// its other files.

// --- Argument coercion ---

// Rhai integers divide as integers (`5 / 2` is 2), so dimensions become
// floats before any arithmetic on them.
fn _num(v, what) {
    let t = type_of(v);
    if t == "i64" || t == "f64" {
        v.to_float()
    } else {
        throw `${what} must be a number, got ${t}`;
    }
}

// An integer as a float; a float or a tree as it is.
fn _float(v) {
    if type_of(v) == "i64" { v.to_float() } else { v }
}

// A number (both components), `[x, y]` or `vec2` as a float array.
fn _vec2(v, what) {
    let t = type_of(v);
    if t == "i64" || t == "f64" {
        [v.to_float(), v.to_float()]
    } else if t == "array" && v.len() == 2 {
        [_num(v[0], what), _num(v[1], what)]
    } else if t == "Vec2" || t == "Vec3" {
        [v.x, v.y]
    } else {
        throw `${what} must be a number or [x, y], got ${_got(v)}`;
    }
}

// A number (all components), `[x, y, z]` or `vec3` as a float array; `[x, y]`
// gets `z_default`.
fn _vec3(v, what, z_default) {
    let t = type_of(v);
    if t == "i64" || t == "f64" {
        [v.to_float(), v.to_float(), v.to_float()]
    } else if t == "array" && v.len() == 2 {
        [_num(v[0], what), _num(v[1], what), z_default]
    } else if t == "array" && v.len() == 3 {
        [_num(v[0], what), _num(v[1], what), _num(v[2], what)]
    } else if t == "Vec2" {
        [v.x, v.y, z_default]
    } else if t == "Vec3" {
        [v.x, v.y, v.z]
    } else {
        throw `${what} must be a number, [x, y] or [x, y, z], got ${_got(v)}`;
    }
}

// `v` for an error message: an array as it is, anything else by its type.
fn _got(v) {
    if type_of(v) == "array" { `${v}` } else { type_of(v) }
}

// A number of copies: an integer, 1 or more.
fn _count(n, what) {
    if type_of(n) != "i64" || n < 1 {
        throw `${what} must be a positive integer, got ${n}`;
    }
    n
}

// Numbers of copies along X, Y and Z, `[nx, ny]` or `[nx, ny, nz]` (Z 1)
// or one number for all three, as a float array; each an integer, 1 or
// more.
fn _counts(v, what) {
    let n = _vec3(v, what, 1.0);
    for c in n {
        if c < 1.0 || c.to_int().to_float() != c {
            throw `${what} must be positive integers, got ${v}`;
        }
    }
    n
}

// An array of trees becomes their union, so arithmetic accepts whatever
// fidget's own shapes accept.
fn _tree(v) {
    if type_of(v) == "array" { union(v) } else { v }
}

// A number as a float, or a tree as it is: a value that may vary over
// space.
fn _field(v, what) {
    let t = type_of(v);
    if t == "i64" || t == "f64" {
        v.to_float()
    } else if t == "Tree" {
        v
    } else {
        throw `${what} must be a number or a tree, got ${t}`;
    }
}

// `[a, b]`, two values of one kind (`[outer, inner]`, `[bottom, top]`),
// each a number or a tree.
fn _pair(v, what) {
    if type_of(v) != "array" || v.len() != 2 {
        throw `${what} must be a pair [a, b], got ${v}`;
    }
    [_field(v[0], what), _field(v[1], what)]
}

// --- Options ---

// An option from a map, or its default.
fn _opt(opts, key, fallback) {
    if key in opts { opts[key] } else { fallback }
}

// `opts`, checked to be a map of `known` keys only, so that a misspelt
// option throws instead of doing nothing.
fn _opts(opts, known, what) {
    if type_of(opts) != "map" {
        throw `${what}: options must be a map #{...}, got ${type_of(opts)}`;
    }
    for key in opts.keys() {
        if !known.contains(key) {
            throw `${what}: unknown option ${key}; known: ${known}`;
        }
    }
    opts
}

// `shape` moved so that the point `anchor` of its bounding box, from `lo`
// to `hi` (2D or 3D), lies on the origin.  `anchor` runs from -1 at `lo`
// to 1 at `hi` along each axis, or is a name; `()` leaves the shape where
// it is.
fn _anchor(shape, anchor, lo, hi, what) {
    if type_of(anchor) == "()" {
        return shape;
    }
    let n = lo.len();
    let a = if type_of(anchor) == "string" {
        _anchor_name(anchor, n, what)
    } else if n == 2 {
        _vec2(anchor, `${what}: anchor`)
    } else {
        _vec3(anchor, `${what}: anchor`, 0.0)
    };
    let p = [];
    for i in 0..n {
        if !_is_number(lo[i]) || !_is_number(hi[i]) {
            throw `${what}: an anchor needs the shape's size as numbers, not trees`;
        }
        p.push(-lerp(lo[i], hi[i], (a[i] + 1.0) * 0.5));
    }
    if p.all(|v| v == 0.0) { shape } else { move(shape, p) }
}

// An anchor's name as its point of the bounding box.
fn _anchor_name(name, n, what) {
    let a = switch name {
        "center" => [0.0, 0.0, 0.0],
        "left" => [-1.0, 0.0, 0.0],
        "right" => [1.0, 0.0, 0.0],
        "front" => [0.0, -1.0, 0.0],
        "back" => [0.0, 1.0, 0.0],
        "bottom" => [0.0, 0.0, -1.0],
        "top" => [0.0, 0.0, 1.0],
        _ => throw `${what}: unknown anchor ${name}; known: center, left, right, front, back, bottom, top`,
    };
    if n == 2 && a[2] != 0.0 {
        throw `${what}: a 2D shape has no ${name}; its anchors are center, left, right, front (-Y) and back (+Y)`;
    }
    a.extract(0, n)
}

// --- Values along a part ---

// A `Sched`, a value along a part, as a tree: a number or a tree as they
// are, a function called with `t`, or keyframes `[[at, value], ...]` read
// at `t`.  `t` is the part's own place along it, a tree from 0 to 1, such
// as how far up an extrusion a point is.
fn _sched(v, t, what) {
    let k = type_of(v);
    if k == "i64" || k == "f64" {
        v.to_float()
    } else if k == "Tree" {
        v
    } else if k == "Fn" {
        _float(v.call(t))
    } else if _is_keys(v) {
        keyframes(t, v)
    } else {
        throw `${what} must be a number, a tree, a function of t or keyframes [[t, value], ...], got ${k}`;
    }
}

// Whether `v` is a list of keys for `keyframes`, rather than a pair.
fn _is_keys(v) {
    type_of(v) == "array" && !v.is_empty()
        && v.all(|k| type_of(k) == "array" && k.len() >= 2 && _is_number(k[0]))
}

// A `Height` as `[z0, z1]`: a number is that tall, centred on z = 0; a
// pair spans from its first up to its second.
fn _height(h, what) {
    let k = type_of(h);
    if k == "i64" || k == "f64" {
        let half = h.to_float() * 0.5;
        [-half, half]
    } else if k == "array" && h.len() == 2 {
        let z0 = _num(h[0], what);
        let z1 = _num(h[1], what);
        if z1 <= z0 {
            throw `${what} must go up, from z0 to z1, got [${z0}, ${z1}]`;
        }
        [z0, z1]
    } else {
        throw `${what} must be a height or [z0, z1], got ${h}`;
    }
}

// A rim option (`round`, `chamfer`) as `[bottom, top]`: one `Sched` for
// both rims, or a pair of them.
fn _rim(v, t, what) {
    if _rim_pair(v) {
        [_sched(v[0], t, what), _sched(v[1], t, what)]
    } else {
        let s = _sched(v, t, what);
        [s, s]
    }
}

// Whether a rim option gives the bottom and the top one each.
fn _rim_pair(v) {
    type_of(v) == "array" && v.len() == 2 && !_is_keys(v)
}

// The field that `make` builds with a radius `r` that may vary over space
// (a rounding or a chamfer), kept a distance to first order.
//
// Its gradient is the shapes' part, of length 1 where they meet square,
// plus `gr` times grad r, gr being the field's derivative by the radius:
// so |grad f|^2 = 1 + 2 gr (grad f . grad r) - gr^2 |grad r|^2, with
// grad f . grad r from a second evaluation of the field a step along
// grad r, and grad r from three of r.  Dividing by that leaves the field as
// exact as with a fixed radius.  The cost is the shapes' twice, plus r's
// four times; a number `r` costs nothing more.
//
// `opts.normalize`, true unless the script sets it, turns the correction
// on; a function that takes it says, in its docs: "`normalize: false`
// skips the correction: twice as fast, but offsets and shells of a varying
// rounding come out uneven."  The function checks its own options; this
// only reads the key.
fn _vary(make, r, opts) {
    let f = make.call(r);
    if _is_number(r) || !_opt(opts, "normalize", true) {
        return f;
    }
    // As in `normalize_z`: a smaller step is noisy in 32-bit trees.
    let h = 0.1;
    let gx = (remap(r, x + h, y, z) - r) / h;
    let gy = (remap(r, x, y + h, z) - r) / h;
    let gz = (remap(r, x, y, z + h) - r) / h;
    let gr = (make.call(r + h) - f) / h;
    let along = (remap(f, x + h * gx, y + h * gy, z + h * gz) - f) / h;
    let gg = square(gx) + square(gy) + square(gz);
    // The floor keeps a radius that changes faster than the shapes from
    // dividing by nothing.
    f / sqrt(max(1.0 + 2.0 * gr * along - square(gr) * gg, 0.25))
}

// `_vary` with the correction on, for a function without options.
fn _vary(make, r) {
    _vary(make, r, #{})
}

// --- Choices and gradients ---

// fidget meshes and shades with a field's gradient, so the fields here keep
// one wherever they have a value.  `sqrt`'s derivative at 0 and `atan2`'s
// on the Z axis are NaN, and so is anything computed from them, even times
// 0.  `and` and `or` choose a whole operand, gradient included, so a branch
// that is NaN only where it is not chosen stays out.  `min` and `max`
// choose too, but fidget orders their operands its own way, so either one
// may win a tie: a tie between a field and a constant, on a surface, may
// leave no gradient there.

// 1 where `a < b`, 0 elsewhere: `compare` gives -1, 0 or 1, and `not` maps
// 0 to 1 and everything else to 0.
fn _less(a, b) {
    not(compare(a, b) + 1)
}

fn _is_number(v) {
    let t = type_of(v);
    t == "i64" || t == "f64"
}

// `then` where `a < b`, `otherwise` elsewhere.  Numbers choose with `if`,
// since `compare` takes no numbers; trees with `and`, so the branch not
// chosen may have a NaN gradient, but must keep a finite value for
// interval arithmetic.
fn _select_less(a, b, then, otherwise) {
    if _is_number(a) && _is_number(b) {
        if a < b { then } else { otherwise }
    } else {
        let k = _less(a, b);
        and(k, then) + and(1.0 - k, otherwise)
    }
}

// `sqrt(s)` for an `s` that has a gradient of 0 where it is 0 (a sum of
// squares, for one), with that gradient there instead of NaN: `and` takes
// `s` itself where it is 0.  The same value and interval as `sqrt(s)`.
fn _sqrt(s) {
    if _is_number(s) { sqrt(s) } else { and(s, sqrt(s)) }
}

// `hypot` with a gradient of 0 instead of NaN where it is 0, for lengths
// that are 0 only off the surface: at a centre, or on an axis, where a
// revolved shape's gradient passes through its radius.  On the surface a 0
// gradient breaks the mesher, which works around a NaN one, so the public
// `hypot` keeps `sqrt`'s.
fn _hypot(a, b) {
    let a = _float(a);
    let b = _float(b);
    _sqrt(a * a + b * b)
}

fn _hypot(a, b, c) {
    let a = _float(a);
    let b = _float(b);
    let c = _float(c);
    _sqrt(a * a + b * b + c * c)
}

// `atan2(y, x)` with a gradient of 0 on the Z axis, where it has none.
fn _atan2(y, x) {
    and(x * x + y * y, atan2(y, x))
}

// A bound of the box from `lo` to `hi` (2D, or 3D when both have 3
// components): below the exact field of any shape inside the box, so `max`
// with it changes no value but lets interval arithmetic see that the shape
// ends at the box, where a selection on `compare` hides it.
fn _box_bound(lo, hi) {
    let p = [x, y, z];
    let d = max(lo[0] - x, x - hi[0]);
    for i in 1..lo.len() {
        d = max(d, max(lo[i] - p[i], p[i] - hi[i]));
    }
    d
}

// The exact distance at a corner, from `m`, the largest of the signed
// distances along orthogonal directions that meet there, and `ss`, the sum
// of the squares of their positive parts: `m` where it is not positive,
// `sqrt(ss)` elsewhere, with the value and interval of
// `min(m, 0.0) + sqrt(ss)`.  `sqrt` is chosen only where `ss` is positive,
// and on a face `m` ties with no constant.  Where `ss` underflows to 0,
// `or` falls back to `m`.
fn _corner_of(m, ss) {
    or(and(_less(0.0, m), sqrt(ss)), m)
}

// `_corner_of` for two distances (a box's corner, an extrusion's rim).
fn _corner(a, b) {
    _corner_of(max(a, b), square(max(a, 0.0)) + square(max(b, 0.0)))
}

// The squared distance to a segment of length `el`, from the signed
// distance to its line, `line`, and the nearest point's place along it,
// `t`, 0 and 1 at its ends: the line's square plus that of the overshoot
// past the ends.  The overshoot is 0 exactly in the segment's span, gradient
// included, so near the segment the gradient is the line's, where the
// difference between a point and its projection would be rounding noise.
fn _segment_dd(line, t, el) {
    square(line) + square((t - clamp(t, 0.0, 1.0)) * el)
}

// A distance from its square `dd` and its sign, with `line` on the outline,
// where `dd` is 0 and `sqrt` has no gradient: `line` is the signed distance
// to the line through the nearest edge, also 0 there, whose gradient is the
// outline's normal.  `or` takes it wherever the product is 0.
fn _signed_sqrt(dd, sign, line) {
    or(sqrt(dd) * sign, line)
}

// --- Public helpers ---

/// clamp(v: Tree, lo: Tree, hi: Tree): Tree
///
/// Limits `v` to the range from `lo` to `hi`.
///
/// - `v`: the value
/// - `lo`, `hi`: the range's ends, `lo <= hi`
///
/// Below `lo` the result is `lo`, above `hi` it is `hi`.
/// It is `min(max(v, lo), hi)`.
///
/// See also: `linstep`, `smoothstep`.
///
/// Example: a slot 6 mm wide, as the distance to a segment from x = -10 to 10, less 3.
/// ```
/// hypot(x - clamp(x, -10, 10), y) - 3
/// ```
fn clamp(v, lo, hi) {
    min(max(_float(v), _float(lo)), _float(hi))
}

/// saturate(v: Tree): Tree
///
/// Limits `v` to the range from 0 to 1.
///
/// - `v`: the value
///
/// It is `clamp(v, 0, 1)`.
///
/// Notes:
/// - Named as in HLSL, Direct3D's shading language.
///
/// See also: `clamp`, `linstep`.
///
/// Example: a plate whose top edge rises 10 mm over 20 mm from x = 0, flat on either side.
/// ```
/// rect([60, 30]).intersection(y - 10 * saturate(x / 20))
/// ```
fn saturate(v) {
    clamp(v, 0.0, 1.0)
}

/// lerp(a: Tree | Tree[], b: Tree | Tree[], t: Tree): Tree | Tree[]
///
/// Linear interpolation, lerp for short: the value `t` of the way from `a` to `b`.
///
/// - `a`, `b`: the ends, or arrays of the same length, such as points
/// - `t`: 0 at `a` and 1 at `b`; not clamped, so it may go beyond them
///
/// Arrays are interpolated element by element, so `lerp` moves points and lists of points too.
/// Two shapes blend as fields, into a shape between the two.
///
/// Notes:
/// - GLSL, the OpenGL Shading Language, calls it `mix`; fidget's own `mix` is a hash for random numbers.
///
/// See also: `linstep`, `keyframes`, `morph`.
///
/// References:
/// - [Linear interpolation, Wikipedia](https://en.wikipedia.org/wiki/Linear_interpolation)
///
/// Example: a shape halfway between a hexagon 40 mm across its flats and a circle.
/// ```
/// lerp(hexagon_af(40), circle(20), 0.5)
/// ```
/// Example: the point a quarter of the way from one point to another.
/// ```
/// lerp([0, 10], [20, 30], 0.25)
/// ```
fn lerp(a, b, t) {
    if type_of(a) == "array" || type_of(b) == "array" {
        if type_of(a) != "array" || type_of(b) != "array" || a.len() != b.len() {
            throw `lerp: a and b must be arrays of the same length, got ${a} and ${b}`;
        }
        let out = [];
        for i in 0..a.len() {
            out.push(lerp(_float(a[i]), _float(b[i]), t));
        }
        return out;
    }
    a + (b - a) * t
}

/// rescale(v: Tree, from: [Tree, Tree], to: [Tree, Tree]): Tree
///
/// `v` carried from one range to another: from `from[0]` to `to[0]`, from `from[1]` to `to[1]`, and in between and beyond along the same line.
///
/// - `v`: the value
/// - `from`: `[a, b]`, the range `v` comes from, `a != b`
/// - `to`: `[c, d]`, the range it goes to
///
/// It is `lerp(c, d, (v - a) / (b - a))`, not clamped.
/// `lerp(c, d, linstep(a, b, v))` is the same, clamped to the range from `c` to `d`.
///
/// Notes:
/// - Often called `map` or `remap` elsewhere; fidget's `remap` moves a shape's coordinates instead.
///
/// See also: `lerp`, `linstep`.
///
/// Example: a cone whose radius goes from 10 at z = 0 to 2 at z = 20. [view: camera front]
/// ```
/// let r = rescale(z, [0, 20], [10, 2]);
/// normalize_z(hypot(x, y) - r)
///     .intersection(slab([0, 20]))
/// ```
fn rescale(v, from, to) {
    let from = _pair(from, "rescale: from");
    let to = _pair(to, "rescale: to");
    lerp(to[0], to[1], (_float(v) - from[0]) / (from[1] - from[0]))
}

/// step(edge: Tree, v: Tree): Tree
///
/// A sudden step from 0 to 1 as `v` reaches `edge`.
///
/// - `edge`: where it steps
/// - `v`: the value
///
/// The result is 0 where `v` is below `edge`, and 1 elsewhere.
/// On trees, its gradient is 0, as `compare`'s is.
///
/// Notes:
/// - The same as `step` in GLSL, the OpenGL Shading Language.
///
/// See also: `linstep`, `smoothstep`, `compare`.
///
/// Example: a post of radius 6 below z = 10 and of radius 3 above.
/// ```
/// let r = lerp(6, 3, step(10, z));
/// (hypot(x, y) - r).intersection(slab([0, 20]))
/// ```
fn step(edge, v) {
    if _is_number(edge) && _is_number(v) {
        if v < edge { 0.0 } else { 1.0 }
    } else {
        // `compare` plus 1 is 0 below `edge`, and 1 or 2 elsewhere.
        min(compare(_float(v), _float(edge)) + 1.0, 1.0)
    }
}

/// linstep(e0: Tree, e1: Tree, v: Tree): Tree
///
/// A straight step from 0 to 1 as `v` goes from edge `e0` to edge `e1`.
///
/// - `e0`, `e1`: the edges, `e0 != e1`
/// - `v`: the value
///
/// The result is 0 at `e0` and beyond it, 1 at `e1` and beyond it, and changes evenly between.
/// `linstep(z0, z1, z)` is how far up the slab from `z0` to `z1` a point is: the `t` that `lerp` and the easings take.
///
/// See also: `smoothstep`, `smootherstep`, `lerp`, `ease`.
///
/// Example: a shaft that narrows from 15 to 5 mm in radius between z = 10 and z = 30. [view: camera front]
/// ```
/// let r = lerp(15, 5, linstep(10, 30, z));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn linstep(e0, e1, v) {
    clamp((_float(v) - e0) / _float(e1 - e0), 0.0, 1.0)
}

/// smoothstep(e0: Tree, e1: Tree, v: Tree): Tree
///
/// A smooth step from 0 to 1 as `v` goes from edge `e0` to edge `e1`.
///
/// - `e0`, `e1`: the edges, `e0 != e1`
/// - `v`: the value
///
/// The result is 0 at `e0` and beyond it, and 1 at `e1` and beyond it.
/// Between, it is `3 t^2 - 2 t^3`, with `t` as `linstep` gives it.
/// Its slope is 0 at both edges, so a value that follows it starts and stops changing gently.
///
/// Notes:
/// - The same as `smoothstep` in GLSL, the OpenGL Shading Language.
/// - Its curvature jumps at the edges; `smootherstep`'s does not.
///
/// See also: `smootherstep`, `linstep`, `ease_in_out_sine`.
///
/// References:
/// - [Smoothstep, Wikipedia](https://en.wikipedia.org/wiki/Smoothstep)
///
/// Example: a bottle, its body joined to its neck by a smooth shoulder. [view: camera front]
/// ```
/// let r = lerp(15, 6, smoothstep(20, 30, z));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn smoothstep(e0, e1, v) {
    let t = clamp((_float(v) - e0) / _float(e1 - e0), 0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// fract(v: Tree): Tree
///
/// The fractional part of `v`: `v - floor(v)`, from 0 up to 1, for a negative `v` too.
///
/// - `v`: the value
///
/// A fractional part of a coordinate rises from 0 to 1 across every cell 1 wide, for a pattern that repeats.
///
/// Notes:
/// - Field: a step at every integer, as for `floor`.
/// - The same as `fract` in GLSL; Rhai's own `fraction` has the sign of `v`.
///
/// See also: `floor`, `mod`.
///
/// Example: a plate with a sawtooth edge, its teeth 8 mm apart.
/// ```
/// rect([40, 20]).intersection(y - 4 * fract(x / 8))
/// ```
fn fract(v) {
    let v = _float(v);
    v - floor(v)
}

/// mod(a: Tree, b: Tree): Tree
///
/// The remainder of `a` divided by `b`, from 0 up to `abs(b)`, for a negative `a` or `b` too.
///
/// - `a`: the value
/// - `b`: the divisor, not 0
///
/// It is the Euclidean remainder, which `%` gives on trees.
/// Between two numbers `%` is Rhai's, which has the sign of `a`, so `-7 % 3` is -1, but `mod(-7, 3)` is 2.
///
/// Notes:
/// - GLSL's `mod` has the sign of `b`; the two agree for a positive `b`.
///
/// See also: `%`, `fract`.
///
/// References:
/// - [Euclidean division, Wikipedia](https://en.wikipedia.org/wiki/Euclidean_division)
///
/// Example: the remainder of -7 divided by 3.
/// ```
/// mod(-7, 3)
/// ```
fn mod(a, b) {
    let a = _float(a);
    let b = _float(b);
    if _is_number(a) && _is_number(b) {
        let r = a % b;
        if r < 0.0 { r + abs(b) } else { r }
    } else {
        a % b
    }
}

/// hypot(a: Tree, b: Tree): Tree
///
/// The length of `[a, b]`: the hypotenuse of a right triangle whose legs are `a` and `b`.
///
/// - `a`, `b`: the legs
///
/// `hypot(x, y)` is the distance from the Z axis.
///
/// See also: `norm`.
///
/// Example: a torus, as the distance from a circle of radius 15 in the XY plane, less 4.
/// ```
/// hypot(hypot(x, y) - 15, z) - 4
/// ```
fn hypot(a, b) {
    let a = _float(a);
    let b = _float(b);
    sqrt(a * a + b * b)
}

/// hypot(a: Tree, b: Tree, c: Tree): Tree
///
/// The length of `[a, b, c]`.
///
/// - `a`, `b`, `c`: the components
///
/// `hypot(x, y, z)` is the distance from the origin.
///
/// See also: `norm`.
///
/// Example: a capsule, as the distance from a segment from z = -10 to 10, less 4.
/// ```
/// hypot(x, y, z - clamp(z, -10, 10)) - 4
/// ```
fn hypot(a, b, c) {
    let a = _float(a);
    let b = _float(b);
    let c = _float(c);
    sqrt(a * a + b * b + c * c)
}

// --- Degrees ---

/// sind(a: Tree): Tree
///
/// The sine of an angle in degrees.
///
/// - `a`: the angle, in degrees
///
/// fidget's own `sin`, `cos` and `tan` take radians.
/// On numbers, the angles whose sine is a whole number or a half, such as 30 and 180, give it exactly.
///
/// See also: `cosd`, `tand`, `asind`.
///
/// From OpenSCAD: `sin` takes degrees there, and gives these angles exactly too.
///
/// Example: the point 20 mm from the origin at 60 degrees from +X.
/// ```
/// [20 * cosd(60), 20 * sind(60)]
/// ```
fn sind(a) {
    if _is_number(a) { _sind(a.to_float()) } else { sin(a * (PI / 180.0)) }
}

/// cosd(a: Tree): Tree
///
/// The cosine of an angle in degrees.
///
/// - `a`: the angle, in degrees
///
/// On numbers, the angles whose cosine is a whole number or a half, such as 60 and 90, give it exactly.
///
/// See also: `sind`, `tand`, `acosd`.
///
/// Example: a plate whose top edge waves 3 mm up and down, once every 18 mm.
/// ```
/// rect([72, 40])
///     .intersection(y - 10 - 3 * cosd(20 * x))
/// ```
fn cosd(a) {
    if _is_number(a) { _sind(a.to_float() + 90.0) } else { cos(a * (PI / 180.0)) }
}

/// tand(a: Tree): Tree
///
/// The tangent of an angle in degrees.
///
/// - `a`: the angle, in degrees
///
/// On numbers, the angles whose tangent is 0, 1 or -1, such as 45 and 180, give it exactly.
///
/// See also: `sind`, `cosd`, `atand`.
///
/// Example: how far a 30-degree slope rises over 10 mm.
/// ```
/// 10 * tand(30)
/// ```
fn tand(a) {
    if !_is_number(a) {
        return tan(a * (PI / 180.0));
    }
    let a = a.to_float();
    let r = a % 180.0;
    let r = if r < 0.0 { r + 180.0 } else { r };
    if r == 45.0 {
        1.0
    } else if r == 135.0 {
        -1.0
    } else {
        _sind(a) / _sind(a + 90.0)
    }
}

/// asind(v: Tree): Tree
///
/// The arcsine of `v`, in degrees, from -90 to 90.
///
/// - `v`: the sine, from -1 to 1
///
/// fidget's own `asin`, `acos`, `atan` and `atan2` give radians.
///
/// See also: `sind`, `acosd`, `atand`.
///
/// Example: the angle of a ramp 10 mm long that rises 3 mm.
/// ```
/// asind(3.0 / 10)
/// ```
fn asind(v) {
    asin(v) * (180.0 / PI)
}

/// acosd(v: Tree): Tree
///
/// The arccosine of `v`, in degrees, from 0 to 180.
///
/// - `v`: the cosine, from -1 to 1
///
/// See also: `cosd`, `asind`, `atand`.
///
/// Example: the angle of a triangle with sides of 4 and 5 mm, opposite its third side of 6 mm.
/// ```
/// acosd((4 * 4 + 5 * 5 - 6 * 6) / (2.0 * 4 * 5))
/// ```
fn acosd(v) {
    acos(v) * (180.0 / PI)
}

/// atand(v: Tree): Tree
///
/// The arctangent of `v`, in degrees, from -90 to 90.
///
/// - `v`: the tangent
///
/// See also: `tand`, `atan2d`, `asind`.
///
/// Example: the angle of a slope that rises 3 mm over 4 mm.
/// ```
/// atand(3.0 / 4)
/// ```
fn atand(v) {
    atan(v) * (180.0 / PI)
}

/// atan2d(y: Tree, x: Tree): Tree
///
/// The two-argument arctangent in degrees: the angle of the point (`x`, `y`) from +X, anticlockwise, from -180 to 180.
///
/// - `y`, `x`: the point's coordinates, `y` first, as in `atan2`
///
/// On trees, `atan2d(y, x)` is each point's angle about the Z axis.
///
/// See also: `atand`, `sind`, `cosd`.
///
/// References:
/// - [atan2, Wikipedia](https://en.wikipedia.org/wiki/Atan2)
///
/// Example: the direction of the point [-1, 1].
/// ```
/// atan2d(1, -1)
/// ```
fn atan2d(y, x) {
    atan2(y, x) * (180.0 / PI)
}

// The sine of `a` degrees, a number: exact where it is a whole number or a
// half, as OpenSCAD's is.
fn _sind(a) {
    let r = a % 360.0;
    let r = if r < 0.0 { r + 360.0 } else { r };
    if r == 0.0 || r == 180.0 {
        0.0
    } else if r == 90.0 {
        1.0
    } else if r == 270.0 {
        -1.0
    } else if r == 30.0 || r == 150.0 {
        0.5
    } else if r == 210.0 || r == 330.0 {
        -0.5
    } else {
        sin(r * (PI / 180.0))
    }
}

// --- Vectors ---

/// dot(a: Tree[], b: Tree[]): Tree
///
/// The dot product of two vectors of the same length.
///
/// - `a`, `b`: the vectors
///
/// See also: `cross`, `norm`.
///
/// References:
/// - [Dot product, Wikipedia](https://en.wikipedia.org/wiki/Dot_product)
///
/// Example: how far the point [3, 4] lies along the direction [0.6, 0.8].
/// ```
/// dot([3, 4], [0.6, 0.8])
/// ```
fn dot(a, b) {
    let a = _array(a, "dot: a");
    let b = _array(b, "dot: b");
    if a.len() != b.len() {
        throw `dot: a and b must have the same length, got ${a} and ${b}`;
    }
    let s = 0.0;
    for i in 0..a.len() {
        s = s + a[i] * b[i];
    }
    s
}

/// cross(a: Vec3, b: Vec3): Vec3
/// cross(a: Vec2, b: Vec2): number
///
/// The cross product of two vectors.
///
/// - `a`, `b`: two 3D vectors, or two 2D ones
///
/// Of two 3D vectors, it is square to both, by the right-hand rule, and as long as the area of the parallelogram they span.
/// Of two 2D vectors, it is that vector's Z: positive when `b` turns anticlockwise from `a`.
///
/// See also: `dot`, `normalize`, `normal2`.
///
/// References:
/// - [Cross product, Wikipedia](https://en.wikipedia.org/wiki/Cross_product)
///
/// Example: the normal of the XY plane, from two of its directions.
/// ```
/// cross([1, 0, 0], [0, 1, 0])
/// ```
/// Example: which way one 2D direction turns from another.
/// ```
/// cross([1, 0], [0, 1])
/// ```
fn cross(a, b) {
    let a = _array(a, "cross: a");
    let b = _array(b, "cross: b");
    if a.len() == 2 && b.len() == 3 {
        a.push(0.0);
    } else if a.len() == 3 && b.len() == 2 {
        b.push(0.0);
    }
    if a.len() == 2 && b.len() == 2 {
        a[0] * b[1] - a[1] * b[0]
    } else if a.len() == 3 && b.len() == 3 {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    } else {
        throw `cross: a and b must be [x, y] or [x, y, z], got ${a} and ${b}`;
    }
}

/// norm(v: Tree[]): Tree
///
/// The length of a vector.
///
/// - `v`: the vector
///
/// See also: `normalize`, `hypot`, `dot`.
///
/// Example: the distance from the point [10, 10] to [30, 25].
/// ```
/// norm([30 - 10, 25 - 10])
/// ```
fn norm(v) {
    sqrt(dot(v, v))
}

/// normalize(v: Tree[]): Tree[]
///
/// A vector scaled to length 1: its direction.
///
/// - `v`: the vector; one of length 0 is an error
///
/// See also: `norm`, `normal2`.
///
/// Example: the direction from the origin towards [3, 4].
/// ```
/// normalize([3, 4])
/// ```
fn normalize(v) {
    let l = norm(v);
    if _is_number(l) && l == 0.0 {
        throw "normalize: a vector of length 0 has no direction";
    }
    _array(v, "normalize: v").map(|c| c / l)
}

/// normal2(a: Vec2, b: Vec2): Vec2
///
/// The unit normal of the 2D segment from `a` to `b`, on its left.
///
/// - `a`, `b`: the segment's ends
///
/// It is the segment's direction turned a quarter anticlockwise.
/// Along an outline that runs anticlockwise, it points inwards.
///
/// See also: `normalize`, `cross`.
///
/// Example: the normal on the left of a segment along +X.
/// ```
/// normal2([0, 0], [10, 0])
/// ```
fn normal2(a, b) {
    let a = _vec2(a, "normal2: a");
    let b = _vec2(b, "normal2: b");
    normalize([a[1] - b[1], b[0] - a[0]])
}

// A vector as an array of floats or trees, from `[...]`, `vec2` or `vec3`.
fn _array(v, what) {
    let t = type_of(v);
    if t == "array" {
        v.map(|c| _float(c))
    } else if t == "Vec2" {
        [v.x, v.y]
    } else if t == "Vec3" {
        [v.x, v.y, v.z]
    } else {
        throw `${what} must be a vector [x, y, ...], got ${t}`;
    }
}
