// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: 2D shapes in the XY plane, centred on the origin.
//
// kind: 2d
//
// Every field here is an exact Euclidean distance unless its doc says
// otherwise, so offsets, shells and rounded combinations stay true.

// --- Rectangles and round shapes ---

/// rect(size: Vec2 | number, opts: #{ round?: Tree, chamfer?: Tree, anchor?: Anchor2, normalize?: bool } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Rectangle centred on the origin, its corners sharp, rounded or chamfered.
///
/// - `size`: `[width, height]`, or one number for a square
/// - `opts`:
///   - `round`: the corners' radius, clamped to half the shorter side; it may vary over space
///   - `chamfer`: how far a 45-degree chamfer at each corner cuts into each side, clamped likewise; it may vary over space
///   - `anchor`: the point put on the origin, from `[-1, -1]`, the -X -Y corner, to `[1, 1]`; or a name, such as `"left"`, the middle of the -X side
///   - `normalize`: `false` to skip the correction that keeps the field a distance when `round` or `chamfer` varies; see the notes
///
/// A rectangle has `round` or `chamfer`, not both.
/// A `round` of half the shorter side gives a stadium, with a half circle at each end.
///
/// Notes:
/// - Field: exact, rounded or chamfered too.
/// - fidget's `rectangle` is only a bound beyond its corners, so its offsets keep sharp corners.
/// - A `round` or `chamfer` that varies keeps the field a distance to first order, at the cost of a second evaluation.
/// - `normalize: false` skips that correction: twice as fast, but offsets and shells come out uneven.
///
/// See also: `rectangle`, `cuboid`, `rounded_polygon`.
///
/// Example: a plate with rounded corners and a hole at each corner.
/// ```
/// let holes = circle(1.7)
///     .grid_array([32, 12], [2, 2], #{center: true});
/// rect([40, 20], #{round: 3}).difference(holes)
/// ```
/// Example: a tab whose corners are rounded more towards +X.
/// ```
/// let corner = lerp(1, 6, linstep(-10, 10, x));
/// rect(20, #{round: corner})
/// ```
fn rect(size) {
    rect(size, #{})
}

fn rect(size, opts) {
    _opts(opts, ["round", "chamfer", "anchor", "normalize"], "rect");
    let s = _vec2(size, "rect: size");
    let shape = if "round" in opts {
        if "chamfer" in opts {
            throw "rect: its corners are rounded or chamfered, not both";
        }
        let r = min(_field(opts.round, "rect: round"), min(s[0], s[1]) * 0.5);
        _vary(|r| _corner(abs(x) - (s[0] - 2.0 * r) * 0.5, abs(y) - (s[1] - 2.0 * r) * 0.5) - r, r, opts)
    } else if "chamfer" in opts {
        let c = min(_field(opts.chamfer, "rect: chamfer"), min(s[0], s[1]) * 0.5);
        _vary(|c| _chamfered_rect(s[0] * 0.5, s[1] * 0.5, c), c, opts)
    } else {
        _corner(abs(x) - s[0] * 0.5, abs(y) - s[1] * 0.5)
    };
    let half = [s[0] * 0.5, s[1] * 0.5];
    _anchor(shape, _opt(opts, "anchor", ()), [-half[0], -half[1]], half, "rect")
}

// The exact field of a rectangle of half sizes `w` and `h` whose corners
// are cut at 45 degrees, `c` off each side.  The symmetry folds every
// point into the +X +Y quadrant, where the outline is a side, a chamfer
// and a top: inside, the largest of the distances to their lines; outside,
// the distance to the nearest of the three segments.
fn _chamfered_rect(w, h, c) {
    let u = abs(x);
    let v = abs(y);
    let side = u - w;
    let top = v - h;
    let cut = (u + v - (w + h - c)) / SQRT_2;
    // The place along the chamfer from its end on the side, and the
    // overshoot past its ends; no division by its length, which may be 0.
    let along = (w - u + v - h + c) / SQRT_2;
    let over = along - clamp(along, 0.0, c * SQRT_2);
    let dd = min(
        min(square(side) + square(max(v - (h - c), 0.0)), square(cut) + square(over)),
        square(top) + square(max(u - (w - c), 0.0)),
    );
    // The box changes no value, but shows interval arithmetic where the
    // shape ends, as `polygon`'s does.
    max(_corner_of(max(max(side, top), cut), dd), _box_bound([-w, -h], [w, h]))
}

/// annulus(r: [Tree, Tree], opts: #{ anchor?: Anchor2 } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Ring between two circles centred on the origin.
///
/// - `r`: `[outer, inner]`, the radii, the inner one smaller; either may vary over space
/// - `opts`:
///   - `anchor`: the point put on the origin, as for `rect`
///
/// Notes:
/// - Field: exact.
///
/// See also: `tube`, `arc_stroke`, `shell`.
///
/// References:
/// - [Annulus (mathematics), Wikipedia](https://en.wikipedia.org/wiki/Annulus_%28mathematics%29)
///
/// Example: a washer for a 3 mm screw.
/// ```
/// annulus([3.5, 1.6])
/// ```
fn annulus(r) {
    annulus(r, #{})
}

fn annulus(r, opts) {
    _opts(opts, ["anchor"], "annulus");
    let r = _pair(r, "annulus: r");
    let shape = abs(_hypot(x, y) - (r[0] + r[1]) * 0.5) - (r[0] - r[1]) * 0.5;
    _anchor(shape, _opt(opts, "anchor", ()), [-r[0], -r[0]], [r[0], r[0]], "annulus")
}

/// ellipse(radii: Vec2 | number, opts: #{ anchor?: Anchor2 } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Ellipse centred on the origin, its radii along X and Y.
///
/// - `radii`: `[rx, ry]`, the radius along X and the one along Y, or one number for a circle
/// - `opts`:
///   - `anchor`: the point put on the origin, as for `rect`
///
/// Notes:
/// - Field: close to a distance.
///   It is exact on the outline and on the axes, and a little off in between, so offsets and rounded combinations come out about the size they are given.
/// - `circle(1).scale([rx, ry])` has the same outline, but its field is too small by up to a factor of the larger radius.
///
/// See also: `circle`, `squircle`.
///
/// References:
/// - Inigo Quilez, [Ellipsoid SDF](https://iquilezles.org/articles/ellipsoids/), the same estimate in 3D
///
/// From OpenSCAD: `scale([rx, ry]) circle(1)` is `ellipse([rx, ry])`.
///
/// Example: an oval window in a panel, for a cable to pass through.
/// ```
/// let plate = rect([40, 25], #{round: 2});
/// let hole = ellipse([10, 5]);
/// plate.difference(hole)
/// ```
fn ellipse(radii) {
    ellipse(radii, #{})
}

fn ellipse(radii, opts) {
    _opts(opts, ["anchor"], "ellipse");
    let r = _vec2(radii, "ellipse: radii");
    if r[0] <= 0.0 || r[1] <= 0.0 {
        throw `ellipse: radii must be positive, got ${radii}`;
    }
    // Quilez's approximation: the unit circle's field in the stretched
    // plane, over the length of its gradient; the clamp keeps it finite at
    // the centre, where the ratio is between the radii.
    let k0 = _hypot(x / r[0], y / r[1]);
    let k1 = _hypot(x / (r[0] * r[0]), y / (r[1] * r[1]));
    let shape = (k0 - 1.0) * clamp(k0 / max(k1, 1e-12), min(r[0], r[1]), max(r[0], r[1]));
    _anchor(shape, _opt(opts, "anchor", ()), [-r[0], -r[1]], r, "ellipse")
}

/// teardrop(r: number, opts: #{ anchor?: Anchor2 } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Circle with a 90-degree point towards +Y, the cross-section of a hole that prints on its side.
///
/// - `r`: the radius of the round part
/// - `opts`:
///   - `anchor`: the point put on the origin, as for `rect`; the box reaches up to the point
///
/// The point is `r * sqrt(2)` from the centre.
/// Its two sides lean at 45 degrees, so a horizontal hole with this cross-section prints without support.
/// Extruded and turned by `rotate_x(90)`, the hole runs along Y with its point up.
///
/// Notes:
/// - Field: exact.
///
/// See also: `circle`, `extrude`.
///
/// Example: a hole for a 3 mm screw, along Y through a plate, its point up.
/// ```
/// let block = cuboid([16, 6, 10]);
/// let hole = teardrop(1.7).extrude(8).rotate_x(90);
/// block.difference(hole)
/// ```
/// Example: the same hole cut flat at the top, a short span that the printer bridges.
/// ```
/// let block = cuboid([16, 6, 10]);
/// let hole = max(teardrop(1.7), y - 1.7)
///     .extrude(8)
///     .rotate_x(90);
/// block.difference(hole)
/// ```
fn teardrop(r) {
    teardrop(r, #{})
}

fn teardrop(r, opts) {
    _opts(opts, ["anchor"], "teardrop");
    let r = _num(r, "teardrop: r");
    // The hull of the circle and the point (0, r * sqrt(2)), split into the
    // circle's arc, the point and the two tangent lines.
    let s = 1.0 / SQRT_2;
    let ax = abs(x);
    let k = (y - ax) * s;
    let on_arc = _less(k, 0.0);
    let on_tip = _less(r, k);
    let d_arc = _hypot(x, y) - r;
    let d_tip = _hypot(x, y - r * SQRT_2);
    let d_side = (ax + y) * s - r;
    let d = on_arc * d_arc + on_tip * d_tip + (1.0 - on_arc - on_tip) * d_side;
    let shape = max(d, _box_bound([-r, -r], [r, r * SQRT_2]));
    _anchor(shape, _opt(opts, "anchor", ()), [-r, -r], [r, r * SQRT_2], "teardrop")
}

// --- Sectors ---

/// wedge(angles: [Tree, Tree]): Shape
///
/// Endless wedge between two angles about the Z axis, for cutting a part of a shape out.
///
/// - `angles`: `[from, to]`, in degrees anticlockwise from +X; `to` is above `from` by at most 360
///
/// The wedge holds every point whose direction from the Z axis lies between the angles.
/// It has no end, outwards or along Z.
/// A shape intersected with it keeps the part between the angles.
///
/// Notes:
/// - Field: exact, in 2D and in 3D.
/// - About 20 operations.
///
/// See also: `sector`, `revolve`.
///
/// Example: three quarters of a tube.
/// ```
/// tube([10, 7], 6)
///     .intersection(wedge([0, 270]))
/// ```
fn wedge(angles) {
    let a = _span(angles, "wedge");
    let p = _span_frame(a[0]);
    let s = sind(a[1]);
    let c = cosd(a[1]);
    // The distance to the edge from the origin along the half angle, in the
    // half of the plane that the fold leaves.
    let line = c * p[0] - s * p[1];
    let along = s * p[0] + c * p[1];
    _signed_sqrt(square(line) + square(min(along, 0.0)), compare(line, 0.0), line)
}

/// sector(r: Tree, angles: [Tree, Tree]): Shape
///
/// Pie slice: the part of a disc centred on the origin between two angles.
///
/// - `r`: the radius; it may vary over space
/// - `angles`: `[from, to]`, in degrees anticlockwise from +X; `to` is above `from` by at most 360
///
/// Notes:
/// - Field: exact.
/// - About 30 operations.
///
/// See also: `wedge`, `arc_stroke`.
///
/// References:
/// - Inigo Quilez, [2D distance functions](https://iquilezles.org/articles/distfunctions2d/), "Pie"
/// - [Circular sector, Wikipedia](https://en.wikipedia.org/wiki/Circular_sector)
///
/// Example: a round lid with an opening of 90 degrees.
/// ```
/// circle(25)
///     .difference(sector(20, [45, 135]))
/// ```
fn sector(r, angles) {
    let r = _field(r, "sector: r");
    let a = _span(angles, "sector");
    let p = _span_frame(a[0]);
    let s = sind(a[1]);
    let c = cosd(a[1]);
    let line = c * p[0] - s * p[1];
    let along = (s * p[0] + c * p[1]) / r;
    let edge = _signed_sqrt(_segment_dd(line, along, r), compare(line, 0.0), line);
    max(_hypot(p[0], p[1]) - r, edge)
}

// `[from, to]` in degrees as `[middle, half]`: the direction halfway
// between, and half the angle between.
fn _span(angles, what) {
    let a = _pair(angles, `${what}: angles`);
    if _is_number(a[0]) && _is_number(a[1]) && (a[1] <= a[0] || a[1] - a[0] > 360.0) {
        throw `${what}: angles must be [from, to] with to above from by at most 360, got ${angles}`;
    }
    [(a[0] + a[1]) * 0.5, (a[1] - a[0]) * 0.5]
}

// The point in the frame of a span whose middle is at `middle` degrees:
// `[across, along]`, `along` towards the middle and `across` away from it,
// folded onto one side, since a span is symmetric about its middle.
fn _span_frame(middle) {
    let c = cosd(middle);
    let s = sind(middle);
    [abs(y * c - x * s), x * c + y * s]
}

// --- Outlines by direction ---

/// polar_outline(r: Tree, dr: Tree): Shape
/// polar_outline(r: (a: Tree) => Tree): Shape
///
/// Closed outline given by its radius in each direction from the origin.
///
/// - `r`: the radius towards each point, positive; a tree that depends only on the direction, such as a tree of `atan2(y, x)`, or a function of `a`, the direction in degrees anticlockwise from +X
/// - `dr`: the derivative of `r` by the angle, anticlockwise, in radians
///
/// Every ray from the origin must cross the outline once.
/// Given a function, the derivative comes from a second call a tenth of a degree further round.
///
/// The field is the gap along the ray to the outline, `hypot(x, y) - r`, times the cosine of the angle between the ray and the outline's normal.
/// That cosine is `1 / sqrt(1 + (dr / r)^2)`.
///
/// Notes:
/// - Field: a distance to first order, close near the outline where it bends gently.
/// - The function form costs two evaluations of `r`.
///
/// See also: `morph`, `squircle_ray`, `polygon`.
///
/// References:
/// - [Polar coordinate system, Wikipedia](https://en.wikipedia.org/wiki/Polar_coordinate_system)
/// - [Star domain, Wikipedia](https://en.wikipedia.org/wiki/Star_domain), the outlines it takes
///
/// From OpenSCAD: `polygon([for (a = [0 : 359]) r(a) * [cos(a), sin(a)]])` is `polar_outline(|a| r(a))`.
///
/// Example: a knob with five lobes to grip, its edges rounded.
/// ```
/// polar_outline(|a| 15 + 2 * cosd(5 * a))
///     .extrude(10, #{round: 1})
/// ```
fn polar_outline(r, dr) {
    let r = _float(r);
    (_hypot(x, y) - r) / sqrt(1.0 + square(_float(dr) / r))
}

fn polar_outline(r) {
    if type_of(r) != "Fn" {
        throw `polar_outline: r must be a function of the angle, or come with its derivative dr, got ${type_of(r)}`;
    }
    let a = _atan2(y, x) * (180.0 / PI);
    let h = 0.1;
    let r0 = _float(r.call(a));
    polar_outline(r0, (_float(r.call(a + h)) - r0) / (h * PI / 180.0))
}

/// circle_ray(r: Tree): Ray
/// type Ray = #{ r: Tree, slope: Tree }
///
/// Circle centred on the origin as a ray, its radius in each direction, for `morph`.
///
/// - `r`: the radius; it may vary over space
///
/// The ray is `#{r: r, slope: 0}`: `r` is the radius towards each point, and `slope` the radius's derivative by the angle, over the radius.
///
/// See also: `morph`, `polygon_ray`, `star_ray`, `squircle_ray`.
///
/// Example: a circle that turns into a hexagon from z = 0 to 30.
/// ```
/// let disc = circle_ray(10);
/// let hexagon = polygon_ray(6, 12);
/// morph(disc, hexagon, linstep(0, 30, z))
///     .normalize_z()
///     .intersection(max(-z, z - 30))
/// ```
fn circle_ray(r) {
    #{r: _field(r, "circle_ray: r"), slope: 0.0}
}

/// polygon_ray(n: number, r: Tree): Ray
/// type Ray = #{ r: Tree, slope: Tree }
///
/// `regular_polygon(n, r)` as a ray, its radius in each direction, for `morph`.
///
/// - `n`: the number of sides, 3 or more
/// - `r`: the circumradius, from the centre to a vertex; it may vary over space
///
/// A vertex is on +X.
/// The ray's `r` is the radius towards each point, and its `slope` the radius's derivative by the angle, over the radius.
///
/// Notes:
/// - Both are exact.
///
/// See also: `morph`, `regular_polygon`, `circle_ray`.
///
/// Example: a square that turns into a circle from z = 0 to 30.
/// ```
/// let square = polygon_ray(4, 12);
/// let disc = circle_ray(10);
/// morph(square, disc, linstep(0, 30, z))
///     .normalize_z()
///     .intersection(max(-z, z - 30))
/// ```
fn polygon_ray(n, r) {
    if type_of(n) != "i64" || n < 3 {
        throw `polygon_ray: n must be an integer of at least 3, got ${n}`;
    }
    let r = _field(r, "polygon_ray: r");
    let an = PI / n;
    // The angle from the middle of the nearest side, whose distance from
    // the centre is the apothem.
    let b = (_atan2(y, x) + 2.0 * PI) % (2.0 * an) - an;
    #{r: r * cos(an) / cos(b), slope: tan(b)}
}

/// star_ray(n: number, r: [Tree, Tree]): Ray
/// type Ray = #{ r: Tree, slope: Tree }
///
/// `star(n, r)` as a ray, its radius in each direction, for `morph`.
///
/// - `n`: the number of points, 2 or more
/// - `r`: `[outer, inner]`, the radius of the points and that of the inner corners; either may vary over space
///
/// A point is on +X.
/// The ray's `r` is the radius towards each point, and its `slope` the radius's derivative by the angle, over the radius.
///
/// Notes:
/// - Both are exact.
///
/// See also: `morph`, `star`, `polygon_ray`.
///
/// Example: a hexagram that turns into a hexagon from z = 0 to 30.
/// ```
/// let star = star_ray(6, [12, 7]);
/// let hexagon = polygon_ray(6, 12);
/// morph(star, hexagon, linstep(0, 30, z))
///     .normalize_z()
///     .intersection(max(-z, z - 30))
/// ```
fn star_ray(n, r) {
    if type_of(n) != "i64" || n < 2 {
        throw `star_ray: n must be an integer of at least 2, got ${n}`;
    }
    let r = _pair(r, "star_ray: r");
    let an = PI / n;
    // As `star` folds the plane: the angle from the nearest inner corner,
    // whose edge runs to the point at `an`.
    let b = (_atan2(y, x) + 2.0 * PI) % (2.0 * an) - an;
    let c = abs(b);
    let ex = r[0] * cos(an) - r[1];
    let ey = r[0] * sin(an);
    let across = ey * cos(c) - ex * sin(c);
    // The fold turns the slope over on one side of each inner corner.
    #{r: ey * r[1] / across, slope: compare(b, 0.0) * (ey * sin(c) + ex * cos(c)) / across}
}

/// squircle_ray(u: Tree, v: Tree, s: number): Ray
/// type Ray = #{ r: Tree, slope: Tree }
///
/// The outline of `squircle(1, s)` as a ray, its radius towards a point, for `morph`.
///
/// - `u`, `v`: the point, in any plane: `x` and `y`, or coordinates within a tilted slice
/// - `s`: the squareness, from 0 up to below 1, as for `squircle`
///
/// The ray's `r` is the distance from the origin to the outline along the ray through `(u, v)`.
/// Its `slope` is the derivative of `r` by the angle, over `r`: the tangent of the angle between the ray and the outline's normal.
/// At the origin, which has no direction, `r` is 1 and `slope` 0.
///
/// A ray scales by multiplying its `r`, and its size may change with height.
/// `morph` blends two rays direction by direction, and `polar_outline` makes a shape of one.
///
/// Notes:
/// - Both are exact.
///
/// See also: `squircle`, `morph`, `polar_outline`, `loft_tilted`.
///
/// References:
/// - [Squircle, Wikipedia](https://en.wikipedia.org/wiki/Squircle), the Fernández-Guasti squircle
///
/// Example: a keycap's body, from a soft squircle at the bottom to a smaller, squarer one at the top.
/// ```
/// let a = squircle_ray(x, y, 0.8);
/// let b = squircle_ray(x, y, 0.95);
/// let start = #{r: 9 * a.r, slope: a.slope};
/// let end = #{r: 6 * b.r, slope: b.slope};
/// morph(start, end, linstep(0, 8, z))
///     .normalize_z()
///     .intersection(max(-z, z - 8))
/// ```
fn squircle_ray(u, v, s) {
    let u = _float(u);
    let v = _float(v);
    let s = _num(s, "squircle_ray: s");
    if s < 0.0 || s >= 1.0 {
        throw `squircle_ray: s must be from 0 up to below 1, got ${s}`;
    }
    // Written in sin 2a and cos 2a, which are rational in u and v: no
    // atan2, whose gradient is NaN at the centre.  As intervals they reach
    // far past +-1, which leaves the sqrt below NaN, so they are clamped to
    // what they are anyway.
    let dd = square(u) + square(v) + 1e-12;
    let sin2 = clamp(2.0 * u * v / dd, -1.0, 1.0);
    let cos2 = clamp((square(u) - square(v)) / dd, -1.0, 1.0);
    let c = sqrt(1.0 - s * s * square(sin2));
    #{r: sqrt(2.0 / (1.0 + c)), slope: s * s * sin2 * cos2 / (c * (1.0 + c))}
}

/// squircle(r: number, s: number, opts: #{ anchor?: Anchor2 } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Squircle centred on the origin, a shape between a circle and a square.
///
/// - `r`: half the side of the square, the radius along the axes
/// - `s`: the squareness, from 0 up to below 1
/// - `opts`:
///   - `anchor`: the point put on the origin, as for `rect`
///
/// At `s` = 0 it is a circle, and as `s` nears 1 it nears a square of side `2 r`.
/// It touches the square's sides at their middles, and only its corners round, more tightly as `s` grows.
/// The outline is the Fernández-Guasti squircle, `x^2 + y^2 - s^2 x^2 y^2 / r^2 = r^2`.
///
/// Notes:
/// - Field: a distance to first order, as `polar_outline` makes it from `squircle_ray`, exact on the outline.
///   For `r` = 10 and `s` = 0.9, it is within 2% of the distance up to 2 units off the outline.
///   At `s` = 0.99, whose corners are tight, that holds up to half a unit off.
/// - It is not the superellipse, `|x|^n + |y|^n = r^n`, which some designs call a squircle too.
///
/// See also: `squircle_ray`, `rect`, `ellipse`.
///
/// References:
/// - [Squircle, Wikipedia](https://en.wikipedia.org/wiki/Squircle)
/// - [Superellipse, Wikipedia](https://en.wikipedia.org/wiki/Superellipse)
///
/// From OpenSCAD: keycap designs sample this curve as `f_squircle`.
///
/// Example: a keycap's soft square, extruded with rounded rims.
/// ```
/// squircle(9, 0.9).extrude(8, #{round: 1})
/// ```
fn squircle(r, s) {
    squircle(r, s, #{})
}

fn squircle(r, s, opts) {
    _opts(opts, ["anchor"], "squircle");
    let r = _num(r, "squircle: r");
    let s = _num(s, "squircle: s");
    if s < 0.0 || s >= 1.0 {
        throw `squircle: s must be from 0 up to below 1, got ${s}`;
    }
    let ray = squircle_ray(x, y, s);
    let shape = polar_outline(r * ray.r, r * ray.r * ray.slope);
    _anchor(shape, _opt(opts, "anchor", ()), [-r, -r], [r, r], "squircle")
}

// --- Polygons ---

/// regular_polygon(n: number, r: Tree, opts: #{ round?: Tree, anchor?: Anchor2, normalize?: bool } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Regular polygon centred on the origin, a vertex on +X, its corners sharp or rounded.
///
/// - `n`: the number of sides, 3 or more
/// - `r`: the circumradius, from the centre to a vertex; it may vary over space
/// - `opts`:
///   - `round`: the corners' radius, at most that of the inscribed circle, which it then gives; it may vary over space
///   - `anchor`: the point of its bounding box put on the origin, as for `rect`
///   - `normalize`: `false` to skip the correction that keeps the field a distance when `round` varies; see the notes
///
/// An `r` that is a tree of `z` makes the slices of a pyramid, each exact.
///
/// Notes:
/// - Field: exact, rounded too.
/// - A `round` that varies keeps the field a distance to first order, at the cost of a second evaluation.
/// - `normalize: false` skips that correction: twice as fast, but offsets and shells come out uneven.
/// - About 25 operations; rounded, about 60.
///
/// See also: `hexagon_af`, `star`, `regular_polygon_points`, `polygon_ray`.
///
/// References:
/// - [Regular polygon, Wikipedia](https://en.wikipedia.org/wiki/Regular_polygon)
///
/// From OpenSCAD: `circle(r, $fn = n)` is `regular_polygon(n, r)`, its vertex on +X as well.
///
/// Example: an octagonal coaster with rounded corners.
/// ```
/// regular_polygon(8, 45, #{round: 4})
///     .extrude([0, 4], #{round: [0, 1]})
/// ```
fn regular_polygon(n, r) {
    regular_polygon(n, r, #{})
}

fn regular_polygon(n, r, opts) {
    _opts(opts, ["round", "anchor", "normalize"], "regular_polygon");
    if type_of(n) != "i64" || n < 3 {
        throw `regular_polygon: n must be an integer of at least 3, got ${n}`;
    }
    let r = _field(r, "regular_polygon: r");
    let an = PI / n;
    let shape = if "round" in opts {
        // A star whose inner corners lie on the sides, so that they are
        // no corners at all.
        let k = _field(opts.round, "regular_polygon: round");
        _vary(|k| _rounded_star(n, r, r * cos(an), k, 0.0), k, opts)
    } else {
        // Fold the plane into half a sector, then measure to that half-edge.
        let b = _atan2(y, x) % (2.0 * an) - an;
        let l = _hypot(x, y);
        let px = l * cos(b) - r * cos(an);
        let py = l * abs(sin(b)) - r * sin(an);
        let py = py + clamp(-py, 0.0, r * sin(an));
        _signed_sqrt(square(px) + square(py), compare(px, 0.0), px)
    };
    if !("anchor" in opts) {
        return shape;
    }
    let corners = [];
    for i in 0..n {
        corners.push([r * cos(2.0 * an * i), r * sin(2.0 * an * i)]);
    }
    _anchor_points(shape, opts, corners, "regular_polygon")
}

/// star(n: number, r: [Tree, Tree], opts: #{ round?: Tree | [number, number], anchor?: Anchor2, normalize?: bool } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Star centred on the origin, a point on +X, its corners sharp or rounded.
///
/// - `n`: the number of points, 2 or more
/// - `r`: `[outer, inner]`, the radius of the points and that of the inner corners; either may vary over space
/// - `opts`:
///   - `round`: the corners' radius, which may vary over space; or `[outer, inner]`, two numbers, one for the points and one for the inner corners
///   - `anchor`: the point of its bounding box put on the origin, as for `rect`
///   - `normalize`: `false` to skip the correction that keeps the field a distance when `round` varies; see the notes
///
/// The outline zigzags between `n` points at radius `outer` and `n` inner corners at radius `inner`, halfway between them.
/// At `inner = outer * cos(180 / n)` the star is the regular polygon of `n` sides.
/// With `inner` larger still, the inner corners point outwards, and the star becomes a rosette.
/// Two triangles of circumradius `r` make `star(6, [r, r / sqrt(3.0)])`.
///
/// Each rounded corner is an arc tangent to its two edges.
/// Two arcs too large for the edge between them are both made smaller, in proportion, until they fit.
///
/// Notes:
/// - Field: exact, rounded too.
/// - A `round` that varies keeps the field a distance to first order, at the cost of a second evaluation.
/// - `normalize: false` skips that correction: twice as fast, but offsets and shells come out uneven.
/// - About 30 operations; rounded, about 60.
///
/// See also: `regular_polygon`, `star_points`, `star_ray`.
///
/// References:
/// - [Star polygon, Wikipedia](https://en.wikipedia.org/wiki/Star_polygon)
///
/// From OpenSCAD: for a star whose inner corners point inwards, `offset(-k) offset(2 * k) offset(-k)` is `#{round: k}`, and `offset(-b) offset(b) offset(a) offset(-a)` is `#{round: [a, b]}`.
///
/// Example: a hexagram rounded both ways.
/// ```
/// star(6, [40, 40 / sqrt(3.0)], #{round: 6})
/// ```
/// Example: a vase that is a hexagon at the bottom and a hexagram at the top.
/// ```
/// let inner = lerp(17.32, 11.55, linstep(0, 40, z));
/// star(6, [20, inner])
///     .normalize_z()
///     .intersection(max(-z, z - 40))
/// ```
fn star(n, r) {
    star(n, r, #{})
}

fn star(n, r, opts) {
    _opts(opts, ["round", "anchor", "normalize"], "star");
    if type_of(n) != "i64" || n < 2 {
        throw `star: n must be an integer of at least 2, got ${n}`;
    }
    let r = _pair(r, "star: r");
    let ro = r[0];
    let ri = r[1];
    let an = PI / n;
    let l = _hypot(x, y);
    let d = if "round" in opts {
        let k = opts.round;
        if type_of(k) == "array" {
            if k.len() != 2 {
                throw `star: round must be a radius or [outer, inner], got ${k}`;
            }
            _rounded_star(n, ro, ri, _num(k[0], "star: round"), _num(k[1], "star: round"))
        } else {
            _vary(|k| _rounded_star(n, ro, ri, k, k), _field(k, "star: round"), opts)
        }
    } else {
        // Fold the plane into the half sector between an inner corner (on
        // +X after the fold) and a point, then measure to the edge between
        // them; the origin's side of that edge is inside.
        let c = abs(_atan2(y, x) % (2.0 * an) - an);
        let wx = l * cos(c) - ri;
        let wy = l * sin(c);
        let ex = ro * cos(an) - ri;
        let ey = ro * sin(an);
        let el = _hypot(ex, ey);
        let line = (ey * wx - ex * wy) / el;
        let t = (wx * ex + wy * ey) / (ex * ex + ey * ey);
        _signed_sqrt(_segment_dd(line, t, el), compare(ey * wx, ex * wy), line)
    };
    // No closer than the circle through the points: changes no value, but
    // lets interval arithmetic see where the star ends.
    let shape = max(d, l - ro);
    if !("anchor" in opts) {
        return shape;
    }
    let corners = [];
    for i in 0..n {
        corners.push([ro * cos(2.0 * an * i), ro * sin(2.0 * an * i)]);
        corners.push([ri * cos(2.0 * an * i + an), ri * sin(2.0 * an * i + an)]);
    }
    _anchor_points(shape, opts, corners, "star")
}

/// hexagon_af(af: Tree, opts: #{ anchor?: Anchor2 } = #{}): Shape
/// type Anchor2 = Vec2 | "center" | "left" | "right" | "front" | "back"
///
/// Regular hexagon centred on the origin, sized across its flats ("af"), two of its flats parallel to the X axis.
///
/// - `af`: the distance across flats, between two opposite sides; it may vary over space
/// - `opts`:
///   - `anchor`: the point of its bounding box put on the origin, as for `rect`
///
/// Nuts, bolt heads and hex keys are sized across their flats, and their tables give that size.
/// `regular_polygon(6, r)` is the same hexagon by its circumradius, `af / sqrt(3)`.
///
/// Notes:
/// - Field: exact.
///
/// See also: `regular_polygon`.
///
/// References:
/// - [Hexagon, Wikipedia](https://en.wikipedia.org/wiki/Hexagon)
/// - [Nut (hardware), Wikipedia](https://en.wikipedia.org/wiki/Nut_%28hardware%29)
///
/// Example: a pocket for the nut of a 3 mm metric screw, 5.5 mm across flats, with 0.2 mm of clearance.
/// ```
/// let cup = cylinder(6, [0, 6]);
/// let pocket = hexagon_af(5.5 + 0.4).extrude([3, 7]);
/// cup.difference(pocket)
/// ```
fn hexagon_af(af) {
    hexagon_af(af, #{})
}

fn hexagon_af(af, opts) {
    regular_polygon(6, _field(af, "hexagon_af: af") / sqrt(3.0), opts)
}

// The exact field of a star of `n` points with radii `ro` and `ri`, its
// points rounded by `kp` and its inner corners by `ki`.
//
// As `star` does, the plane folds into the half sector from an inner corner
// I, on +X, to a point P.  There the outline is an arc round I, the edge,
// and an arc round P.  The lines through each arc's centre square to the
// edge split the half sector in three: beyond them the arcs' circles give
// the sign, between them the edge's line does.  The distance is the nearer
// of the edge and the arc on the point's side.
fn _rounded_star(n, ro, ri, kp, ki) {
    let an = PI / n;
    let c = abs(_atan2(y, x) % (2.0 * an) - an);
    let l = _hypot(x, y);
    let wx = l * cos(c);
    let wy = l * sin(c);
    let px = ro * cos(an);
    let py = ro * sin(an);
    let el = _hypot(px - ri, py);
    let ux = (px - ri) / el;
    let uy = py / el;
    // How far along the edge each arc ends: the radius times the cotangent
    // of half the corner's angle.  At I that half angle's cosine is -ux,
    // its sine uy; I is concave where ux > 0, flat at 0.
    let tp = kp * (ux * cos(an) + uy * sin(an)) / (uy * cos(an) - ux * sin(an));
    let ti = ki * abs(ux) / uy;
    // Arcs too large for the edge shrink together until they meet.
    let fit = min(1.0, el / max(tp + ti, 1e-9));
    let kp = kp * fit;
    let ki = ki * fit;
    let tp = tp * fit;
    let ti = ti * fit;
    let si = _select_less(0.0, ux, -1.0, 1.0);
    // The arcs' ends on the edge, and their centres, on the side of the
    // outline the arc bends round.
    let ix = ri + ti * ux;
    let iy = ti * uy;
    let ix_c = ix - si * ki * uy;
    let iy_c = iy + si * ki * ux;
    let qx = px - tp * ux;
    let qy = py - tp * uy;
    let px_c = qx - kp * uy;
    let py_c = qy + kp * ux;
    // Along the edge from I's arc, and across it, outwards.
    let along = (wx - ix) * ux + (wy - iy) * uy;
    let line = (wx - ix) * uy - (wy - iy) * ux;
    let span = el - ti - tp;
    let edge = square(line) + square(along - clamp(along, 0.0, span));
    let arc_i = si * (_hypot(wx - ix_c, wy - iy_c) - ki);
    let arc_p = _hypot(wx - px_c, wy - py_c) - kp;
    let v = _select_less(along, 0.0, arc_i, _select_less(span, along, arc_p, line));
    let dd = min(edge, _select_less(along, 0.0, square(arc_i), _select_less(span, along, square(arc_p), edge)));
    // The star lies within the circle through its points, so the distance
    // to it is never below the circle's and `max` keeps it as it is; but
    // fitted bounds see the circle where they cannot see through the arcs.
    max(_signed_sqrt(dd, compare(v, 0.0), v), l - ro)
}

// `shape` anchored by the bounding box of its outline's `corners`.
fn _anchor_points(shape, opts, corners, what) {
    let lo = corners[0];
    let hi = corners[0];
    for p in corners {
        lo = [min(lo[0], p[0]), min(lo[1], p[1])];
        hi = [max(hi[0], p[0]), max(hi[1], p[1])];
    }
    _anchor(shape, _opt(opts, "anchor", ()), lo, hi, what)
}

/// polygon(points: Outline): Shape
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | [number, number, #{ arc: number }]
///
/// Polygon through a list of points, its corners sharp.
///
/// - `points`: the corners, each `[x, y]`; or a list of such lists, the loops of an outline with several parts or holes, as `polygon_clip` gives them
///
/// The points go in order round the outline, either way round, and the last joins back to the first.
/// The outline must not cross itself.
/// Where loops lie inside each other, the inner ones are holes.
///
/// A point `[x, y, #{arc: r}]` makes the edge to the next point an arc, as in `rounded_polygon`.
/// Such an outline is a `rounded_polygon` with every corner sharp.
///
/// Notes:
/// - Field: exact.
/// - About 40 operations a point.
///
/// See also: `rounded_polygon`, `polygon_clip`, `miter_offset`, `regular_polygon_points`.
///
/// References:
/// - Inigo Quilez, [2D distance functions](https://iquilezles.org/articles/distfunctions2d/), "Polygon"
///
/// Example: a triangular gusset, 20 by 10, to stiffen a corner.
/// ```
/// polygon([[0, 0], [20, 0], [0, 10]]).extrude(3)
/// ```
/// Example: a square frame, its hole a loop of its own.
/// ```
/// let outer = [[0, 0], [20, 0], [20, 20], [0, 20]];
/// let inner = [[5, 5], [15, 5], [15, 15], [5, 15]];
/// polygon([outer, inner])
/// ```
fn polygon(points) {
    let loops = _outline(points, "polygon");
    if loops.some(|ring| ring.some(|w| type_of(w.k) != "()")) {
        throw "polygon: a corner's radius is for rounded_polygon";
    }
    if loops.some(|ring| ring.some(|w| type_of(w.arc) != "()")) {
        return rounded_polygon(points, 0.0);
    }
    // Inigo Quilez's sdPolygon: the nearest edge gives the distance, the
    // parity of edge crossings to the right of the point gives the sign;
    // the nearest edge's line gives the gradient on the outline.  Every
    // loop has the inside on its left, so the line is positive on its
    // right.
    let d = ();
    let line = ();
    let s = 1.0;
    for ring in loops {
        let n = ring.len();
        for i in 0..n {
            let a = ring[i].p;
            let b = ring[(i + n - 1) % n].p;
            let ex = b[0] - a[0];
            let ey = b[1] - a[1];
            let wx = x - a[0];
            let wy = y - a[1];
            let ee = ex * ex + ey * ey;
            let el = sqrt(ee);
            let l = (ex * wy - ey * wx) / el;
            let dd = _segment_dd(l, (wx * ex + wy * ey) / ee, el);
            line = if type_of(d) == "()" { l } else { _select_less(dd, d, l, line) };
            d = if type_of(d) == "()" { dd } else { min(d, dd) };
            let c1 = 1.0 - _less(y, a[1]);
            let c2 = _less(y, b[1]);
            let c3 = _less(ey * wx, ex * wy);
            let flip = c1 * c2 * c3 + (1.0 - c1) * (1.0 - c2) * (1.0 - c3);
            s = s * (1.0 - 2.0 * flip);
        }
    }
    let lo = loops[0][0].p;
    let hi = lo;
    for ring in loops {
        for w in ring {
            lo = [min(lo[0], w.p[0]), min(lo[1], w.p[1])];
            hi = [max(hi[0], w.p[0]), max(hi[1], w.p[1])];
        }
    }
    max(_signed_sqrt(d, s, line), _box_bound(lo, hi))
}

/// rounded_polygon(points: Outline, r: number, opts: #{ concave?: number } = #{}): Shape
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | [number, number, number] | [number, number, #{ arc?: number, round?: number }]
///
/// Polygon through a list of points, its corners rounded and its edges straight or arcs.
///
/// - `points`: the corners, each `[x, y]` as in `polygon`, or `[x, y, k]` for a corner with a radius `k` of its own; or a list of such lists, the loops of an outline with several parts or holes
/// - `r`: the radius of the convex corners
/// - `opts`:
///   - `concave`: the radius of the concave corners, `r` unless given
///
/// Each corner is an arc tangent to its two edges.
/// `[x, y, 0]` keeps a corner sharp, and an `r` of 0 keeps every convex one sharp.
///
/// A point `[x, y, #{arc: a}]` makes the edge to the next point an arc of radius `abs(a)`, the shorter way round.
/// The arc runs anticlockwise for a positive `a`, clockwise for a negative one.
/// `#{arc: a, round: k}` gives the point's corner a radius of its own as well.
/// Where a straight edge meets an arc tangent to it, there is no corner.
/// A circle is two half circles: `[[r, 0, #{arc: r}], [-r, 0, #{arc: r}]]`.
///
/// Where the arcs of two convex corners, or of two concave ones, do not fit on the edge between them, the edge goes.
/// One arc then joins the edges either side, as an opening or a closing does.
/// Where they turn opposite ways, it throws, naming the edge.
///
/// Notes:
/// - Field: exact.
/// - About 90 operations a corner, 60 a sharp one, and 5 more where the edge after it is an arc.
///
/// See also: `polygon`, `polygon_clip`, `offset`.
///
/// References:
/// - [Opening (morphology), Wikipedia](https://en.wikipedia.org/wiki/Opening_%28morphology%29), and closing
///
/// From OpenSCAD: `offset(-r) offset(2 * r) offset(-r)` is `rounded_polygon(points, r)`, and `offset(-c) offset(c) offset(r) offset(-r)` is `rounded_polygon(points, r, #{concave: c})`.
///
/// Example: the profile of an angle bracket, its outer corners rounded by 3 and its inner one by 1.
/// ```
/// let outline = [
///     [0, 0], [30, 0], [30, 8],
///     [8, 8], [8, 20], [0, 20],
/// ];
/// rounded_polygon(outline, 3, #{concave: 1})
/// ```
/// Example: a tab with a bulging end, an arc of radius 12, its corners rounded by 2.
/// ```
/// let outline = [
///     [0, 0],
///     [30, 0, #{arc: 12}],
///     [30, 16],
///     [0, 16],
/// ];
/// rounded_polygon(outline, 2)
/// ```
fn rounded_polygon(points, r) {
    rounded_polygon(points, r, #{})
}

fn rounded_polygon(points, r, opts) {
    _opts(opts, ["concave"], "rounded_polygon");
    let r = _num(r, "rounded_polygon: r");
    let concave = _num(_opt(opts, "concave", r), "rounded_polygon: concave");
    let loops = _outline(points, "rounded_polygon").map(|ring| _rounded_loop(ring, r, concave));
    let box = _pieces_box(loops);
    max(_outline_field(loops), _box_bound(box[0], box[1]))
}

// The pieces of one loop of a rounded outline, in order: each corner's
// arc, then what is left of the edge to the next corner.
fn _rounded_loop(ring, r, concave) {
    let what = "rounded_polygon";
    let ring = _straight_on(ring);
    let edges = _loop_edges(ring, what);
    if edges.len() < 3 && edges.all(|e| type_of(e.arc) == "()") {
        throw `${what}: needs at least 3 corners, got ${edges.len()}`;
    }
    // Corner i joins edge i - 1 to edge i.
    let corners = [];
    let n = edges.len();
    for i in 0..n {
        corners.push(_corner_arc(edges[(i + n - 1) % n], edges[i], ring[i].k, r, concave));
    }
    // Every edge must hold the arcs at its ends.  Where two that turn the
    // same way overlap, the edge goes, and one arc joins its neighbours.
    loop {
        let n = edges.len();
        let short = -1;
        for i in 0..n {
            let e = edges[i];
            let f0 = _edge_param(e, _corner_end(corners[i], e, false));
            let f1 = _edge_param(e, _corner_end(corners[(i + 1) % n], e, true));
            if f0 < -1e-6 || f1 > 1.0 + 1e-6 {
                throw `${what}: the arc at ${e.a} or ${e.b} reaches past the edge between them; give it a smaller radius`;
            }
            if f0 > f1 + 1e-6 {
                short = i;
                break;
            }
        }
        if short < 0 {
            break;
        }
        let e = edges[short];
        let c0 = corners[short];
        let c1 = corners[(short + 1) % n];
        let kind = if type_of(e.arc) == "()" { "an edge" } else { "an arc" };
        let rounded = type_of(c0.k) != "()" && type_of(c1.k) != "()" && c0.k > 0.0;
        let enough = n >= 4 || edges.some(|e| type_of(e.arc) != "()");
        if !rounded || c0.s != c1.s || c0.k != c1.k || !enough {
            let l = _dist(e.a, e.b);
            throw `${what}: the arcs at ${e.a} and ${e.b} do not fit on ${kind} ${l} long between them; give them smaller radii`;
        }
        let near = [(c0.c[0] + c1.c[0]) * 0.5, (c0.c[1] + c1.c[1]) * 0.5];
        let before = edges[(short + n - 1) % n];
        let after = edges[(short + 1) % n];
        let joined = _fillet(before, after, c0.s, c0.k, near);
        if type_of(joined) == "()" || _edge_distance(e, joined.c) < c0.k * (1.0 - 1e-6) {
            throw `${what}: the arcs at ${e.a} and ${e.b} do not fit on ${kind} between them, and no arc joins the edges either side; give them smaller radii`;
        }
        edges.remove(short);
        corners.remove(short);
        corners[short % (n - 1)] = joined;
    }
    let n = edges.len();
    let pieces = [];
    for i in 0..n {
        pieces += _corner_pieces(corners[i]);
        let e = edges[i];
        let start = _corner_end(corners[i], e, false);
        let end = _corner_end(corners[(i + 1) % n], e, true);
        // An edge the arcs take all of, to rounding, is left out: a sliver
        // of it, pointing back, would give the wrong side past its ends.
        if _dist(start, end) > 1e-6 && _edge_param(e, end) - _edge_param(e, start) > 1e-6 {
            pieces.push(_edge_piece(_edge_part(e, start, end)));
        }
    }
    pieces
}

// The loop without the points where two straight edges go straight on:
// they are no corners.
fn _straight_on(ring) {
    let n = ring.len();
    let out = [];
    for i in 0..n {
        let before = ring[(i + n - 1) % n];
        let a = before.p;
        let b = ring[i].p;
        let c = ring[(i + 1) % n].p;
        if type_of(before.arc) == "()" && type_of(ring[i].arc) == "()" {
            let d1 = [b[0] - a[0], b[1] - a[1]];
            let d2 = [c[0] - b[0], c[1] - b[1]];
            let turn = cross(d1, d2) / (norm(d1) * norm(d2));
            if abs(turn) < 1e-9 {
                if dot(d1, d2) < 0.0 {
                    throw `rounded_polygon: the outline turns back on itself at ${b}`;
                }
                continue;
            }
        }
        out.push(ring[i]);
    }
    out
}

// The arc at the corner from the edge `e_in` to `e_out`: `k` if the
// point gives a radius, `r` if the corner is convex and `concave` if not.
// A map: `s` 1 if convex, -1 if not; `k` the radius; `c` the centre;
// `t_in` and `t_out` where it meets the edges; `d1` and `d2` the
// directions there; `at` the point.  Where the edges meet tangent, `k` is
// `()`: no corner.
fn _corner_arc(e_in, e_out, k, r, concave) {
    let d1 = _edge_tangent(e_in, 1.0);
    let d2 = _edge_tangent(e_out, 0.0);
    let turn = d1[0] * d2[1] - d1[1] * d2[0];
    let at = e_out.a;
    if abs(turn) < 1e-9 {
        if d1[0] * d2[0] + d1[1] * d2[1] < 0.0 {
            throw `rounded_polygon: the outline turns back on itself at ${at}`;
        }
        return #{k: (), at: at};
    }
    let s = if turn > 0.0 { 1.0 } else { -1.0 };
    let k = if type_of(k) != "()" { k } else if s > 0.0 { r } else { concave };
    if k == 0.0 {
        return #{s: s, k: 0.0, c: at, t_in: at, t_out: at, d1: d1, d2: d2, at: at};
    }
    let arc = _fillet(e_in, e_out, s, k, at);
    if type_of(arc) == "()" {
        throw `rounded_polygon: no arc of radius ${k} fits the corner at ${at}`;
    }
    arc
}

// The arc of radius `k` tangent to the edges `e_in` and `e_out`, on their
// left for `s` = 1, their right for -1, nearest `near`; `()` if none.  Its
// centre is where the edges' lines or circles, moved `k` that way, meet.
fn _fillet(e_in, e_out, s, k, near) {
    let o1 = _offset_curve(e_in, s * k);
    let o2 = _offset_curve(e_out, s * k);
    if type_of(o1) == "()" || type_of(o2) == "()" {
        return ();
    }
    let c = ();
    for p in _curve_meetings(o1, o2) {
        if type_of(c) == "()" || _dist(p, near) < _dist(c, near) {
            c = p;
        }
    }
    if type_of(c) == "()" {
        return ();
    }
    let t_in = _foot(e_in, c);
    let t_out = _foot(e_out, c);
    #{
        s: s, k: k, c: c, t_in: t_in, t_out: t_out, at: near,
        d1: _edge_tangent(e_in, _edge_param(e_in, t_in)),
        d2: _edge_tangent(e_out, _edge_param(e_out, t_out)),
    }
}

// The line or circle of the edge `e`, moved `h` to its left, as an edge
// for `_curve_meetings`; `()` where a circle would shrink to nothing.
fn _offset_curve(e, h) {
    if type_of(e.arc) == "()" {
        let d = _edge_tangent(e, 0.0);
        let a = [e.a[0] - h * d[1], e.a[1] + h * d[0]];
        return #{a: a, b: [a[0] + d[0], a[1] + d[1]], arc: ()};
    }
    // An anticlockwise arc has its centre on its left.
    let r = if e.arc.ccw { e.arc.r - h } else { e.arc.r + h };
    if r <= 0.0 {
        return ();
    }
    #{a: (), b: (), arc: #{c: e.arc.c, r: r}}
}

// The point of the edge's line or circle nearest `p`.
fn _foot(e, p) {
    if type_of(e.arc) == "()" {
        return _edge_point(e, _edge_param(e, p));
    }
    let c = e.arc.c;
    let l = _dist(p, c);
    [c[0] + (p[0] - c[0]) * e.arc.r / l, c[1] + (p[1] - c[1]) * e.arc.r / l]
}

// Where a corner's arc leaves the edge `e` after it, or, at its `end`,
// meets the edge `e` before it.
fn _corner_end(corner, e, end) {
    if type_of(corner.k) == "()" {
        if end { e.b } else { e.a }
    } else if end {
        corner.t_in
    } else {
        corner.t_out
    }
}

// A corner's arc as pieces for `_outline_field`: none where the edges
// meet tangent, two for an arc of more than half a turn, whose ends the
// field's wedge cannot tell apart.
fn _corner_pieces(corner) {
    if type_of(corner.k) == "()" {
        return [];
    }
    let piece = #{kind: "arc", c: corner.c, r: corner.k, s: corner.s, a: corner.t_in, b: corner.t_out, d1: corner.d1, d2: corner.d2};
    if corner.k == 0.0 {
        return [piece];
    }
    let a0 = _angle_of(corner.t_in, corner.c);
    let turn = (_angle_of(corner.t_out, corner.c) - a0) * corner.s;
    let turn = turn - 2.0 * PI * floor(turn / (2.0 * PI));
    if turn <= PI {
        return [piece];
    }
    let m = a0 + corner.s * turn * 0.5;
    let mid = [corner.c[0] + corner.k * cos(m), corner.c[1] + corner.k * sin(m)];
    let d = [-corner.s * sin(m), corner.s * cos(m)];
    let first = piece;
    first.b = mid;
    first.d2 = d;
    let second = piece;
    second.a = mid;
    second.d1 = d;
    [first, second]
}

// An edge as a piece for `_outline_field`.
fn _edge_piece(e) {
    if type_of(e.arc) == "()" {
        return #{kind: "line", a: e.a, b: e.b};
    }
    #{
        kind: "arc", c: e.arc.c, r: e.arc.r, s: if e.arc.ccw { 1.0 } else { -1.0 },
        a: e.a, b: e.b, d1: _edge_tangent(e, 0.0), d2: _edge_tangent(e, 1.0),
    }
}

// The box round loops of pieces: their ends, and the points of their
// arcs furthest along X and Y.
fn _pieces_box(loops) {
    let lo = loops[0][0].a;
    let hi = lo;
    for pieces in loops {
        for p in pieces {
            let ends = [p.a, p.b];
            if p.kind == "arc" && p.r > 0.0 {
                for u in [[1.0, 0.0], [0.0, 1.0], [-1.0, 0.0], [0.0, -1.0]] {
                    if -(u[0] * p.d1[0] + u[1] * p.d1[1]) <= 0.0 && u[0] * p.d2[0] + u[1] * p.d2[1] <= 0.0 {
                        ends.push([p.c[0] + p.r * u[0], p.c[1] + p.r * u[1]]);
                    }
                }
            }
            for q in ends {
                lo = [min(lo[0], q[0]), min(lo[1], q[1])];
                hi = [max(hi[0], q[0]), max(hi[1], q[1])];
            }
        }
    }
    [lo, hi]
}

// The exact field of loops of pieces: lines `#{kind: "line", a, b}` and
// arcs `#{kind: "arc", c, r, s, a, b, d1, d2}`, `s` 1 where the centre is
// inside and -1 where it is outside, `d1` and `d2` the directions at the
// ends; each loop has the inside on its left.  Each piece gives its
// squared distance, and a signed one, to its line or circle; the nearest
// decides.  Beyond its ends, a piece takes the sign of what joins it at
// the nearer end: at a sharp corner, an arc of radius 0, the line or
// circle of the piece beside it may have the wrong side, where the
// corner's own is right, and the other way round.
fn _outline_field(loops) {
    let d = ();
    let v = ();
    for pieces in loops {
        let n = pieces.len();
        let own = pieces.map(|p| _piece_side(p));
        for i in 0..n {
            let p = pieces[i];
            let before = own[(i + n - 1) % n];
            let after = own[(i + 1) % n];
            let dd = ();
            let side = ();
            if p.kind == "line" {
                let ex = p.b[0] - p.a[0];
                let ey = p.b[1] - p.a[1];
                let ee = ex * ex + ey * ey;
                let t = ((x - p.a[0]) * ex + (y - p.a[1]) * ey) / ee;
                dd = _segment_dd(own[i], t, sqrt(ee));
                side = _select_less(t, 0.0, before, _select_less(1.0, t, after, own[i]));
            } else if p.r == 0.0 {
                // A sharp corner is nearest only in its wedge and on its
                // edges, where its own sign is right; past them an edge is
                // nearer.  Its ends are one point, so telling them apart,
                // where it ties with an edge, would pick a side at random.
                dd = square(own[i]);
                side = own[i];
            } else {
                // In the wedge from the centre between the ends' normals,
                // the distance to the circle; elsewhere, to the nearer end.
                let cx = x - p.c[0];
                let cy = y - p.c[1];
                let wedge = max(-(cx * p.d1[0] + cy * p.d1[1]), cx * p.d2[0] + cy * p.d2[1]);
                let to_a = square(x - p.a[0]) + square(y - p.a[1]);
                let to_b = square(x - p.b[0]) + square(y - p.b[1]);
                dd = _select_less(wedge, 0.0, square(own[i]), min(to_a, to_b));
                side = _select_less(wedge, 0.0, own[i], _select_less(to_a, to_b, before, after));
            }
            if type_of(d) == "()" {
                d = dd;
                v = side;
            } else {
                v = _select_less(dd, d, side, v);
                d = min(d, dd);
            }
        }
    }
    _signed_sqrt(d, compare(v, 0.0), v)
}

// A piece's signed distance to its line or circle, positive outside.  At
// a sharp corner, an arc of radius 0, the distance from the point has no
// gradient there, so the edges' lines through it give one.
fn _piece_side(p) {
    if p.kind == "line" {
        let ex = p.b[0] - p.a[0];
        let ey = p.b[1] - p.a[1];
        return ((x - p.a[0]) * ey - (y - p.a[1]) * ex) / sqrt(ex * ex + ey * ey);
    }
    let cx = x - p.c[0];
    let cy = y - p.c[1];
    if p.r > 0.0 {
        return p.s * (_hypot(cx, cy) - p.r);
    }
    let l1 = cx * p.d1[1] - cy * p.d1[0];
    let l2 = cx * p.d2[1] - cy * p.d2[0];
    or(p.s * _hypot(cx, cy), if p.s > 0.0 { max(l1, l2) } else { min(l1, l2) })
}

/// miter_offset(points: Vec2[], d: number): Vec2[]
///
/// The corners of a polygon moved so that its edges move outwards by `d` and its corners stay sharp.
///
/// - `points`: the corners, each `[x, y]`, as in `polygon`, either way round
/// - `d`: the distance; a negative one moves the edges inwards
///
/// Every edge moves `d` along its outward normal, and each corner goes to where its two edges now meet.
/// It works on numbers when the script runs, so it makes no field.
///
/// Notes:
/// - A sharp corner moves further than `d`, by `d / sin(a / 2)` for a corner of angle `a`.
/// - A `d` large enough to make an edge vanish leaves a polygon that crosses itself.
///
/// See also: `offset`, `polygon`, `polygon_clip`.
///
/// References:
/// - [Parallel curve, Wikipedia](https://en.wikipedia.org/wiki/Parallel_curve)
///
/// Example: a pocket 0.3 mm larger than a triangular part all round, its corners still sharp.
/// ```
/// let tri = [[-10, -8], [12, -8], [-10, 8]];
/// rect([40, 30]).difference(polygon(miter_offset(tri, 0.3)))
/// ```
fn miter_offset(points, d) {
    let d = _num(d, "miter_offset: d");
    let v = [];
    for p in points {
        v.push(_vec2(p, "miter_offset: a point"));
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

// --- Outlines of lines and arcs ---
//
// `polygon`, `rounded_polygon` and `polygon_clip` read an outline as one
// list of points or a list of such lists, its loops.  Here a loop is a
// list of vertices, `#{p, k, arc}`: the point, its corner's own radius or
// `()`, and the signed radius of the arc to the next vertex or `()` for a
// straight edge.  An edge is `#{a, b, arc}`, from `a` to `b`, `arc` `()`
// or `#{c, r, ccw, from, sweep}`: the centre, the radius, whether it runs
// anticlockwise, the angle of `a` round the centre and how far it turns,
// in radians, at most half a turn.

// The loops of the outline `v`, each turned so that the inside is on its
// left: anticlockwise round a part, clockwise round a hole, by how many
// other loops hold it.  Repeated points are dropped.
fn _outline(v, what) {
    if type_of(v) != "array" || v.is_empty() {
        throw `${what}: points must be an array of points [x, y], got ${v}`;
    }
    let several = type_of(v[0]) == "array" && !v[0].is_empty() && type_of(v[0][0]) == "array";
    let loops = [];
    for list in if several { v } else { [v] } {
        if type_of(list) != "array" {
            throw `${what}: a loop must be an array of points, got ${list}`;
        }
        let ring = _outline_loop(list, what);
        if ring.len() < 3 && ring.all(|w| type_of(w.arc) == "()") {
            throw `${what}: a loop needs at least 3 points, or 2 joined by arcs, got ${list}`;
        }
        loops.push(ring);
    }
    let edges = loops.map(|ring| _loop_edges(ring, what));
    for i in 0..loops.len() {
        let probe = _edge_point(edges[i][0], 0.5);
        let depth = 0;
        for j in 0..loops.len() {
            if j != i && _inside(probe, edges[j]) {
                depth += 1;
            }
        }
        if (_loop_area(edges[i]) < 0.0) == (depth % 2 == 0) {
            loops[i] = _reverse_loop(loops[i]);
        }
    }
    loops
}

// A loop's vertices from its points, a point that repeats the one before
// it dropped: the arc from it, and its radius if the first has none, go
// to the one kept.
fn _outline_loop(list, what) {
    let ring = [];
    for p in list {
        let w = _outline_vertex(p, what);
        if !ring.is_empty() && _dist(w.p, ring[ring.len() - 1].p) < 1e-9 {
            let last = ring.len() - 1;
            ring[last].arc = w.arc;
            if type_of(ring[last].k) == "()" {
                ring[last].k = w.k;
            }
        } else {
            ring.push(w);
        }
    }
    while ring.len() > 1 && _dist(ring[0].p, ring[ring.len() - 1].p) < 1e-9 {
        let w = ring.pop();
        ring[ring.len() - 1].arc = w.arc;
    }
    ring
}

// A vertex from a point: `[x, y]`, `[x, y, r]` or `[x, y, #{arc, round}]`.
fn _outline_vertex(p, what) {
    if type_of(p) == "array" && p.len() == 3 {
        let at = _vec2([p[0], p[1]], `${what}: a point`);
        if type_of(p[2]) != "map" {
            return #{p: at, k: _num(p[2], `${what}: a corner's radius`), arc: ()};
        }
        _opts(p[2], ["arc", "round"], `${what}: a point`);
        let arc = if "arc" in p[2] { _num(p[2].arc, `${what}: an arc's radius`) } else { () };
        if _is_number(arc) && arc == 0.0 {
            throw `${what}: an arc's radius must not be 0, at ${at}`;
        }
        let k = if "round" in p[2] { _num(p[2].round, `${what}: a corner's radius`) } else { () };
        #{p: at, k: k, arc: arc}
    } else {
        #{p: _vec2(p, `${what}: a point`), k: (), arc: ()}
    }
}

// A loop the other way round: each arc moves to the vertex it now starts
// from, and turns the other way.
fn _reverse_loop(ring) {
    let n = ring.len();
    let out = [];
    for j in 0..n {
        let w = ring[n - 1 - j];
        let before = ring[(2 * n - 2 - j) % n];
        out.push(#{p: w.p, k: w.k, arc: if type_of(before.arc) == "()" { () } else { -before.arc }});
    }
    out
}

fn _loop_edges(ring, what) {
    let n = ring.len();
    let out = [];
    for i in 0..n {
        out.push(_edge(ring[i].p, ring[(i + 1) % n].p, ring[i].arc, what));
    }
    out
}

// The edge from `a` to `b`: straight for an `arc` of `()`, otherwise the
// shorter arc of radius `abs(arc)`, anticlockwise when `arc` is positive.
fn _edge(a, b, arc, what) {
    if type_of(arc) == "()" {
        return #{a: a, b: b, arc: ()};
    }
    let r = abs(arc);
    let dx = b[0] - a[0];
    let dy = b[1] - a[1];
    let l = sqrt(dx * dx + dy * dy);
    if l > 2.0 * r * (1.0 + 1e-9) {
        throw `${what}: an arc of radius ${r} cannot reach from ${a} to ${b}, ${l} apart`;
    }
    let half = min(l / (2.0 * r), 1.0);
    let h = r * sqrt(max(1.0 - half * half, 0.0));
    // The centre lies on the side the arc turns to, left of the chord for
    // an anticlockwise arc.
    let side = if arc > 0.0 { 1.0 } else { -1.0 };
    let c = [(a[0] + b[0]) * 0.5 - side * h * dy / l, (a[1] + b[1]) * 0.5 + side * h * dx / l];
    #{a: a, b: b, arc: #{c: c, r: r, ccw: arc > 0.0, from: _angle_of(a, c), sweep: 2.0 * asin(half)}}
}

// The part of the edge `e` from `p` to `q`, both on it, in order.
fn _edge_part(e, p, q) {
    if type_of(e.arc) == "()" {
        return #{a: p, b: q, arc: ()};
    }
    let arc = e.arc;
    let sweep = (_arc_fraction(arc, q) - _arc_fraction(arc, p)) * arc.sweep;
    #{a: p, b: q, arc: #{c: arc.c, r: arc.r, ccw: arc.ccw, from: _angle_of(p, arc.c), sweep: sweep}}
}

fn _edge_reverse(e) {
    if type_of(e.arc) == "()" {
        return #{a: e.b, b: e.a, arc: ()};
    }
    let arc = e.arc;
    #{a: e.b, b: e.a, arc: #{c: arc.c, r: arc.r, ccw: !arc.ccw, from: _angle_of(e.b, arc.c), sweep: arc.sweep}}
}

// The point a fraction `f` along the edge `e`.
fn _edge_point(e, f) {
    if type_of(e.arc) == "()" {
        return [e.a[0] + (e.b[0] - e.a[0]) * f, e.a[1] + (e.b[1] - e.a[1]) * f];
    }
    let a = _arc_angle(e.arc, f);
    [e.arc.c[0] + e.arc.r * cos(a), e.arc.c[1] + e.arc.r * sin(a)]
}

// The unit direction of travel a fraction `f` along the edge `e`.
fn _edge_tangent(e, f) {
    if type_of(e.arc) == "()" {
        let d = [e.b[0] - e.a[0], e.b[1] - e.a[1]];
        let l = sqrt(d[0] * d[0] + d[1] * d[1]);
        return [d[0] / l, d[1] / l];
    }
    let a = _arc_angle(e.arc, f);
    if e.arc.ccw { [-sin(a), cos(a)] } else { [sin(a), -cos(a)] }
}

// How far along the edge `e` the point nearest `p` on its line or circle
// lies, as a fraction, not clamped.
fn _edge_param(e, p) {
    if type_of(e.arc) == "()" {
        let d = [e.b[0] - e.a[0], e.b[1] - e.a[1]];
        return ((p[0] - e.a[0]) * d[0] + (p[1] - e.a[1]) * d[1]) / (d[0] * d[0] + d[1] * d[1]);
    }
    _arc_fraction(e.arc, p)
}

// The distance from `p` to the edge `e`.
fn _edge_distance(e, p) {
    let f = _edge_param(e, p);
    if f < 0.0 || f > 1.0 {
        return min(_dist(p, e.a), _dist(p, e.b));
    }
    if type_of(e.arc) == "()" {
        _dist(p, _edge_point(e, f))
    } else {
        abs(_dist(p, e.arc.c) - e.arc.r)
    }
}

// The angle round the arc's centre a fraction `f` along it.
fn _arc_angle(arc, f) {
    if arc.ccw { arc.from + f * arc.sweep } else { arc.from - f * arc.sweep }
}

// How far along the arc the point of its circle in the direction of `p`
// lies, as a fraction: within half a turn of the arc's middle either way,
// so points before its start come out negative.
fn _arc_fraction(arc, p) {
    let a = _angle_of(p, arc.c);
    let s = if arc.ccw { a - arc.from } else { arc.from - a };
    let d = s - arc.sweep * 0.5;
    let d = d - 2.0 * PI * floor((d + PI) / (2.0 * PI));
    (arc.sweep * 0.5 + d) / arc.sweep
}

// The angle of `p` round `c`, from +X.
fn _angle_of(p, c) {
    atan(p[1] - c[1], p[0] - c[0])
}

fn _dist(p, q) {
    let dx = p[0] - q[0];
    let dy = p[1] - q[1];
    sqrt(dx * dx + dy * dy)
}

// The signed area of a loop's edges, positive anticlockwise: the polygon
// of its points, and the segment each arc adds or takes away.
fn _loop_area(edges) {
    let area = 0.0;
    for e in edges {
        area += (e.a[0] * e.b[1] - e.b[0] * e.a[1]) * 0.5;
        if type_of(e.arc) != "()" {
            let segment = e.arc.r * e.arc.r * 0.5 * (e.arc.sweep - sin(e.arc.sweep));
            area += if e.arc.ccw { segment } else { -segment };
        }
    }
    area
}

// Whether `p` lies inside the edges' outline: the parity of the edges a
// ray from it crosses.  The ray leaves at an angle of one radian, which no
// outline is likely to share, so it passes no corner and grazes no arc.
fn _inside(p, edges) {
    let u = [cos(1.0), sin(1.0)];
    let n = 0;
    for e in edges {
        if type_of(e.arc) == "()" {
            let d = [e.b[0] - e.a[0], e.b[1] - e.a[1]];
            let den = u[0] * d[1] - u[1] * d[0];
            if den != 0.0 {
                let w = [e.a[0] - p[0], e.a[1] - p[1]];
                let s = (w[0] * d[1] - w[1] * d[0]) / den;
                let t = (w[0] * u[1] - w[1] * u[0]) / den;
                if s > 0.0 && t >= 0.0 && t < 1.0 {
                    n += 1;
                }
            }
        } else {
            let w = [p[0] - e.arc.c[0], p[1] - e.arc.c[1]];
            let b = u[0] * w[0] + u[1] * w[1];
            let disc = b * b - (w[0] * w[0] + w[1] * w[1] - e.arc.r * e.arc.r);
            if disc > 0.0 {
                for s in [-b - sqrt(disc), -b + sqrt(disc)] {
                    let f = _arc_fraction(e.arc, [p[0] + s * u[0], p[1] + s * u[1]]);
                    if s > 0.0 && f >= 0.0 && f < 1.0 {
                        n += 1;
                    }
                }
            }
        }
    }
    n % 2 == 1
}

// --- Point lists ---
//
// Plain arithmetic on numbers: points for `polygon` and `rounded_polygon`,
// and the geometry a script works out before it builds any shape.

/// regular_polygon_points(n: number, r: number): Vec2[]
///
/// The corners of `regular_polygon(n, r)`, anticlockwise from the one on +X.
///
/// - `n`: the number of sides, 3 or more
/// - `r`: the circumradius, from the centre to a corner
///
/// See also: `regular_polygon`, `star_points`, `rounded_polygon`.
///
/// Example: the corners of a square standing on one corner, 10 from the centre.
/// ```
/// regular_polygon_points(4, 10)
/// ```
/// Example: a flange with six bolt holes, one at each corner of a hexagon.
/// ```
/// let holes = regular_polygon_points(6, 22)
///     .map(|p| circle(2).move(p));
/// circle(30).difference(union(holes))
/// ```
fn regular_polygon_points(n, r) {
    if type_of(n) != "i64" || n < 3 {
        throw `regular_polygon_points: n must be an integer of at least 3, got ${n}`;
    }
    let r = _num(r, "regular_polygon_points: r");
    let out = [];
    for i in 0..n {
        let a = 360.0 * i / n;
        out.push([r * cosd(a), r * sind(a)]);
    }
    out
}

/// star_points(n: number, r: [number, number]): Vec2[]
///
/// The corners of `star(n, r)`, anticlockwise from the point on +X, points and inner corners in turn.
///
/// - `n`: the number of points, 2 or more
/// - `r`: `[outer, inner]`, the radius of the points and that of the inner corners
///
/// See also: `star`, `regular_polygon_points`, `polygon_clip`.
///
/// Example: the corners of a star of 2 points, a rhombus.
/// ```
/// star_points(2, [10, 5])
/// ```
fn star_points(n, r) {
    if type_of(n) != "i64" || n < 2 {
        throw `star_points: n must be an integer of at least 2, got ${n}`;
    }
    let r = _pair(r, "star_points: r");
    let ro = _num(r[0], "star_points: r");
    let ri = _num(r[1], "star_points: r");
    let out = [];
    for i in 0..n {
        let a = 360.0 * i / n;
        let b = a + 180.0 / n;
        out.push([ro * cosd(a), ro * sind(a)]);
        out.push([ri * cosd(b), ri * sind(b)]);
    }
    out
}

/// bezier_points(points: Vec2[] | Vec3[], n: number): Vec2[] | Vec3[]
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
/// From OpenSCAD: `bezier3(points, n)` is `bezier_points(points, n)`.
///
/// Example: the points of a curve from three control points, in two steps.
/// ```
/// bezier_points([[0, 0], [10, 20], [20, 0]], 2)
/// ```
/// Example: a fin with a curved back, its outline a curve closed by a straight base.
/// ```
/// let curve = [[0, 0], [5, 30], [30, 25], [40, 0]];
/// polygon(bezier_points(curve, 24))
/// ```
fn bezier_points(points, n) {
    if type_of(n) != "i64" || n < 1 {
        throw `bezier_points: n must be an integer of at least 1, got ${n}`;
    }
    let out = [];
    for i in 0..=n {
        out.push(bezier_point(points, i.to_float() / n));
    }
    out
}

/// pts_move(points: Vec2[] | Vec3[], v: Vec2 | Vec3): Vec2[] | Vec3[]
///
/// Points ("pts") moved by a vector.
///
/// - `points`: the points, 2D or 3D
/// - `v`: the move; a 2D `v` moves 3D points along X and Y only
///
/// See also: `move`, `pts_rotate`, `pts_scale`.
///
/// Example: two points moved 10 along X.
/// ```
/// pts_move([[0, 0], [1, 2]], [10, 0])
/// ```
fn pts_move(points, v) {
    let v = _array(v, "pts_move: v");
    _pts(points, "pts_move").map(|p| {
        let q = p;
        for i in 0..min(p.len(), v.len()) {
            q[i] += v[i];
        }
        q
    })
}

/// pts_rotate(points: Vec2[] | Vec3[], angle: number): Vec2[] | Vec3[]
///
/// Points ("pts") turned about the Z axis, as `rotate_z` turns shapes.
///
/// - `points`: the points, 2D or 3D
/// - `angle`: the turn, in degrees, anticlockwise looking down
///
/// See also: `rotate_z`, `pts_move`, `pts_scale`.
///
/// Example: a point on +X turned a quarter turn.
/// ```
/// pts_rotate([[10, 0]], 90)
/// ```
fn pts_rotate(points, angle) {
    let a = _num(angle, "pts_rotate: angle");
    let c = cosd(a);
    let s = sind(a);
    _pts(points, "pts_rotate").map(|p| {
        let q = p;
        q[0] = p[0] * c - p[1] * s;
        q[1] = p[0] * s + p[1] * c;
        q
    })
}

/// pts_scale(points: Vec2[] | Vec3[], s: number | Vec2 | Vec3): Vec2[] | Vec3[]
///
/// Points ("pts") scaled about the origin.
///
/// - `points`: the points, 2D or 3D
/// - `s`: one factor for every axis, or one for each
///
/// A polygon through scaled points keeps an exact field.
/// `scale` on the polygon itself leaves only a bound when it scales the axes differently.
///
/// See also: `scale`, `pts_move`, `pts_mirror_x`.
///
/// From OpenSCAD: `scale([2, 1]) polygon(points)` is `polygon(pts_scale(points, [2, 1]))`.
///
/// Example: two points stretched to twice their distance along X.
/// ```
/// pts_scale([[1, 1], [2, -1]], [2, 1])
/// ```
fn pts_scale(points, s) {
    let s = if _is_number(s) { [s.to_float(), s.to_float(), s.to_float()] } else { _array(s, "pts_scale: s") };
    _pts(points, "pts_scale").map(|p| {
        let q = p;
        for i in 0..min(p.len(), s.len()) {
            q[i] *= s[i];
        }
        q
    })
}

/// pts_mirror_x(points: Vec2[] | Vec3[]): Vec2[] | Vec3[]
///
/// Points ("pts") mirrored across the Y axis, each X negated.
///
/// - `points`: the points, 2D or 3D
///
/// The order is kept, so an outline through the points goes round the other way.
///
/// See also: `reflect`, `pts_mirror_y`.
///
/// Example: a symmetric outline, its right half given and its left half mirrored.
/// ```
/// let half = [[0, 0], [15, 0], [10, 20], [0, 25]];
/// let other = pts_mirror_x(half);
/// other.reverse();
/// polygon(half + other)
/// ```
fn pts_mirror_x(points) {
    pts_scale(points, [-1.0, 1.0, 1.0])
}

/// pts_mirror_y(points: Vec2[] | Vec3[]): Vec2[] | Vec3[]
///
/// Points ("pts") mirrored across the X axis, each Y negated.
///
/// - `points`: the points, 2D or 3D
///
/// The order is kept, so an outline through the points goes round the other way.
///
/// See also: `reflect`, `pts_mirror_x`.
///
/// Example: two points mirrored below the X axis.
/// ```
/// pts_mirror_y([[1, 2], [3, 4]])
/// ```
fn pts_mirror_y(points) {
    pts_scale(points, [1.0, -1.0, 1.0])
}

// A list of points as arrays of floats.
fn _pts(points, what) {
    if type_of(points) != "array" {
        throw `${what}: points must be an array of points, got ${type_of(points)}`;
    }
    points.map(|p| _array(p, `${what}: a point`))
}

/// polygon_clip(a: Outline, b: Outline, op: "intersection" | "union" | "difference"): Point[][]
/// type Outline = Point[] | Point[][]
/// type Point = Vec2 | [number, number, #{ arc: number }]
///
/// The intersection, union or difference of two outlines, as new points.
///
/// - `a`, `b`: the outlines, each a list of points as `polygon` takes them, either way round, or a list of such lists for an outline of several parts or with holes
/// - `op`: `"intersection"`, `"union"`, or `"difference"`, `a` without `b`
///
/// The result is a list of loops, anticlockwise round each part and clockwise round each hole.
/// `polygon`, `rounded_polygon` and `polygon_clip` itself take it as it is.
/// An edge that is an arc stays one, `[x, y, #{arc: r}]` as in `rounded_polygon`.
/// Outlines that share an edge leave no seam there: two squares side by side make one rectangle.
/// When nothing is left, the result is an empty list.
///
/// Shapes combined with `union` or `difference` have a field that is only a bound in places.
/// A polygon through the result's points has an exact field instead, so its offsets come out right.
/// `rounded_polygon` can also round the corners where the outlines met.
///
/// Each edge is cut where the other outline meets it.
/// A piece is kept by whether its middle lies inside the other outline, outside it, or along one of its edges.
/// The kept pieces are then joined into loops.
///
/// Notes:
/// - It works on numbers when the script runs, so it makes no field.
/// - The points are exact to about a millionth of the outlines' size.
/// - The outlines must not cross themselves.
/// - Parts that meet at a single point come out as loops of their own.
/// - About `n * m` steps for outlines of `n` and `m` edges.
///
/// See also: `polygon`, `rounded_polygon`, `revolve`.
///
/// References:
/// - [Boolean operations on polygons, Wikipedia](https://en.wikipedia.org/wiki/Boolean_operations_on_polygons)
/// - [Greiner-Hormann clipping algorithm, Wikipedia](https://en.wikipedia.org/wiki/Greiner%E2%80%93Hormann_clipping_algorithm), a related method
///
/// From OpenSCAD: `difference() { polygon(a); polygon(b); }` is `polygon(polygon_clip(a, b, "difference"))`, and the same for `union` and `intersection`.
///
/// Example: a plate with a round notch, its corners then rounded.
/// ```
/// let plate = [[-20, -10], [20, -10], [20, 10], [-20, 10]];
/// let notch = [[8, 10, #{arc: 8}], [-8, 10, #{arc: 8}]];
/// rounded_polygon(polygon_clip(plate, notch, "difference"), 2)
/// ```
fn polygon_clip(a, b, op) {
    if !["intersection", "union", "difference"].contains(op) {
        throw `polygon_clip: op must be "intersection", "union" or "difference", got ${op}`;
    }
    let ea = _clip_edges(a, "polygon_clip: a");
    let eb = _clip_edges(b, "polygon_clip: b");
    let eps = 1e-6 * _outline_size(ea + eb);
    // Each edge cut where the other outline meets it, so that each piece
    // lies inside the other outline, outside it, or along one of its edges.
    let cuts_a = ea.map(|e| []);
    let cuts_b = eb.map(|e| []);
    for i in 0..ea.len() {
        for j in 0..eb.len() {
            for p in _meetings(ea[i], eb[j], eps) {
                cuts_a[i].push(p);
                cuts_b[j].push(p);
            }
        }
    }
    // The pieces the result keeps.  Along a shared edge both outlines'
    // insides lie on one side ("same") or on either side ("opposite"); `a`'s
    // piece stands for both.
    let kept = [];
    for i in 0..ea.len() {
        for e in _split(ea[i], cuts_a[i], eps) {
            let k = _classify(e, eb, eps);
            let keep = switch op {
                "intersection" => k == "in" || k == "same",
                "union" => k == "out" || k == "same",
                _ => k == "out" || k == "opposite",
            };
            if keep {
                kept.push(e);
            }
        }
    }
    for j in 0..eb.len() {
        for e in _split(eb[j], cuts_b[j], eps) {
            let k = _classify(e, ea, eps);
            if (k == "in" && op == "intersection") || (k == "out" && op == "union") {
                kept.push(e);
            } else if k == "in" && op == "difference" {
                kept.push(_edge_reverse(e));
            }
        }
    }
    let loops = [];
    for chain in _chain(kept, eps) {
        let chain = _merge_pieces(chain, eps);
        if chain.len() >= 2 && abs(_loop_area(chain)) > eps * eps {
            loops.push(chain.map(|e| _vertex_point(e)));
        }
    }
    loops
}

// An outline for `polygon_clip`: its loops' edges, all in one list.
fn _clip_edges(v, what) {
    let edges = [];
    for ring in _outline(v, what) {
        if ring.some(|w| type_of(w.k) != "()") {
            throw `${what}: a corner's radius is for rounded_polygon; clip first, then round the result`;
        }
        edges += _loop_edges(ring, what);
    }
    edges
}

// The size of an outline: the larger side of the box round its edges'
// ends, at least 1.
fn _outline_size(edges) {
    let lo = edges[0].a;
    let hi = edges[0].a;
    for e in edges {
        for p in [e.a, e.b] {
            lo = [min(lo[0], p[0]), min(lo[1], p[1])];
            hi = [max(hi[0], p[0]), max(hi[1], p[1])];
        }
    }
    max(max(hi[0] - lo[0], hi[1] - lo[1]), 1.0)
}

// The points where the edges `e` and `f` meet: where they cross or touch,
// and the ends of either that lie on the other.  An end is taken as it
// is, so that pieces cut there join it exactly.
fn _meetings(e, f, eps) {
    let found = [];
    for p in [e.a, e.b] {
        if _edge_distance(f, p) < eps {
            found.push(p);
        }
    }
    for p in [f.a, f.b] {
        if _edge_distance(e, p) < eps && found.all(|q| _dist(p, q) >= eps) {
            found.push(p);
        }
    }
    for p in _curve_meetings(e, f) {
        if _edge_distance(e, p) < eps && _edge_distance(f, p) < eps && found.all(|q| _dist(p, q) >= eps) {
            found.push(p);
        }
    }
    found
}

// The points where the lines or circles of the edges `e` and `f` meet;
// none for parallel lines or circles of one centre, whose overlaps the
// edges' ends mark.
fn _curve_meetings(e, f) {
    let line_e = type_of(e.arc) == "()";
    let line_f = type_of(f.arc) == "()";
    if line_e && line_f {
        let d1 = [e.b[0] - e.a[0], e.b[1] - e.a[1]];
        let d2 = [f.b[0] - f.a[0], f.b[1] - f.a[1]];
        let den = d1[0] * d2[1] - d1[1] * d2[0];
        if abs(den) <= 1e-12 * (abs(d1[0]) + abs(d1[1])) * (abs(d2[0]) + abs(d2[1])) {
            return [];
        }
        let t = ((f.a[0] - e.a[0]) * d2[1] - (f.a[1] - e.a[1]) * d2[0]) / den;
        return [[e.a[0] + t * d1[0], e.a[1] + t * d1[1]]];
    }
    if line_e {
        return _line_circle(e.a, e.b, f.arc.c, f.arc.r);
    }
    if line_f {
        return _line_circle(f.a, f.b, e.arc.c, e.arc.r);
    }
    _circle_circle(e.arc.c, e.arc.r, f.arc.c, f.arc.r)
}

// Where the line through `a` and `b` meets the circle round `c` of radius
// `r`: one point where it touches.
fn _line_circle(a, b, c, r) {
    let d = [b[0] - a[0], b[1] - a[1]];
    let l = sqrt(d[0] * d[0] + d[1] * d[1]);
    let u = [d[0] / l, d[1] / l];
    let s = (c[0] - a[0]) * u[0] + (c[1] - a[1]) * u[1];
    let foot = [a[0] + s * u[0], a[1] + s * u[1]];
    let fc = _dist(foot, c);
    let hh = r * r - fc * fc;
    if hh < -1e-9 * r * r {
        return [];
    }
    let h = sqrt(max(hh, 0.0));
    if h == 0.0 {
        return [foot];
    }
    [[foot[0] - h * u[0], foot[1] - h * u[1]], [foot[0] + h * u[0], foot[1] + h * u[1]]]
}

// Where the circles round `c1` and `c2`, of radii `r1` and `r2`, meet.
fn _circle_circle(c1, r1, c2, r2) {
    let dd = _dist(c1, c2);
    if dd < 1e-12 * (r1 + r2) || dd > (r1 + r2) * (1.0 + 1e-9) || dd < abs(r1 - r2) * (1.0 - 1e-9) {
        return [];
    }
    let u = [(c2[0] - c1[0]) / dd, (c2[1] - c1[1]) / dd];
    let a = (r1 * r1 - r2 * r2 + dd * dd) / (2.0 * dd);
    let h = sqrt(max(r1 * r1 - a * a, 0.0));
    let m = [c1[0] + a * u[0], c1[1] + a * u[1]];
    if h == 0.0 {
        return [m];
    }
    [[m[0] - h * u[1], m[1] + h * u[0]], [m[0] + h * u[1], m[1] - h * u[0]]]
}

// The edge `e` cut at the points `cuts`, in order along it; points at its
// ends, or at the last cut, cut nothing.
fn _split(e, cuts, eps) {
    let at = [];
    for p in cuts {
        if _dist(p, e.a) >= eps && _dist(p, e.b) >= eps {
            at.push(#{f: _edge_param(e, p), p: p});
        }
    }
    at.sort(|u, v| if u.f < v.f { -1 } else if u.f > v.f { 1 } else { 0 });
    let parts = [];
    let from = e.a;
    for c in at {
        if _dist(c.p, from) >= eps {
            parts.push(_edge_part(e, from, c.p));
            from = c.p;
        }
    }
    parts.push(_edge_part(e, from, e.b));
    parts
}

// Where a piece lies against the outline of `edges`, by its middle: "in"
// or "out", or along one of its edges the "same" way or the "opposite".
fn _classify(e, edges, eps) {
    let m = _edge_point(e, 0.5);
    for g in edges {
        if _edge_distance(g, m) < eps {
            let t = _edge_tangent(e, 0.5);
            let u = _edge_tangent(g, _edge_param(g, m));
            return if t[0] * u[0] + t[1] * u[1] > 0.0 { "same" } else { "opposite" };
        }
    }
    if _inside(m, edges) { "in" } else { "out" }
}

// The pieces joined end to end into loops.  Where several could follow,
// the one that turns furthest left does: with the inside on the left,
// that keeps each loop round its own part, and parts that only touch
// apart.
fn _chain(edges, eps) {
    let used = edges.map(|e| false);
    let loops = [];
    for i in 0..edges.len() {
        if used[i] {
            continue;
        }
        used[i] = true;
        let chain = [edges[i]];
        loop {
            let last = chain[chain.len() - 1];
            let heading = _edge_tangent(last, 1.0);
            // -1 closes the loop; -2 is nothing found.
            let next = -2;
            let best = -10.0;
            if _dist(last.b, chain[0].a) < eps {
                next = -1;
                best = _turn(heading, _edge_tangent(chain[0], 0.0));
            }
            for j in 0..edges.len() {
                if !used[j] && _dist(edges[j].a, last.b) < eps {
                    let turn = _turn(heading, _edge_tangent(edges[j], 0.0));
                    if turn > best {
                        next = j;
                        best = turn;
                    }
                }
            }
            if next == -1 {
                break;
            }
            if next == -2 {
                throw "polygon_clip: an outline does not close; do the outlines cross themselves?";
            }
            used[next] = true;
            chain.push(edges[next]);
        }
        loops.push(chain);
    }
    loops
}

// The angle from the direction `d1` to `d2`, anticlockwise positive, from
// -PI to PI.
fn _turn(d1, d2) {
    atan(d1[0] * d2[1] - d1[1] * d2[0], d1[0] * d2[0] + d1[1] * d2[1])
}

// A loop's pieces with those that go straight on joined: lines along one
// line, and arcs round one circle the same way, up to half a turn.
fn _merge_pieces(chain, eps) {
    let out = [];
    for e in chain {
        if !out.is_empty() {
            let joined = _join_pieces(out[out.len() - 1], e, eps);
            if type_of(joined) != "()" {
                out[out.len() - 1] = joined;
                continue;
            }
        }
        out.push(e);
    }
    while out.len() > 2 {
        let joined = _join_pieces(out[out.len() - 1], out[0], eps);
        if type_of(joined) == "()" {
            break;
        }
        out[0] = joined;
        out.pop();
    }
    out
}

fn _join_pieces(e, f, eps) {
    if type_of(e.arc) == "()" && type_of(f.arc) == "()" {
        let d = _edge_tangent(e, 1.0);
        let off = (f.b[0] - e.a[0]) * d[1] - (f.b[1] - e.a[1]) * d[0];
        let t = _edge_tangent(f, 0.0);
        if abs(off) < eps && d[0] * t[0] + d[1] * t[1] > 0.0 {
            return #{a: e.a, b: f.b, arc: ()};
        }
    } else if type_of(e.arc) != "()" && type_of(f.arc) != "()" {
        let same = _dist(e.arc.c, f.arc.c) < eps && abs(e.arc.r - f.arc.r) < eps && e.arc.ccw == f.arc.ccw;
        if same && e.arc.sweep + f.arc.sweep <= PI {
            let arc = e.arc;
            arc.sweep = e.arc.sweep + f.arc.sweep;
            return #{a: e.a, b: f.b, arc: arc};
        }
    }
    ()
}

// The point an edge starts from, as `polygon_clip` gives it.
fn _vertex_point(e) {
    if type_of(e.arc) == "()" {
        [e.a[0], e.a[1]]
    } else {
        [e.a[0], e.a[1], #{arc: if e.arc.ccw { e.arc.r } else { -e.arc.r }}]
    }
}

// --- Strokes ---

/// stroke(points: Vec2[], width: Tree | ((t: Tree) => Tree), opts: #{ caps?: "round" | "butt", closed?: bool } = #{}): Shape
///
/// Line through a list of points, drawn with a pen of the given width.
///
/// - `points`: the line's points, each `[x, y]`, at least two
/// - `width`: the stroke's full width, which may vary over space; or a function of `t`, how far along the line, from 0 at its start to 1 at its end
/// - `opts`:
///   - `caps`: `"round"` ends, the default, or `"butt"`, cut square at the first and the last point
///   - `closed`: `true` joins the last point back to the first, for a line with no ends
///
/// The stroke holds every point within half of `width` of the line.
/// Where the line turns, its corner is round on the outside, whatever the caps.
/// Two points make a stadium, the shape of a slot.
/// A function of `t` makes a stroke that tapers; `t` grows with the length drawn.
///
/// Notes:
/// - Field: exact outside; inside, where the segments overlap, a bound.
///   With a width that changes, a bound while it changes slowly.
/// - About 25 operations a segment.
///
/// See also: `arc_stroke`, `bezier_stroke`, `offset`.
///
/// References:
/// - [Stadium (geometry), Wikipedia](https://en.wikipedia.org/wiki/Stadium_%28geometry%29)
///
/// From OpenSCAD: `stroke_line` draws its ends as `#{caps: "butt"}` does.
///
/// Example: a slot 10 long in a plate, for a 3 mm screw to slide in.
/// ```
/// let plate = rect([30, 15], #{round: 2});
/// let slot = stroke([[-5, 0], [5, 0]], 3.4);
/// plate.difference(slot)
/// ```
/// Example: a hook's arm that tapers from 4 wide to 1.
/// ```
/// let path = [[0, 0], [20, 0], [25, 10]];
/// stroke(path, |t| lerp(4.0, 1.0, t))
/// ```
fn stroke(points, width) {
    stroke(points, width, #{})
}

fn stroke(points, width, opts) {
    _opts(opts, ["caps", "closed"], "stroke");
    let p = [];
    for q in points {
        p.push(_vec2(q, "stroke: a point"));
    }
    if p.len() < 2 {
        throw `stroke: needs at least 2 points, got ${p.len()}`;
    }
    let caps = _opt(opts, "caps", "round");
    if caps != "round" && caps != "butt" {
        throw `stroke: caps must be "round" or "butt", got ${caps}`;
    }
    if _opt(opts, "closed", false) {
        if "caps" in opts {
            throw "stroke: a closed stroke has no ends to cap";
        }
        p.push(p[0]);
    }
    let half = if type_of(width) == "Fn" {
        |t| _float(width.call(t)) * 0.5
    } else {
        let w = _field(width, "stroke: width") * 0.5;
        |t| w
    };
    let lengths = [];
    let total = 0.0;
    for i in 1..p.len() {
        let l = norm([p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]]);
        lengths.push(l);
        total += l;
    }
    if total == 0.0 {
        throw "stroke: its points are all one point";
    }
    let butt = caps == "butt";
    let last = lengths.len() - 1;
    let parts = [];
    let done = 0.0;
    for i in 0..=last {
        if lengths[i] > 0.0 {
            let ends = [butt && i == 0, butt && i == last];
            parts.push(_stroke_segment(p[i], p[i + 1], [done / total, lengths[i] / total], half, ends));
        }
        done += lengths[i];
    }
    if parts.len() == 1 { parts[0] } else { union(parts) }
}

// One segment of a stroke from `a` to `b`, `t` its share of the stroke's
// length as `[start, part]`, `butt` whether each end is cut square.  The
// round part is the distance to the segment, less the half width there,
// leaving out the overshoot past a cut end; past that end, the distance
// is to the cut edge, a corner between the overshoot and the round part.
fn _stroke_segment(a, b, t, half, butt) {
    let ex = b[0] - a[0];
    let ey = b[1] - a[1];
    let el = sqrt(ex * ex + ey * ey);
    let wx = x - a[0];
    let wy = y - a[1];
    let along = (wx * ex + wy * ey) / el;
    let across = (wx * ey - wy * ex) / el;
    let r = half.call(t[0] + t[1] * clamp(along / el, 0.0, 1.0));
    let before = if butt[0] { 0.0 } else { min(along, 0.0) };
    let after = if butt[1] { 0.0 } else { max(along - el, 0.0) };
    let round = _hypot(before + after, across) - r;
    if butt[0] && butt[1] {
        _corner(max(-along, along - el), round)
    } else if butt[0] {
        _corner(-along, round)
    } else if butt[1] {
        _corner(along - el, round)
    } else {
        round
    }
}

/// arc_stroke(r: Tree, angles: [Tree, Tree], width: Tree, opts: #{ caps?: "round" | "butt" } = #{}): Shape
///
/// Arc of a circle centred on the origin, drawn with a pen of the given width.
///
/// - `r`: the arc's radius, to the middle of the stroke; it may vary over space
/// - `angles`: `[from, to]`, in degrees anticlockwise from +X; `to` is above `from` by at most 360
/// - `width`: the stroke's full width; it may vary over space
/// - `opts`:
///   - `caps`: `"round"` ends, the default, or `"butt"`, cut along the radii at the two angles
///
/// With butt caps it is the ring from `r - width / 2` to `r + width / 2`, cut to the angles.
///
/// Notes:
/// - Field: exact.
/// - About 30 operations.
///
/// See also: `stroke`, `sector`, `annulus`.
///
/// References:
/// - Inigo Quilez, [2D distance functions](https://iquilezles.org/articles/distfunctions2d/), "Arc"
///
/// Example: a curved slot in a round plate, for a part to turn on a screw through it.
/// ```
/// circle(25)
///     .difference(arc_stroke(17, [-60, 60], 3.4))
/// ```
/// Example: a horseshoe-shaped clip, its ends cut square.
/// ```
/// arc_stroke(15, [-45, 225], 6, #{caps: "butt"})
/// ```
fn arc_stroke(r, angles, width) {
    arc_stroke(r, angles, width, #{})
}

fn arc_stroke(r, angles, width, opts) {
    _opts(opts, ["caps"], "arc_stroke");
    let caps = _opt(opts, "caps", "round");
    if caps != "round" && caps != "butt" {
        throw `arc_stroke: caps must be "round" or "butt", got ${caps}`;
    }
    let r = _field(r, "arc_stroke: r");
    let half = _field(width, "arc_stroke: width") * 0.5;
    let a = _span(angles, "arc_stroke");
    let p = _span_frame(a[0]);
    let s = sind(a[1]);
    let c = cosd(a[1]);
    // Positive past the radius at the end's angle, beyond the arc's end.
    let line = c * p[0] - s * p[1];
    let ring = abs(_hypot(p[0], p[1]) - r);
    let d = if caps == "butt" {
        let along = s * p[0] + c * p[1];
        _corner(line, _select_less(0.0, line, abs(along - r), ring) - half)
    } else {
        _select_less(0.0, line, _hypot(p[0] - r * s, p[1] - r * c), ring) - half
    };
    // No closer than the whole ring: changes no value, but lets interval
    // arithmetic see where the arc ends.
    max(d, ring - half)
}
