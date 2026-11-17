// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: profiles that change with height.
//
// kind: extrude
//
// OpenSCAD designs stack point layers and stitch them into a polyhedron;
// here a solid is the rule that gives each height its profile, and the
// field is that profile's, corrected for how fast it changes.

// --- Profiles over height ---

/// loft(slices: Slice[]): Shape
/// loft(h: Height, slice: (t: Tree) => Shape | Section): Shape
/// type Slice = #{
///   z: number,
///   shape?: Shape, scale?: number, angle?: number, move?: Vec2,
///   ease?: Ease, ease_shape?: Ease, ease_scale?: Ease,
///   ease_angle?: Ease, ease_move?: Ease,
/// }
/// type Height = number | [number, number]
/// type Section = #{ shape: Shape, scale?: Tree, angle?: Tree, move?: [Tree, Tree] }
///
/// Solid whose 2D profile changes with height, from key slices or from a function of the height.
///
/// - `slices`: the key slices, from the bottom up, at least two
///   - `z`: the slice's height, above the slice before
///   - `shape`: its 2D profile; the first slice must have one
///   - `scale`: a factor on the profile, about the origin
///   - `angle`: a turn of the profile about the origin, in degrees, anticlockwise looking down
///   - `move`: `[dx, dy]`, a move of the profile
///   - `ease`: how this slice's values are reached from the slice below, `"linear"` by default; see `ease`
///   - `ease_shape`, `ease_scale`, `ease_angle`, `ease_move`: the same for one of them
/// - `h`: the height, centred on z = 0; or `[z0, z1]`, from `z0` up to `z1`
/// - `slice`: a function of `t`, from 0 at the bottom to 1 at the top, that gives the profile there; or a map of the profile, as `shape`, and its `scale`, `angle` and `move`
///
/// With key slices, each value goes from one slice that gives it to the next, as in `keyframes`.
/// A slice that leaves a value out does not stop it: a `scale` given only at the bottom and the top changes over the whole height.
/// The first slice starts at scale 1, angle 0 and no move, unless it gives others.
///
/// With a function, `slice` is called once, with `t` as a tree.
/// So it is built from arithmetic, `ease`, `keyframes` and `lerp` of `t`, and cannot branch on `t` with `if`.
/// It suits a centre that runs along a curve, or a scale that follows a formula.
///
/// Either way, the bottom and the top are cut flat.
/// The profile is scaled first, then turned, then moved.
/// A scale may reach 0, for a tip.
///
/// Two different profiles blend as fields, so they need no matching points.
/// A profile can also change with height by itself, such as a `star` whose depth is `keyframes` of `z`.
/// Such a profile goes in as the first slice's only shape.
///
/// Notes:
/// - Field: a distance to first order, as `normalize_z` makes it, so `shell` and `offset` keep their thickness on leaning and turning walls.
/// - Costs two evaluations of the profile; with key slices, of every slice's profile, even when two slices give the same one.
/// - Fitted bounds of a turning profile reach as far from the Z axis on every side as the profile does, and may be up to a third larger.
///
/// See also: `extrude`, `loft_tilted`, `bend`, `keyframes`, `normalize_z`.
///
/// References:
/// - [Lofting, Wikipedia](https://en.wikipedia.org/wiki/Lofting)
///
/// Example: a vase's body, a hexagon that becomes a wider circle as it rises, turning by 30 degrees.
/// ```
/// loft([
///     #{z: 0, shape: hexagon_af(40)},
///     #{
///         z: 60,
///         shape: circle(25),
///         scale: 1.2,
///         angle: 30,
///         ease: "in_out_sine",
///     },
/// ])
/// ```
/// Example: a twisted column whose centre circles the Z axis once as it rises.
/// ```
/// loft([0, 60], |t| #{
///     shape: rect(10),
///     angle: 90 * t,
///     move: [8 * cos(TAU * t), 8 * sin(TAU * t)],
/// })
/// ```
fn loft(slices) {
    if type_of(slices) != "array" || slices.len() < 2 {
        throw "loft: slices must be an array of at least two maps";
    }
    let keys = #{shape: [], scale: [], angle: [], dx: [], dy: []};
    let bottom = 0.0;
    let top = 0.0;
    for i in 0..slices.len() {
        let s = slices[i];
        if type_of(s) != "map" || !("z" in s) {
            throw `loft: every slice must be a map with z, got ${s}`;
        }
        _opts(s, ["z", "shape", "scale", "angle", "move", "ease",
                  "ease_shape", "ease_scale", "ease_angle", "ease_move"], "loft: a slice");
        let at = _num(s.z, "loft: z");
        let first = i == 0;
        if first {
            bottom = at;
        } else if at <= top {
            throw `loft: slices must go up, got z = ${top} then ${at}`;
        }
        top = at;
        let e = _opt(s, "ease", "linear");
        if "shape" in s {
            keys.shape.push([at, _tree(s.shape), _opt(s, "ease_shape", e)]);
        } else if first {
            throw "loft: the first slice needs a shape";
        }
        if first || "scale" in s {
            keys.scale.push([at, _num(_opt(s, "scale", 1.0), "loft: scale"), _opt(s, "ease_scale", e)]);
        }
        if first || "angle" in s {
            let a = _num(_opt(s, "angle", 0.0), "loft: angle") * PI / 180.0;
            keys.angle.push([at, a, _opt(s, "ease_angle", e)]);
        }
        if first || "move" in s {
            let m = _vec2(_opt(s, "move", 0.0), "loft: move");
            keys.dx.push([at, m[0], _opt(s, "ease_move", e)]);
            keys.dy.push([at, m[1], _opt(s, "ease_move", e)]);
        }
    }
    let k = keyframes(z, keys.scale);
    // A scale of 0, the tip of a cone or pyramid, kept just off it: the
    // profile's coordinates divided by it would be infinite there, and
    // fitted bounds would see nothing.
    if keys.scale.some(|key| key[1] == 0.0) {
        k = max(k, 1e-5);
    }
    let move = [keyframes(z, keys.dx), keyframes(z, keys.dy)];
    _loft_field(keyframes(z, keys.shape), k, keyframes(z, keys.angle), move, bottom, top)
}

