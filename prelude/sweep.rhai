// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: helices, bends and sweeps.
//
// kind: extrude

// --- Helices and bends ---

/// helix(profile: Shape, radius: number, pitch: number): Shape
///
/// Sweeps a 2D profile along a helix round the Z axis, without end.
///
/// - `profile`: the cross-section, centred on the origin
/// - `radius`: the helix's radius
/// - `pitch`: its rise per turn; negative for a left-handed helix
///
/// The profile stands square to the helix.
/// Its X points away from the axis, and its Y along the helix's binormal, upwards.
/// So `circle(r)` makes a round wire, and `rect([a, b])` a flat band.
///
/// The profile must fit within one pitch along Z.
/// Cut the ends with planes or `intersection`.
/// For several starts, union copies turned with `rotate_z`.
///
/// Notes:
/// - Field: approx (1%): with a round profile, within 1% of the distance in a wire as thick as the helix's radius, on helices up to 60 degrees steep.
/// - Costs as much as one turn, however many turns there are.
///
/// See also: `sweep`, `rotate_z`.
///
/// References:
/// - [Helix, Wikipedia](https://en.wikipedia.org/wiki/Helix)
/// - [Frenet–Serret formulas, Wikipedia](https://en.wikipedia.org/wiki/Frenet%E2%80%93Serret_formulas), for the binormal
///
/// From OpenSCAD: a `linear_extrude` with `twist` of an off-centre circle cuts the wire horizontally, which flattens it on a steep helix.
///
/// Example: a compression spring, 40 mm long, its ends cut flat.
/// ```
/// helix(circle(1.5), 10, 8)
///     .intersection(cuboid([30, 30, 40]))
/// ```
fn helix(profile, radius, pitch) {
    let rh = _num(radius, "helix: radius");
    let p = _num(pitch, "helix: pitch");
    if p == 0.0 {
        throw "helix: pitch must not be 0; revolve a profile for rings";
    }
    let r = _hypot(x, y);
    // Height above the helix's nearest turn at this angle; the remainder
    // also joins the turns where atan2 jumps.
    let w = (z - p * _atan2_narrow(y, x) / TAU + abs(p) * 0.5) % abs(p) - abs(p) * 0.5;
    // The binormal offset is w times the cosine of the helix angle: at the
    // helix's radius on the wire, at the point's own radius off it; their
    // geometric mean is right to second order on both sides, as the law of
    // cosines has it.
    let cos_h = TAU * rh / _hypot(TAU * rh, p);
    let cos_r = TAU * r / _hypot(TAU * r, p);
    remap(_tree(profile), r - rh, w * _sqrt(cos_h * cos_r), square(0.0))
}

