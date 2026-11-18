// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: 3D solids from 2D shapes.
//
// kind: extrude
//
// Each takes the shape's slice at z = 0, so any tree works as a profile.
// With an exact 2D field, the extrusions are exact too, rims included.

// --- Extrusion along Z ---

/// extrude(shape: Shape, h: Height, opts: #{ round?: Rim, chamfer?: Rim, normalize?: bool, draft?: number, twist?: Sched, scale?: Sched, move?: Move, ease?: Ease, ease_twist?: Ease, ease_scale?: Ease, ease_move?: Ease } = #{}): Shape
/// type Height = number | [number, number]
/// type Rim = Sched | [Sched, Sched]
/// type Sched = Tree | ((t: Tree) => Tree) | Key[]
/// type Move = [Sched, Sched] | ((t: Tree) => [Tree, Tree])
///
/// Extrudes a 2D shape along Z into a solid, its rims sharp, rounded or chamfered.
///
/// - `shape`: the 2D profile, in XY
/// - `h`: the height, centred on z = 0; or `[z0, z1]`, from `z0` up to `z1`
/// - `opts`:
///   - `round`: the radius of the rims; `[bottom, top]` for one each, 0 for a sharp rim
///   - `chamfer`: how much a 45-degree chamfer cuts off the side and the face at the rims, as for `round`
///   - `normalize`: `false` skips the correction of a rim size that varies over space; twice as fast, but offsets and shells come out uneven
///   - `draft`: the walls' slope from vertical, in degrees; positive leans them in as they rise, negative out
///   - `twist`: the profile's turn about Z, in degrees, anticlockwise looking down
///   - `scale`: a factor on the profile, about the origin
///   - `move`: `[dx, dy]`, a move of the profile
///   - `ease`: how a number for `twist`, `scale` or `move` is reached, `"linear"` by default; see `ease`
///   - `ease_twist`, `ease_scale`, `ease_move`: the same for one of them
///
/// `t` runs from 0 at the bottom to 1 at the top.
///
/// A rounded rim keeps the side on the profile and curves over into the face.
/// A rim's size is a number, a tree that varies over space, a function of `t`, or keyframes in `t`.
/// The two rims' sizes together must be less than the height.
/// A small chamfer on the bottom rim hides elephant's foot, the bulge of a squashed first layer.
///
/// `draft` tilts every wall by the same angle, starting from the profile at the bottom.
///
/// `twist`, `scale` and `move` change the profile as it rises.
/// A number is the value at the top: the bottom is the profile as it is, and the easing takes it from there.
/// A tree, a function of `t` or keyframes in `t` give the value at every height instead.
/// The profile is scaled first, then turned, then moved, as in `loft`.
///
/// Notes:
/// - Field: exact where the profile's field is, without `draft`, `twist`, `scale` or `move`; rims as below.
/// - Rounded rims are exact along the profile's edges, straight or curved, and a bound near its corners; chamfered rims are a bound beyond the chamfer.
/// - With `draft`, a distance to first order, as `normalize_slope` makes it.
/// - With `twist`, `scale` or `move`, a distance to first order, as `normalize_z` makes it, from a second evaluation of the profile.
/// - A rim size that varies over space also takes a second evaluation, unless `normalize` is false.
/// - Fitted bounds of a turning profile reach as far from the Z axis on every side as the profile does, and may be up to a third larger.
///
/// See also: `twist`, `loft`, `revolve`, `extrude_z`.
///
/// References:
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Extrusion"
/// - [Draft (engineering), Wikipedia](https://en.wikipedia.org/wiki/Draft_(engineering))
///
/// From OpenSCAD: `linear_extrude(h, twist = a, scale = k)` is `extrude(shape, [0, h], #{twist: -a, scale: k})`; its twist turns the other way.
///
/// Example: a plate for printing, its top edges rounded and its bottom edge chamfered against elephant's foot.
/// ```
/// rect([40, 20], #{round: 4})
///     .extrude([0, 6], #{round: [0, 1], chamfer: [0.6, 0]})
/// ```
/// Example: a mould's core, its walls drafted by 3 degrees so that the cast comes off.
/// ```
/// rect([30, 20], #{round: 3})
///     .extrude([0, 12], #{draft: 3, round: [0, 1]})
/// ```
/// Example: a vase's body, a hexagon that turns by 60 degrees and narrows as it rises.
/// ```
/// regular_polygon(6, 20)
///     .extrude([0, 60], #{
///         twist: 60,
///         scale: 0.7,
///         ease: "in_out_sine",
///     })
/// ```
fn extrude(shape, h, opts) {
    _opts(opts, ["round", "chamfer", "normalize", "draft", "twist", "scale", "move", "ease", "ease_twist", "ease_scale", "ease_move"], "extrude");
    let zs = _height(h, "extrude: h");
    let d = remap(_tree(shape), x, y, square(0.0));
    _extrude(_extrude_slices(d, zs, opts, "extrude"), zs, opts, (), "extrude")
}