// Both lofts' field: `profile` scaled by `k`, turned by `a` radians and
// moved by `move` at each height, a distance to first order, cut flat at
// `bottom` and `top`.
fn _loft_field(profile, k, a, move, bottom, top) {
    let px = x - move[0];
    let py = y - move[1];
    let c = cos(a);
    let s = sin(a);
    let f = remap(profile, (px * c + py * s) / k, (py * c - px * s) / k, z) * k;
    _corner(normalize_z(f), max(bottom - z, z - top))
}

// The loft whose slices one function gives: `slice.call(t)` at
// t = linstep(z0, z1, z), a shape or a map of its shape, scale, angle and
// move.
fn loft(h, slice) {
    let zs = _height(h, "loft: h");
    if type_of(slice) != "Fn" {
        throw `loft: slice must be a function of t, got ${type_of(slice)}`;
    }
    let s = slice.call(linstep(zs[0], zs[1], z));
    if type_of(s) != "map" {
        s = #{shape: s};
    }
    _opts(s, ["shape", "scale", "angle", "move"], "loft: a slice");
    if !("shape" in s) {
        throw "loft: a slice needs a shape";
    }
    let k = max(_field(_opt(s, "scale", 1.0), "loft: scale"), 1e-5);
    let a = _field(_opt(s, "angle", 0.0), "loft: angle") * (PI / 180.0);
    let move = _opt(s, "move", [0.0, 0.0]);
    if type_of(move) != "array" || move.len() != 2 {
        throw `loft: move must be [dx, dy], got ${move}`;
    }
    let move = [_field(move[0], "loft: move"), _field(move[1], "loft: move")];
    _loft_field(_shape(s.shape, "loft: shape"), k, a, move, zs[0], zs[1])
}