/// bend(shape: Shape, r: number, angle: number | [number, number] = [-180, 180]): Shape
///
/// Bends a shape's Z axis round an arc of radius `r` about the Z axis, in the XY plane.
///
/// - `shape`: the shape, laid along Z
/// - `r`: the arc's radius
/// - `angle`: how far round, in degrees, anticlockwise looking down from +X; `[a0, a1]` from `a0` to `a1`; at most a whole turn
///
/// The shape's Z becomes the length along the arc, from +X.
/// Its X becomes the distance outwards from the arc, and its Y becomes Z.
/// So the shape from z = `r * a0` to z = `r * a1`, the angles in radians, goes round the arc; for a single angle, from z = 0 up.
/// A part of a turn is cut flat at both ends, in the shape's own section there.
///
/// A whole turn takes the shape from z = `-PI * r` to `PI * r` and joins its ends at -X.
/// A shape that repeats every `TAU * r` along Z closes into a ring without a seam, such as a rope with a whole number of twists.
/// Any other is cut where the ends meet.
///
/// `revolve` is the same for a profile that does not change along Z.
///
/// Notes:
/// - Field: exact where the shape's field is, for a shape that does not change along Z, ends included.
/// - Lengths along the arc are measured at its radius.
///   Where the shape's surface crosses Z at an angle, the field is steeper inside the arc, by up to `r / d` at distance `d` from the axis, and a bound outside it.
///   A loft's walls nearly follow Z, so a bent loft stays close to a distance.
///
/// See also: `revolve`, `sweep`, `loft`.
///
/// Example: a horn, a hexagon that shrinks and turns as it bends a quarter turn round a radius of 40.
/// ```
/// let column = loft([0, 40 * PI / 2], |t| #{
///     shape: regular_polygon(6, 8),
///     scale: lerp(1.0, 0.4, t),
///     angle: 60 * t,
/// });
/// column.bend(40, 90)
/// ```
fn bend(shape, r, angle) {
    let p = _shape(shape, "bend: shape");
    let r = _num(r, "bend: r");
    if r <= 0.0 {
        throw `bend: r must be positive, got ${r}`;
    }
    let a = _angles(angle, "bend: angle");
    let a0 = a[0] * (PI / 180.0);
    let a1 = a[1] * (PI / 180.0);
    if a[1] - a[0] >= 360.0 {
        // The angle runs once round from a0, so the seam is at a0.
        let m = (a0 + a1) * 0.5;
        let c = cos(m);
        let s = sin(m);
        let around = m + _atan2_narrow(y * c - x * s, x * c + y * s);
        return remap(p, _hypot(x, y) - r, z, r * around);
    }
    let at = _arc_place(a0, a1);
    max(_corner(remap(p, at.u - r, z, r * at.a), at.across), _wedge_bound(a0, a1))
}

// Both `bend(shape, r)` and the method form `shape.bend(r, angle)`, told
// apart by the first argument: a shape, or the radius.
fn bend(r, angle) {
    if _is_number(r) { bend(this, r, angle) } else { bend(r, angle, [-180.0, 180.0]) }
}

// --- Sweeps ---