// Both `extrude(shape, h)` and the method form `shape.extrude(h, opts)`,
// which Rhai cannot tell apart by their number of arguments: as a method,
// `opts` is the map of options, and as a function it is the height.
fn extrude(h, opts) {
    if type_of(opts) == "map" { extrude(this, h, opts) } else { extrude(h, opts, #{}) }
}

// The 2D field `d` extruded from `zs[0]` up to `zs[1]`, its rims rounded or
// chamfered as `opts` say, their sizes clamped to `limit` unless it is
// `()`.
fn _extrude(d, zs, opts, limit, what) {
    let mid = (zs[0] + zs[1]) * 0.5;
    let half = (zs[1] - zs[0]) * 0.5;
    let dz = if mid == 0.0 { abs(z) - half } else { abs(z - mid) - half };
    if !("round" in opts) && !("chamfer" in opts) {
        return _corner(d, dz);
    }
    let t = linstep(zs[0], zs[1], z);
    let round = if "round" in opts { _rim(opts.round, t, `${what}: round`) } else { [0.0, 0.0] };
    let chamfer = if "chamfer" in opts { _rim(opts.chamfer, t, `${what}: chamfer`) } else { [0.0, 0.0] };
    let kinds = [];
    let sizes = [];
    for i in 0..2 {
        let rounded = !_is_zero(round[i]);
        let chamfered = !_is_zero(chamfer[i]);
        if rounded && chamfered {
            throw `${what}: a rim is rounded or chamfered, not both`;
        }
        kinds.push(if rounded { "round" } else if chamfered { "chamfer" } else { "sharp" });
        let size = if rounded { round[i] } else { chamfer[i] };
        sizes.push(if type_of(limit) == "()" { size } else { min(size, limit) });
    }
    // One size for both rims: the slab's symmetric field, as for a sharp
    // extrusion.  Two: each rim on its own face, the solid their
    // intersection, exact while neither rim reaches the other's.
    let kind = kinds[0];
    let symmetric = if kinds[1] != kind {
        false
    } else if _is_number(sizes[0]) && _is_number(sizes[1]) {
        sizes[0] == sizes[1]
    } else {
        !_rim_pair(_opt(opts, kind, 0.0))
    };
    if symmetric {
        _vary(|v| _rim_field(d, dz, kind, v), sizes[0], opts)
    } else {
        let bottom = _vary(|v| _rim_field(d, zs[0] - z, kinds[0], v), sizes[0], opts);
        let top = _vary(|v| _rim_field(d, z - zs[1], kinds[1], v), sizes[1], opts);
        max(bottom, top)
    }
}

// An extrusion's field near one rim, from `d`, the profile's, and `dz`,
// the face's: sharp, rounded with radius `v`, or chamfered by `v`.
fn _rim_field(d, dz, kind, v) {
    switch kind {
        "round" => _corner(d + v, dz + v) - v,
        "chamfer" => max(max(d, dz), (d + dz + v) / SQRT_2),
        _ => _corner(d, dz),
    }
}

fn _is_zero(v) {
    _is_number(v) && v == 0.0
}

// The slice `d` turned, scaled and moved up the extrusion from `zs[0]` to
// `zs[1]` as `opts` say, and drafted: a field that is a distance within
// each slice, made one in 3D to first order.
fn _extrude_slices(d, zs, opts, what) {
    let scheduled = "twist" in opts || "scale" in opts || "move" in opts;
    if scheduled {
        let t = linstep(zs[0], zs[1], z);
        d = _scheduled(d, t, opts, what, x, y, z);
    }
    if "draft" in opts {
        let k = tand(_num(opts.draft, `${what}: draft`));
        d = d + (z - zs[0]) * k;
        if !scheduled {
            return d / sqrt(1.0 + k * k);
        }
    }
    if scheduled { normalize_z(d) } else { d }
}

// The 2D field `d` at `t` along a part, scaled, turned and moved as the
// part's `twist`, `scale` and `move` options say there, at the point whose
// coordinates in the part's slice are `u` and `v`; `w` becomes the
// field's z.  A scale near 0 is kept off it, so that a point is a tip and
// fitted bounds still see it.
fn _scheduled(d, t, opts, what, u, v, w) {
    let e = _opt(opts, "ease", "linear");
    let k = 1.0;
    if "scale" in opts {
        k = max(_goal(opts.scale, t, 1.0, _opt(opts, "ease_scale", e), `${what}: scale`), 1e-5);
    }
    let a = 0.0;
    if "twist" in opts {
        a = _goal(opts.twist, t, 0.0, _opt(opts, "ease_twist", e), `${what}: twist`) * (PI / 180.0);
    }
    let m = [0.0, 0.0];
    if "move" in opts {
        m = _goal_pair(opts.move, t, _opt(opts, "ease_move", e), `${what}: move`);
    }
    let pu = u - m[0];
    let pv = v - m[1];
    let c = cos(a);
    let s = sin(a);
    remap(d, (pu * c + pv * s) / k, (pv * c - pu * s) / k, w) * k
}

// A goal value at `t`: a number is the value at t = 1, reached from
// `neutral` at t = 0 along the easing `e`; anything else is a `Sched`,
// the value itself.
fn _goal(v, t, neutral, e, what) {
    if _is_number(v) {
        neutral + (v.to_float() - neutral) * ease(e, t)
    } else {
        _sched(v, t, what)
    }
}

// A goal `[dx, dy]` at `t`, each a goal from 0, or a function of `t`
// that gives both.
fn _goal_pair(v, t, e, what) {
    if type_of(v) == "Fn" {
        let m = v.call(t);
        if type_of(m) != "array" || m.len() != 2 {
            throw `${what}: a function of t must give [dx, dy], got ${m}`;
        }
        return [_float(m[0]), _float(m[1])];
    }
    if type_of(v) != "array" || v.len() != 2 {
        throw `${what} must be [dx, dy] or a function of t, got ${v}`;
    }
    [_goal(v[0], t, 0.0, e, what), _goal(v[1], t, 0.0, e, what)]
}

/// twist(shape: Shape, angle: Tree): Shape
///
/// Twists a shape round the Z axis, each point by the angle given there.
///
/// - `shape`: the shape, usually an extrusion
/// - `angle`: the turn in degrees, anticlockwise looking down; a tree of the coordinates, such as `9 * z`
///
/// `9 * z` turns by a steady 9 degrees per unit of height.
/// An easing of `z` gives a turn that speeds up and slows down.
/// A plain number throws: a turn of the whole shape is `rotate_z`.
///
/// Notes:
/// - Field: steeper than a distance away from the axis, by `sqrt(1 + (k r)^2)` at radius `r`, where `k` is the turn's rate in radians per unit of height.
/// - So offsets after a twist come out thinner away from the axis; `extrude`'s own `twist` keeps its field a distance to first order.
/// - Fitted bounds reach as far from the Z axis on every side as the shape does, and may be up to a third larger.
///
/// See also: `extrude`, `rotate_z`.
///
/// References:
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Twist"
///
/// Example: a twisted handle, a rounded bar turned by a whole turn along its 40 mm.
/// ```
/// cuboid([10, 4, 40], #{round: 1}).twist(9 * z)
/// ```
fn twist(shape, angle) {
    if _is_number(angle) {
        throw `twist: angle must be a tree, the turn at each point, such as ${angle} * z for ${angle} degrees per unit of height`;
    }
    let a = _field(angle, "twist: angle") * (PI / 180.0);
    let c = cos(a);
    let s = sin(a);
    remap(_tree(shape), x * c + y * s, y * c - x * s, z)
}

// --- Revolution ---

/// revolve(shape: Shape | Outline, angle: number | [number, number] = 360, opts: #{ sides?: number, round?: number, concave?: number } = #{}): Shape
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | [number, number, #{ arc: number }]
///
/// Revolves a 2D profile round the Z axis: the profile's X becomes the radius and its Y becomes Z.
///
/// - `shape`: the profile, in XY; or its points, as `polygon` takes them
/// - `angle`: how far round, in degrees, anticlockwise looking down from +X; `[a0, a1]` from `a0` to `a1`; at most a whole turn
/// - `opts`:
///   - `sides`: flat facets instead of a round surface, this many in a whole turn, a corner on +X; the profile's X is the radius to the corners
///   - `round`, `concave`: for a profile given as points, the radii of its convex and concave corners, as for `rounded_polygon`
///
/// `opts` may come without `angle`, for a whole turn.
/// A part of a turn ends flat at both ends, in the profile's plane.
/// With `sides`, a part of a turn has its share of the facets, rounded up, and starts at a corner.
///
/// A profile given as points may touch or cross the axis.
/// Its part at X >= 0 is joined to its mirror image, so the axis is no surface.
/// A profile all at X <= 0 is mirrored first.
///
/// Notes:
/// - Field: exact where the profile's field is, for a profile at X > 0 such as a ring or a groove, ends included; exact for a profile given as points, wherever it lies.
/// - A shape symmetric about X = 0, a whole cross-section such as `rect([2 * r, h])`, is exact for a whole turn; for a part of a turn, its ends are a bound behind the axis.
/// - Any other shape that reaches X = 0 has a bound inside, 0 along the axis, so offsets and shells go wrong there; give such a profile as points.
/// - With `sides`, a distance to first order on the facets, from a second evaluation of the profile, and a bound outside near the edges between them.
/// - fidget's `revolve_y` turns round the Y axis, and needs a profile symmetric about X = 0.
///
/// See also: `bend`, `sweep`, `polygon`, `rounded_polygon`, `revolve_y`.
///
/// References:
/// - [Surface of revolution, Wikipedia](https://en.wikipedia.org/wiki/Surface_of_revolution)
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Revolution"
///
/// From OpenSCAD: `rotate_extrude(angle = a, $fn = n)` is `revolve(shape, a, #{sides: n})`, its facets as OpenSCAD makes them.
///
/// Example: a cup, its profile drawn from the axis, its corners rounded.
/// ```
/// let profile = [
///     [0, 0], [20, 0], [24, 30],
///     [22, 30], [18, 2], [0, 2],
/// ];
/// revolve(profile, #{round: 0.8})
/// ```
/// Example: a pipe elbow, a tube's section turned by a quarter turn.
/// ```
/// circle(5)
///     .shell(1)
///     .move([20, 0])
///     .revolve(90)
/// ```
fn revolve(shape, angle, opts) {
    _opts(opts, ["sides", "round", "concave"], "revolve");
    let p = if _is_outline(shape) {
        _revolve_outline(shape, opts)
    } else if "round" in opts || "concave" in opts {
        throw "revolve: round and concave are for a profile given as points; round a shape before revolving it";
    } else {
        _shape(shape, "revolve: shape")
    };
    let a = _angles(angle, "revolve: angle");
    let whole = a[1] - a[0] >= 360.0;
    if whole && !("sides" in opts) {
        return revolve(p);
    }
    let a0 = a[0] * (PI / 180.0);
    let a1 = a[1] * (PI / 180.0);
    let rho = _hypot(x, y);
    let at = if whole { #{u: rho, a: _atan2(y, x), past: -1.0} } else { _arc_place(a0, a1) };
    let u = at.u;
    let flat = 0.0;
    if "sides" in opts {
        let n = opts.sides;
        if type_of(n) != "i64" || n < 3 {
            throw `revolve: sides must be an integer of at least 3, got ${n}`;
        }
        // As many facets as OpenSCAD's, n a turn, a part of one rounded up.
        // On a facet, the profile's X is the distance from the axis square
        // to the facet, over the facet's own distance from it at a vertex.
        // Past an end the angle stays at the end, a vertex, where that is
        // the distance from the axis: the end is the profile itself.
        let facets = max(ceil(n * (a[1] - a[0]) / 360.0), 1.0);
        let sector = (a1 - a0) / facets;
        let b = (at.a - a0) % sector - sector * 0.5;
        let c = cos(sector * 0.5);
        u = at.u * cos(b) / c;
        // The facets stretch the profile across by 1 / c; past the ends,
        // within a thousandth of a radian, they do no longer.
        flat = (1.0 / (c * c) - 1.0) * clamp(-1000.0 * at.past, 0.0, 1.0);
    }
    let f = remap(p, u, z, square(0.0));
    if "sides" in opts {
        // The facets stretch the profile across, so the field is steeper
        // by its gradient's share along X, which a second evaluation finds.
        let h = 0.1;
        let fu = (remap(p, u + h, z, square(0.0)) - f) / h;
        f = f / sqrt(1.0 + square(fu) * flat);
    }
    if whole {
        return f;
    }
    // Behind the axis the profile's X is negative, where a profile
    // symmetric about X = 0 has a mirror image that is not part of the end.
    max(_corner(max(f, -u), at.across), _wedge_bound(a0, a1))
}

// Both `revolve(shape, angle)` or `revolve(shape, opts)` and the method
// form `shape.revolve(angle, opts)`, told apart by the first argument: a
// shape, or an angle.
fn revolve(angle, opts) {
    if _is_angle(angle) {
        revolve(this, angle, opts)
    } else if type_of(opts) == "map" {
        revolve(angle, 360.0, opts)
    } else {
        revolve(angle, opts, #{})
    }
}

// Both `revolve(shape)` and the method forms `shape.revolve(angle)` and
// `shape.revolve(opts)`: Rhai passes a method's one argument where the
// function's shape would be, so `circle(1).revolve(90)` would otherwise
// revolve the number 90.
fn revolve(shape) {
    if _is_angle(shape) || type_of(shape) == "map" {
        let profile = ();
        try {
            profile = this;
        } catch {
            throw `revolve: ${shape} is not a shape; revolve a profile with profile.revolve(${shape}) or revolve(profile, ${shape})`;
        }
        if _is_angle(shape) { revolve(profile, shape, #{}) } else { revolve(profile, 360.0, shape) }
    } else if _is_outline(shape) {
        revolve(shape, 360.0, #{})
    } else {
        remap(_shape(shape, "revolve: shape"), _hypot(x, y), z, square(0.0))
    }
}

// Whether `v` is an outline's points rather than a shape or an array of
// shapes.
fn _is_outline(v) {
    type_of(v) == "array" && !v.is_empty() && type_of(v[0]) == "array"
}

// A profile given as points, as a shape whose field is exact about the
// axis: its part at X >= 0 and that part's mirror image, joined, rounded
// as `opts` say.  For a point on one side of the axis, the nearest point
// of the solid lies in its own half-plane, on that side's outline, so the
// whole cross-section's field is the solid's.
fn _revolve_outline(points, opts) {
    let loops = _outline(points, "revolve: points");
    if loops.some(|ring| ring.some(|w| type_of(w.k) != "()")) {
        throw "revolve: a profile given as points takes its corners' radii as #{round, concave}";
    }
    let lo = loops[0][0].p;
    let hi = lo;
    let reach = 0.0;
    for ring in loops {
        for w in ring {
            lo = [min(lo[0], w.p[0]), min(lo[1], w.p[1])];
            hi = [max(hi[0], w.p[0]), max(hi[1], w.p[1])];
            if type_of(w.arc) != "()" {
                reach = max(reach, abs(w.arc));
            }
        }
    }
    // A box over all of the profile at X >= 0, arcs included.
    let m = 2.0 * reach + 1.0;
    let far = max(hi[0], -lo[0]) + m;
    let right = [[0.0, lo[1] - m], [far, lo[1] - m], [far, hi[1] + m], [0.0, hi[1] + m]];
    let profile = loops.map(|ring| ring.map(|w| if type_of(w.arc) == "()" { w.p } else { [w.p[0], w.p[1], #{arc: w.arc}] }));
    let half = _polygon_clip(profile, right, "intersection", "revolve");
    if half.is_empty() {
        half = _polygon_clip(_mirror_x(profile), right, "intersection", "revolve");
    }
    if half.is_empty() {
        throw "revolve: the profile's points enclose nothing";
    }
    let whole = _polygon_clip(half, _mirror_x(half), "union", "revolve");
    let r = _num(_opt(opts, "round", 0.0), "revolve: round");
    let concave = _num(_opt(opts, "concave", r), "revolve: concave");
    if r == 0.0 && concave == 0.0 { polygon(whole) } else { rounded_polygon(whole, r, #{concave: concave}) }
}

// Loops of points mirrored across X = 0: an arc then turns the other way.
fn _mirror_x(loops) {
    loops.map(|ring| ring.map(|p| if p.len() == 3 { [-p[0], p[1], #{arc: -p[2].arc}] } else { [-p[0], p[1]] }))
}

// Where a point lies relative to the part of a turn round the Z axis from
// angle `a0` to `a1`, in radians: `off`, its angle from the part's middle,
// from -PI to PI; `past`, its angle past the nearer end, negative within;
// `a`, the angle within the part nearest it; and, in the
// half-plane at that angle, `u`, the point's distance from the axis along
// it, and `across`, its signed distance square to it, negative within.  A
// profile put at `u` and closed by `across` with `_corner` is exact at the
// ends, as an extrusion's rims are: past an end, the nearest point is on
// the end's half-plane.
fn _arc_place(a0, a1) {
    let m = (a0 + a1) * 0.5;
    let half = (a1 - a0) * 0.5;
    let c = cos(m);
    let s = sin(m);
    let off = _atan2(y * c - x * s, x * c + y * s);
    let past = abs(off) - half;
    let rho = _hypot(x, y);
    #{
        off: off,
        past: past,
        a: m + clamp(off, -half, half),
        u: rho * cos(max(past, 0.0)),
        across: rho * sin(max(past, -FRAC_PI_2)),
    }
}

// A bound of the wedge from angle `a0` to `a1` round the Z axis, in
// radians, at most a turn: below the field of any solid within it, so
// `max` with it changes no value but lets fitted bounds see the wedge's
// sides.  Up to half a turn the wedge is the intersection of the half-planes
// beyond its sides, past that their union.
fn _wedge_bound(a0, a1) {
    let start = x * sin(a0) - y * cos(a0);
    let end = y * cos(a1) - x * sin(a1);
    if a1 - a0 <= PI { max(start, end) } else { min(start, end) }
}

// An angle option as `[a0, a1]`, in degrees: a number from 0, either way
// round, or a pair, at most a turn apart.
fn _angles(v, what) {
    let a = if _is_number(v) {
        let v = v.to_float();
        if v < 0.0 { [v, 0.0] } else { [0.0, v] }
    } else if type_of(v) == "array" && v.len() == 2 {
        [_num(v[0], what), _num(v[1], what)]
    } else {
        throw `${what} must be an angle in degrees or [a0, a1], got ${v}`;
    };
    if a[1] <= a[0] || a[1] - a[0] > 360.0 {
        throw `${what} must go anticlockwise from a0 to a1, at most a turn, got [${a[0]}, ${a[1]}]`;
    }
    a
}

// Whether `v` is an angle option, a number or a pair of them, rather than
// a shape.
fn _is_angle(v) {
    _is_number(v) || (type_of(v) == "array" && v.len() == 2 && v.all(|a| _is_number(a)))
}

// A shape argument as a tree, an array of shapes as their union; anything
// else throws, so that a misplaced number does not become a constant.
fn _shape(v, what) {
    let t = type_of(v);
    if t == "Tree" || (t == "array" && !v.is_empty() && v.all(|s| type_of(s) == "Tree")) {
        _tree(v)
    } else {
        throw `${what} must be a shape, got ${t}`;
    }
}

// --- Method forms ---

// Rhai calls a script function as a method only through `this`, so each
// function above whose first argument is a shape gets a twin for
// `shape.f(...)`.

fn extrude(h) { extrude(this, h, #{}) }
fn twist(angle) { twist(this, angle) }
fn revolve() { revolve(this) }