/// loft_tilted(profile: Shape, top: Vec3, tilt: number): Shape
///
/// Solid made of 2D slices that tilt more as they rise, like the side of a sculpted keycap.
///
/// - `profile`: the 2D outline of a slice, in the slice's own coordinates; its `z` runs from 0 at the bottom slice to 1 at the top one
/// - `top`: `[x, y, z]`, the centre of the top slice; the bottom slice is centred on the origin
/// - `tilt`: the top slice's tilt about Y, in degrees; a positive `tilt` lowers its +X side
///
/// The bottom slice is flat.
/// Going up, each slice moves towards `top` and tilts further, until the top slice is tilted by `tilt`.
/// In the profile, X runs along the slice's tilted plane and Y is the world's Y.
///
/// The profile's `z` says how far up its slice is, so the profile can change as it rises.
/// For example, `lerp(a, b, z)` blends from `a` at the bottom to `b` at the top.
/// The profile sees `z` only from 0 to 1, so `acos(z)` and the like need no clamp.
///
/// The top is cut along the top slice.
/// Below z = 0 the wall continues straight down, so that the part can be cut where it stands with `.intersection(-z)`.
/// Cutting after `shell` leaves the shell open there.
///
/// Notes:
/// - Field: a distance to first order, as `loft`'s is, so shells keep their thickness.
/// - Costs two evaluations of the profile.
/// - The slices' planes meet near x = `top[2] / tan(tilt)`, and the solid must end before that.
///
/// See also: `loft`, `squircle`, `lerp`.
///
/// From OpenSCAD: keycaps that turn their layers by an evenly growing angle come out within about 0.01 mm of `loft_tilted`.
///
/// Example: the side of a keycap, hollow, its top tilted down towards +X.
/// ```
/// let profile = lerp(squircle(9, 0.9), squircle(6, 0.95), z);
/// loft_tilted(profile, [-1, 0, 8], 10)
///     .shell(1)
///     .intersection(-z)
/// ```
fn loft_tilted(profile, top, tilt) {
    let top = _vec3(top, "loft_tilted: top", 0.0);
    if top[2] <= 0.0 {
        throw `loft_tilted: the top must lie above the bottom, got z = ${top[2]}`;
    }
    let tilt = _num(tilt, "loft_tilted: tilt");
    if abs(tilt) >= 90.0 {
        throw `loft_tilted: tilt must be within 90 degrees of level, got ${tilt}`;
    }
    let profile = _tree(profile);
    let tt = tan(tilt * PI / 180.0);

    // The plane of slice t passes through the point where
    // (x - t top_x) t tt + z - t top_z = 0, k t^2 + b t - z = 0; its root,
    // written to stay finite as k nears 0.  max keeps the denominators'
    // intervals clear of 0, where they would be NaN.
    let k = top[0] * tt;
    let b = top[2] - x * tt;
    let free = 2.0 * z / max(b + _sqrt(max(square(b) + 4.0 * k * z, 0.0)), 1e-6);
    let t = clamp(free, 0.0, 1.0);

    // The field's rate square to the slices: its change from slice t to a
    // neighbour, below near the top, times t's own rate, one over how fast
    // the slice's plane moves past the point as t grows.  Past the ends t
    // stays put, and so does the field.  The step's sign is a factor of its
    // own, as dividing by a choice of steps would leave intervals that
    // straddle 0.  The neighbour is clamped for the intervals' sake too: a
    // step that straddles 0 reaches past either end, where a profile such as
    // acos(z) is NaN, and the field would have no fitted bounds.
    let f = _tilted_slice(profile, top, tt, t);
    let h = if top[2] > 0.2 { 0.1 / top[2] } else { 0.5 };
    let step = 2.0 * _less(t, 1.0 - h) - 1.0;
    let between = _less(0.0, free) * _less(free, 1.0);
    let rate = between * sqrt(1.0 + square(t * tt)) / max(2.0 * k * t + b, 1e-6);
    let near = _tilted_slice(profile, top, tt, clamp(t + step * h, 0.0, 1.0));
    let g = (near - f) * step / h * rate;
    // g's interval reaches far, and dividing by it would draw that of the
    // field towards 0 from both sides, which fitted bounds cannot see past.
    // Only a wall within a degree of its slices is steeper than this.
    let g = clamp(g, -100.0, 100.0);

    let n = sqrt(1.0 + tt * tt);
    let lid = ((x - top[0]) * tt + z - top[2]) / n;
    _corner(f / sqrt(1.0 + square(g)), lid)
}