/// sweep(profile: Shape | ((t: Tree) => Shape), path: Step[], opts: #{ twist?: Sched, scale?: Sched, ease?: Ease, ease_twist?: Ease, ease_scale?: Ease } = #{}): Shape
/// type Step = #{ line: number } | #{ arc: number, turn: number } | #{ helix: number, turn: number, rise: number } | #{ bezier: Vec2[] }
/// type Sched = Tree | ((t: Tree) => Tree) | Key[]
///
/// Sweeps a 2D profile along a path of steps, as a turtle walks it.
///
/// - `profile`: the cross-section, its X to the path's left and its Y up; or a function of `t` that gives it
/// - `path`: the steps, in order
///   - `line`: straight ahead, this long
///   - `arc`: round an arc of this radius, by `turn` degrees; to the left for a positive `turn`, to the right for a negative one; at most a whole turn
///   - `helix`: an arc of this radius that also climbs by `rise` as it turns; less than a whole turn
///   - `bezier`: along a Bézier curve; these are its control points after the first, in the turtle's frame (X ahead, Y to the left), and the first is where the turtle stands
/// - `opts`:
///   - `twist`: the profile's turn in its plane, in degrees, anticlockwise as it is drawn
///   - `scale`: a factor on the profile, about its origin
///   - `ease`: how a number for `twist` or `scale` is reached, `"linear"` by default; see `ease`
///   - `ease_twist`, `ease_scale`: the same for one of them
///
/// The turtle starts at the origin, heading along +X, in the XY plane.
/// Each step starts where the one before ended, heading the way it ended, so a line turns smoothly into an arc.
/// A Bézier step joins smoothly when the first of its control points lies straight ahead, on +X.
/// It ends heading from its last but one control point to its last.
/// The path's ends are cut flat, square to it.
///
/// The profile stays upright, its Y along +Z.
/// On a level path, that is a rotation-minimising frame: the profile does not spin about the path.
/// On a `helix` step, the wire is cut vertically, as a ramp, so it joins level steps without a seam.
///
/// `t` is how far along the path a point is, by length, from 0 at the start to 1 at the end.
/// A number for `twist` or `scale` is the value at the end, reached along the easing.
/// A tree, a function of `t` or keyframes in `t` give the value at every point instead, as for `extrude`.
/// A function for `profile` is called once, with `t` as a tree, so the profile can change along the path.
///
/// Turn and move the result into place, or stand it up with `rotate_x`.
///
/// Notes:
/// - Field: exact outside along lines and arcs, where the profile's field is; inside, a bound where two steps meet.
/// - Along a Bézier step, close to exact: the nearest point on the curve comes from three steps of Newton's method, as in `bezier_stroke`, about 150 operations per piece of up to 45 degrees of turn.
///   Far inside a tight bend it can be larger than the distance.
/// - With `twist`, `scale`, a function for `profile`, or along a `helix` step, a distance to first order, from a second evaluation of the profile.
/// - A profile wider than an arc's radius folds over itself inside the bend.
///
/// See also: `sweep_length`, `bezier_stroke`, `helix`, `bend`, `revolve`.
///
/// References:
/// - [Turtle graphics, Wikipedia](https://en.wikipedia.org/wiki/Turtle_graphics)
/// - [Bézier curve, Wikipedia](https://en.wikipedia.org/wiki/B%C3%A9zier_curve)
/// - Wenping Wang, Bert Jüttler, Dayue Zheng, Yang Liu, [Computation of rotation minimizing frames](https://doi.org/10.1145/1330511.1330513), 2008
///
/// Example: a wall hook, its wire bent by a half turn, lying flat.
/// ```
/// let path = [
///     #{line: 30},
///     #{arc: 8, turn: 180},
///     #{line: 10},
/// ];
/// sweep(circle(2), path)
/// ```
/// Example: a spiral ramp, a level run, three quarters of a turn climbing by 10, and another level run.
/// ```
/// let path = [
///     #{line: 10},
///     #{
///         helix: 15,
///         turn: 270,
///         rise: 10,
///     },
///     #{line: 10},
/// ];
/// sweep(rect([8, 2]), path)
/// ```
fn sweep(profile, path, opts) {
    _opts(opts, ["twist", "scale", "ease", "ease_twist", "ease_scale"], "sweep");
    if type_of(path) != "array" || path.is_empty() {
        throw `sweep: path must be an array of steps, got ${path}`;
    }
    // The pieces of the path, walked when the script runs.
    let at = [0.0, 0.0, 0.0];
    let heading = 0.0;
    let pieces = [];
    let total = 0.0;
    for step in path {
        let walked = _sweep_step(step, at, heading);
        for piece in walked.pieces {
            piece.s0 = total;
            total += piece.length;
            pieces.push(piece);
        }
        at = walked.at;
        heading = walked.heading;
    }
    pieces[0].first = true;
    pieces[pieces.len() - 1].last = true;
    // The profile in its own coordinates, with `t` as its z.
    let varying = type_of(profile) == "Fn" || "twist" in opts || "scale" in opts;
    let shape = if type_of(profile) == "Fn" {
        _shape(profile.call(z), "sweep: profile")
    } else {
        remap(_shape(profile, "sweep: profile"), x, y, square(0.0))
    };
    let section = |u, v, t| _scheduled(shape, t, opts, "sweep", u, v, t);
    let parts = pieces.map(|piece| _sweep_piece(piece, section, total, varying));
    if parts.len() == 1 { parts[0] } else { union(parts) }
}