// `profile` in the plane of `loft_tilted`'s slice `t`: the point's
// coordinates along the plane, turned back by the slice's tilt about its
// centre, and `t` as its z.
fn _tilted_slice(profile, top, tt, t) {
    let ta = t * tt;
    let ca = 1.0 / sqrt(1.0 + square(ta));
    let qx = x - top[0] * t;
    let qz = z - top[2] * t;
    remap(profile, (qx - qz * ta) * ca, y - top[1] * t, t)
}

/// normalize_z(shape: Shape): Shape
///
/// Makes a field built from horizontal slices measure distance in 3D, to first order.
///
/// - `shape`: a field that is a distance, or a bound, within each horizontal slice
///
/// A field built slice by slice, such as a profile that is scaled or turned with height, measures distance across its slice.
/// Where the wall leans or turns, the distance to the wall is shorter than that.
/// `normalize_z` divides the field by `sqrt(1 + (df/dz)^2)`, where `df/dz` is how fast the field changes going up.
/// Offsets and shells then keep their thickness.
///
/// `loft` and `extrude`'s `twist`, `scale` and `move` already do this, and `loft_tilted` does the same along its slices.
///
/// Notes:
/// - Field: exact for straight leaning walls, close for curved ones.
/// - The slope comes from a second evaluation of the shape 0.1 higher, so the cost doubles.
///
/// See also: `normalize_slope`, `loft`.
///
/// References:
/// - Inigo Quilez, [Distance estimation](https://iquilezles.org/articles/distance/)
///
/// Example: a six-pointed star that gets spikier as it rises.
/// ```
/// let radius = keyframes(z, [[0, 26], [50, 17, "in_out_cubic"]]);
/// normalize_z(star(6, [30, radius]))
///     .intersection(max(-z, z - 50))
/// ```
fn normalize_z(shape) {
    let f = _tree(shape);
    // Trees are 32-bit floats: a hundredth's difference is noisy enough to
    // speckle the shading, whose normals differentiate it once more.
    let h = 0.1;
    let slope = (remap(f, x, y, z + h) - f) / h;
    f / sqrt(1.0 + square(slope))
}

/// normalize_slope(shape: Shape, dz: Tree): Shape
///
/// `normalize_z` with the slope worked out by hand.
///
/// - `shape`: a field that is a distance, or a bound, within each horizontal slice
/// - `dz`: how fast the field changes going up, at a fixed point of the slice
///
/// The field is divided by `sqrt(1 + dz^2)`.
/// Work `dz` out with the chain rule, through whatever the slices change with height, such as a radius or an angle.
///
/// Notes:
/// - Field: exact where `normalize_z`'s is, without its second evaluation of the shape or the noise of its finite difference.
///
/// See also: `normalize_z`.
///
/// References:
/// - Inigo Quilez, [Distance estimation](https://iquilezles.org/articles/distance/)
///
/// Example: a cone cut short, its radius shrinking by 0.5 per unit of height, so `dz` is 0.5.
/// ```
/// normalize_slope(hypot(x, y) - (10 - 0.5 * z), 0.5)
///     .intersection(max(-z, z - 12))
/// ```
fn normalize_slope(shape, dz) {
    _tree(shape) / sqrt(1.0 + square(_float(dz)))
}

// --- Method forms ---

// Rhai calls a script function as a method only through `this`, so each
// function above whose first argument is a shape gets a twin for
// `shape.f(...)`.

fn loft_tilted(top, tilt) { loft_tilted(this, top, tilt) }
fn normalize_z() { normalize_z(this) }
fn normalize_slope(dz) { normalize_slope(this, dz) }