// Both `sweep(profile, path)` and the method form `profile.sweep(path,
// opts)`, told apart by the first argument: a profile, or a path.
fn sweep(path, opts) {
    if _is_path(path) { sweep(this, path, opts) } else { sweep(path, opts, #{}) }
}

/// sweep_length(path: Step[]): number
///
/// The length of a sweep's path, from its start to its end.
///
/// - `path`: the steps, as `sweep` takes them
///
/// `sweep`'s `t` runs from 0 to 1 over this length.
/// So a place `d` along the path is at `t = d / sweep_length(path)`, and one `d` before its end at `1 - d / sweep_length(path)`.
/// A Bézier step's length is that of 32 chords along it, as `sweep` measures it.
///
/// See also: `sweep`, `keyframes`.
///
/// Example: a line of 10 and a quarter turn of radius 5.
/// ```
/// sweep_length([#{line: 10}, #{arc: 5, turn: 90}])
/// ```
/// Example: a bar whose ends taper over their last 4 mm, wherever the path ends.
/// ```
/// let path = [#{line: 20}, #{arc: 8, turn: 90}, #{line: 20}];
/// let tip = 4 / sweep_length(path);
/// let scale = [[0, 0.6], [tip, 1], [1 - tip, 1], [1, 0.6]];
/// circle(3).sweep(path, #{scale: scale})
/// ```
fn sweep_length(path) {
    if type_of(path) != "array" || path.is_empty() {
        throw `sweep_length: path must be an array of steps, got ${path}`;
    }
    let at = [0.0, 0.0, 0.0];
    let heading = 0.0;
    let total = 0.0;
    for step in path {
        let walked = _sweep_step(step, at, heading);
        for piece in walked.pieces {
            total += piece.length;
        }
        at = walked.at;
        heading = walked.heading;
    }
    total
}

// Whether `v` is a path of steps rather than a profile.
fn _is_path(v) {
    type_of(v) == "array" && !v.is_empty() && v.all(|step| type_of(step) == "map")
}

// One step of a sweep's path, taken from `at` heading `heading` radians:
// its pieces, and where it ends and which way.
fn _sweep_step(step, at, heading) {
    if type_of(step) != "map" {
        throw `sweep: a step must be a map such as #{line: 10}, got ${step}`;
    }
    let c = cos(heading);
    let s = sin(heading);
    if "line" in step {
        _opts(step, ["line"], "sweep: a line step");
        let l = _num(step.line, "sweep: line");
        if l <= 0.0 {
            throw `sweep: a line must be longer than 0, got ${l}`;
        }
        let piece = #{kind: "line", at: at, heading: heading, length: l};
        return #{pieces: [piece], at: [at[0] + l * c, at[1] + l * s, at[2]], heading: heading};
    }
    if "arc" in step || "helix" in step {
        let helix = "helix" in step;
        let what = if helix { "sweep: a helix step" } else { "sweep: an arc step" };
        _opts(step, if helix { ["helix", "turn", "rise"] } else { ["arc", "turn"] }, what);
        let r = _num(if helix { step.helix } else { step.arc }, what);
        let turn = _num(_opt(step, "turn", 0.0), `${what}: turn`);
        let rise = if helix { _num(_opt(step, "rise", 0.0), `${what}: rise`) } else { 0.0 };
        if r <= 0.0 || turn == 0.0 || abs(turn) > 360.0 || (helix && abs(turn) >= 360.0) {
            throw `${what} needs a positive radius and a turn of up to ${if helix { "below" } else { "at most" }} a whole turn either way, got ${step}`;
        }
        let side = if turn > 0.0 { 1.0 } else { -1.0 };
        let turn = turn * (PI / 180.0);
        // The arc's centre is to the side it turns to; the turtle starts at
        // `from` round it.
        let centre = [at[0] - side * r * s, at[1] + side * r * c];
        let from = heading - side * FRAC_PI_2;
        let to = from + turn;
        let climb = rise / abs(turn);
        let piece = #{
            kind: "arc", centre: centre, z: at[2], r: r, side: side,
            from: from, to: to, climb: climb,
            length: abs(turn) * sqrt(r * r + climb * climb),
        };
        let end = [centre[0] + r * cos(to), centre[1] + r * sin(to), at[2] + rise];
        return #{pieces: [piece], at: end, heading: heading + turn};
    }
    if "bezier" in step {
        _opts(step, ["bezier"], "sweep: a bezier step");
        if type_of(step.bezier) != "array" || step.bezier.is_empty() {
            throw `sweep: bezier must be an array of control points, got ${step.bezier}`;
        }
        // The control points in the plane, from the turtle's frame.
        let p = [[at[0], at[1]]];
        for q in step.bezier {
            let q = _vec2(q, "sweep: a bezier control point");
            p.push([at[0] + q[0] * c - q[1] * s, at[1] + q[0] * s + q[1] * c]);
        }
        let n = p.len() - 1;
        let pieces = [];
        for piece in _bezier_pieces(p, 0.0, 1.0, 0) {
            pieces.push(#{kind: "bezier", points: piece[0], z: at[2], length: _bezier_length(piece[0])});
        }
        let dx = p[n][0] - p[n - 1][0];
        let dy = p[n][1] - p[n - 1][1];
        if dx == 0.0 && dy == 0.0 {
            throw "sweep: a bezier's last two control points must differ, to give its end a heading";
        }
        return #{pieces: pieces, at: [p[n][0], p[n][1], at[2]], heading: atan(dy, dx)};
    }
    throw `sweep: unknown step ${step}; a step is #{line}, #{arc, turn}, #{helix, turn, rise} or #{bezier}`;
}

// A Bézier curve's length, from 32 chords.
fn _bezier_length(p) {
    let l = 0.0;
    let last = p[0];
    for i in 1..=32 {
        let q = bezier_point(p, i / 32.0);
        l += _hypot(q[0] - last[0], q[1] - last[1]);
        last = q;
    }
    l
}

// One piece's field: `section.call(u, v, t)` in the plane square to the
// path at the point's nearest place along the piece, closed at its ends as
// an extrusion's rims are.  `start` and `end` are the signed distances
// past them, or what the piece's sections are closed by within its span,
// past the path's own ends only.
fn _sweep_piece(piece, section, total, varying) {
    switch piece.kind {
        "line" => {
            let c = cos(piece.heading);
            let s = sin(piece.heading);
            let dx = x - piece.at[0];
            let dy = y - piece.at[1];
            let along = dx * c + dy * s;
            let t = (piece.s0 + clamp(along, 0.0, piece.length)) / total;
            let h = 0.1;
            let start = -along;
            let end = along - piece.length;
            let ends = _sweep_ends(piece, max(start, end), start, end);
            _sweep_section(section, dy * c - dx * s, z - piece.at[2], t, 0.0, h / total, h, ends, varying)
        }
        "arc" => {
            // Round the centre, put at the origin, then moved to it.
            let lo = min(piece.from, piece.to);
            let hi = max(piece.from, piece.to);
            let at = _arc_place(lo, hi);
            let gone = abs(at.a - piece.from);
            let along = sqrt(piece.r * piece.r + piece.climb * piece.climb);
            let u = piece.side * (piece.r - at.u);
            let v = z - piece.z - piece.climb * gone;
            let t = (piece.s0 + along * gone) / total;
            // A step a tenth along the path, as an angle, moves a point
            // its own distance from the axis times that.
            let da = 0.1 / along;
            let step = max(_hypot(x, y) * da, 1e-4);
            // How far past each end, as angles, from the arc's middle; within
            // the span, the distance to an end's half-plane.
            let half = (hi - lo) * 0.5;
            let past = [-at.off - half, at.off - half];
            if piece.side < 0.0 {
                past = [past[1], past[0]];
            }
            let rho = _hypot(x, y);
            let start = rho * _sin_poly(max(past[0], -FRAC_PI_2));
            let end = rho * _sin_poly(max(past[1], -FRAC_PI_2));
            let ends = _sweep_ends(piece, at.across, start, end);
            let rising = varying || piece.climb != 0.0;
            let f = _sweep_section(section, u, v, t, -piece.climb * da, 0.1 / total, step, ends, rising);
            move(max(f, _wedge_bound(lo, hi)), [piece.centre[0], piece.centre[1], 0.0])
        }
        "bezier" => _sweep_bezier(piece, section, total, varying),
    }
}

// A Bézier piece's field: the nearest point on the curve found as
// `bezier_stroke` finds it, then the section in the plane square to the
// curve there.
fn _sweep_bezier(piece, section, total, varying) {
    let p = piece.points;
    let n = p.len() - 1;
    let c = _bezier_coefficients(p);
    let ex = p[n][0] - p[0][0];
    let ey = p[n][1] - p[0][1];
    let ee = ex * ex + ey * ey;
    let s = if ee > 0.0 {
        clamp(((x - p[0][0]) * ex + (y - p[0][1]) * ey) / ee, 0.0, 1.0)
    } else {
        0.5 + 0.0 * x
    };
    for i in 0..3 {
        let b = _bezier_eval(c, s);
        let bx = b[0] - x;
        let by = b[1] - y;
        let speed = b[2] * b[2] + b[3] * b[3];
        let f2 = max(speed + bx * b[4] + by * b[5], speed * 0.1 + 1e-9);
        s = clamp(s - (bx * b[2] + by * b[3]) / f2, 0.0, 1.0);
    }
    let b = _bezier_eval(c, s);
    let speed = _sqrt(b[2] * b[2] + b[3] * b[3]);
    let u = ((y - b[1]) * b[2] - (x - b[0]) * b[3]) / max(speed, 1e-9);
    // The planes square to the curve at its ends, from the control polygon.
    let start = _bezier_end(p[0], p[1]);
    let end = _bezier_end(p[n], p[n - 1]);
    let start = (x - p[0][0]) * start[0] + (y - p[0][1]) * start[1];
    let end = (x - p[n][0]) * end[0] + (y - p[n][1]) * end[1];
    let ends = _sweep_ends(piece, max(start, end), start, end);
    let t = (piece.s0 + piece.length * s) / total;
    _sweep_section(section, u, z - piece.z, t, 0.0, 0.1 / total, 0.1, ends, varying)
}

// The unit direction out of a Bézier curve at its end `a`, away from its
// next control point `b`.
fn _bezier_end(a, b) {
    let dx = a[0] - b[0];
    let dy = a[1] - b[1];
    let l = sqrt(dx * dx + dy * dy);
    [dx / l, dy / l]
}

// A Bézier curve in the power basis: c[k] such that the curve is the sum
// of c[k] s^k, for `_bezier_eval`.  The same as `_bezier_piece`'s.
fn _bezier_coefficients(p) {
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

// What closes a piece's sections: past either end, `across`, the distance
// to the nearer end's section; within its span, the distance to the path's
// own ends among `start` and `end`, if any.  An end where the next piece
// joins closes nothing within: there the union's inside is the next
// piece's, where it would otherwise be 0 all over the joint.
fn _sweep_ends(piece, across, start, end) {
    let inner = -1e6;
    if "first" in piece {
        inner = start;
    }
    if "last" in piece {
        inner = max(inner, end);
    }
    #{across: across, closed: _select_less(0.0, across, across, inner)}
}

// A section at `u`, `v` and `t`, closed by `ends`.  Where `varying`, the
// section changes along the path, and a second evaluation a `step` further
// along, where `v` and `t` have changed by `dv` and `dt`, keeps the field a
// distance to first order; past the ends the section no longer changes.
fn _sweep_section(section, u, v, t, dv, dt, step, ends, varying) {
    let f = section.call(u, v, t);
    if varying {
        let g = (section.call(u, v + dv, t + dt) - f) / step * clamp(-1000.0 * ends.across, 0.0, 1.0);
        f = f / sqrt(1.0 + square(g));
    }
    _corner(f, ends.closed)
}

// --- Method forms ---

// Rhai calls a script function as a method only through `this`, so each
// function above whose first argument is a shape gets a twin for
// `shape.f(...)`.

fn helix(radius, pitch) { helix(this, radius, pitch) }
fn bend(r) { bend(this, r, [-180.0, 180.0]) }
fn sweep(path) { sweep(this, path, #{}) }
