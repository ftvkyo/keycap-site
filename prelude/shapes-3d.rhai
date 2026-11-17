// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: 3D solids, centred on the origin, axes along Z.
//
// kind: 3d
//
// Every field here is an exact Euclidean distance unless its doc says
// otherwise.

// --- Boxes ---

/// cuboid(size: Vec3 | number, opts: #{ round?: Tree, chamfer?: Tree, anchor?: Anchor3, normalize?: bool } = #{}): Shape
/// type Anchor3 = Vec3 | "center" | "left" | "right" | "front" | "back" | "bottom" | "top"
///
/// Box centred on the origin, its edges sharp, rounded or chamfered.
///
/// - `size`: `[x, y, z]`, or one number for a cube
/// - `opts`:
///   - `round`: the radius of every edge and corner, clamped to half the shortest side; it may vary over space
///   - `chamfer`: how far a 45-degree chamfer at every edge cuts into each face, clamped likewise; it may vary over space
///   - `anchor`: the point put on the origin, from `[-1, -1, -1]`, the -X -Y -Z corner, to `[1, 1, 1]`; or a name, such as `"bottom"`, the middle of the -Z face
///   - `normalize`: `false` to skip the correction that keeps the field a distance when `round` or `chamfer` varies; see the notes
///
/// A box has `round` or `chamfer`, not both.
/// A chamfer cuts the corners too, with a triangle where its three edges meet.
/// A rounded box is a smaller box grown by `round` in every direction, so its offsets stay round.
/// For rounded vertical edges only, extrude a rounded `rect`.
///
/// Notes:
/// - Field: exact, rounded too; chamfered, exact inside and a bound outside near the cut edges and corners.
/// - fidget's `box` is only a bound beyond its edges, so its offsets keep sharp edges.
/// - A `round` or `chamfer` that varies keeps the field a distance to first order, at the cost of a second evaluation.
/// - `normalize: false` skips that correction: twice as fast, but offsets and shells come out uneven.
///
/// See also: `box`, `rect`, `octahedron`.
///
/// From OpenSCAD: `minkowski() { cube(s - 2 * r, center = true); sphere(r); }` is `cuboid(s, #{round: r})`.
///
/// Example: a slab standing on z = 0, its edges rounded.
/// ```
/// cuboid([40, 20, 5], #{round: 1, anchor: "bottom"})
/// ```
fn cuboid(size) {
    cuboid(size, #{})
}

fn cuboid(size, opts) {
    _opts(opts, ["round", "chamfer", "anchor", "normalize"], "cuboid");
    let s = _vec3(size, "cuboid: size", 0.0);
    if s[0] <= 0.0 || s[1] <= 0.0 || s[2] <= 0.0 {
        throw `cuboid: size must be three positive numbers, or one, got ${size}`;
    }
    let limit = min(s[0], min(s[1], s[2])) * 0.5;
    let shape = if "round" in opts {
        if "chamfer" in opts {
            throw "cuboid: its edges are rounded or chamfered, not both";
        }
        let r = min(_field(opts.round, "cuboid: round"), limit);
        _vary(|r| _cuboid(s[0] - 2.0 * r, s[1] - 2.0 * r, s[2] - 2.0 * r) - r, r, opts)
    } else if "chamfer" in opts {
        let c = min(_field(opts.chamfer, "cuboid: chamfer"), limit);
        _vary(|c| _chamfered_cuboid(s[0] * 0.5, s[1] * 0.5, s[2] * 0.5, c), c, opts)
    } else {
        _cuboid(s[0], s[1], s[2])
    };
    let half = s.map(|v| v * 0.5);
    _anchor(shape, _opt(opts, "anchor", ()), half.map(|v| -v), half, "cuboid")
}

// A box of sides `sx`, `sy` and `sz` centred on the origin, exact.
fn _cuboid(sx, sy, sz) {
    let dx = abs(x) - sx * 0.5;
    let dy = abs(y) - sy * 0.5;
    let dz = abs(z) - sz * 0.5;
    let m = max(dx, max(dy, dz));
    _corner_of(m, square(max(dx, 0.0)) + square(max(dy, 0.0)) + square(max(dz, 0.0)))
}

// A box of half sizes `a`, `b` and `d` whose edges are cut at 45 degrees,
// `c` off each face, and whose corners are cut by the plane through the
// cuts' ends: every point within an L1 distance `c` of the box shrunk by
// `c`.  A convex polyhedron, so the largest of the signed distances to its
// faces' planes, exact inside.
fn _chamfered_cuboid(a, b, d, c) {
    let u = abs(x);
    let v = abs(y);
    let w = abs(z);
    let faces = max(u - a, max(v - b, w - d));
    let edges = max(u + v - (a + b - c), max(v + w - (b + d - c), u + w - (a + d - c))) / SQRT_2;
    let corner = (u + v + w - (a + b + d - 2.0 * c)) / sqrt(3.0);
    max(faces, max(edges, corner))
}

// --- Round solids ---

/// cylinder(r: Tree, h: Height, opts: #{ round?: Rim, chamfer?: Rim, sides?: number, anchor?: Anchor3, normalize?: bool } = #{}): Shape
/// type Height = number | [number, number]
/// type Rim = Sched | [Sched, Sched]
/// type Sched = Tree | ((t: Tree) => Tree) | Key[]
/// type Anchor3 = Vec3 | "center" | "left" | "right" | "front" | "back" | "bottom" | "top"
///
/// Cylinder along Z, centred on the origin, its rims sharp, rounded or chamfered.
///
/// - `r`: the radius; it may vary over space
/// - `h`: the height, centred on z = 0, or `[z0, z1]`, from `z0` up to `z1`; `[0, h]` stands the cylinder on z = 0
/// - `opts`:
///   - `round`: the radius of the rims, clamped to `r` and half of `h`; `[bottom, top]` for one each
///   - `chamfer`: how far a 45-degree chamfer at the rims cuts into the side and the ends, as for `round`
///   - `sides`: the number of sides of a prism to make instead, with a vertex on +X; `r` is then the distance from the axis to each vertex
///   - `anchor`: the point put on the origin, as for `cuboid`
///   - `normalize`: `false` to skip the correction that keeps the field a distance when a rim's size varies; see the notes
///
/// A rim's size is a number, a tree that varies over space, a function of `t`, or keyframes in `t`, with `t` from 0 at the bottom to 1 at the top, as for `extrude`.
/// One rim may be rounded and the other chamfered.
///
/// Notes:
/// - Field: exact, with rounded rims too; chamfered rims are a bound beyond the chamfer, and a prism's rounded rims a bound near its edges.
/// - A rim's size that varies keeps the field a distance to first order, at the cost of a second evaluation.
/// - `normalize: false` skips that correction: twice as fast, but offsets and shells come out uneven.
///
/// See also: `tube`, `cone`, `rod`, `extrude`.
///
/// From OpenSCAD: `cylinder(h, r, $fn = n)` is `cylinder(r, [0, h], #{sides: n})`.
///
/// Example: a peg standing on z = 0, its top rounded.
/// ```
/// cylinder(5, [0, 20], #{round: [0, 1]})
/// ```
fn cylinder(r, h) {
    cylinder(r, h, #{})
}

fn cylinder(r, h, opts) {
    _opts(opts, ["round", "chamfer", "sides", "anchor", "normalize"], "cylinder");
    let r = _field(r, "cylinder: r");
    let zs = _height(h, "cylinder: h");
    let profile = if "sides" in opts { regular_polygon(opts.sides, r) } else { _hypot(x, y) - r };
    let shape = _extrude(profile, zs, opts, min(r, (zs[1] - zs[0]) * 0.5), "cylinder");
    _anchor_round(shape, opts, r, zs, "cylinder")
}

/// tube(r: [Tree, Tree], h: Height, opts: #{ round?: Rim, chamfer?: Rim, anchor?: Anchor3, normalize?: bool } = #{}): Shape
/// type Height = number | [number, number]
/// type Rim = Sched | [Sched, Sched]
/// type Sched = Tree | ((t: Tree) => Tree) | Key[]
/// type Anchor3 = Vec3 | "center" | "left" | "right" | "front" | "back" | "bottom" | "top"
///
/// Tube along Z, centred on the origin, its rims sharp, rounded or chamfered.
///
/// - `r`: `[outer, inner]`, the radii, the inner one smaller; either may vary over space
/// - `h`: the height, centred on z = 0, or `[z0, z1]`, from `z0` up to `z1`
/// - `opts`:
///   - `round`, `chamfer`: the rims, as for `cylinder`, clamped to half the wall and half of `h`
///   - `anchor`: the point put on the origin, as for `cuboid`
///   - `normalize`: `false` to skip the correction that keeps the field a distance when a rim's size varies; see the notes
///
/// A rounded or chamfered end has both its outer and its inner edge cut alike.
///
/// Notes:
/// - Field: exact, with rounded rims too; chamfered rims are a bound beyond the chamfer.
/// - A rim's size that varies keeps the field a distance to first order, at the cost of a second evaluation.
/// - `normalize: false` skips that correction: twice as fast, but offsets and shells come out uneven.
///
/// See also: `cylinder`, `annulus`, `shell`.
///
/// Example: a spacer 8 tall for a 5 mm screw, its rims chamfered.
/// ```
/// tube([5, 2.7], [0, 8], #{chamfer: 0.5})
/// ```
fn tube(r, h) {
    tube(r, h, #{})
}

fn tube(r, h, opts) {
    _opts(opts, ["round", "chamfer", "anchor", "normalize"], "tube");
    let r = _pair(r, "tube: r");
    let zs = _height(h, "tube: h");
    let limit = min((r[0] - r[1]) * 0.5, (zs[1] - zs[0]) * 0.5);
    let shape = _extrude(annulus(r), zs, opts, limit, "tube");
    _anchor_round(shape, opts, r[0], zs, "tube")
}

/// cone(r: [number, number], h: Height, opts: #{ round?: Rim, sides?: number, anchor?: Anchor3, normalize?: bool } = #{}): Shape
/// type Height = number | [number, number]
/// type Rim = Sched | [Sched, Sched]
/// type Sched = Tree | ((t: Tree) => Tree) | Key[]
/// type Anchor3 = Vec3 | "center" | "left" | "right" | "front" | "back" | "bottom" | "top"
///
/// Cone along Z, or a frustum, a cone with its tip cut off, centred on the origin.
///
/// - `r`: `[bottom, top]`, the radii at the bottom and at the top; either may be 0, for a point
/// - `h`: the height, centred on z = 0, or `[z0, z1]`, from `z0` up to `z1`
/// - `opts`:
///   - `round`: the radius of the rims, clamped to the largest that fits; `[bottom, top]` for one each
///   - `sides`: the number of sides of a pyramid to make instead, or of a frustum of one, with a vertex on +X; the radii are then distances from the axis to the vertices
///   - `anchor`: the point put on the origin, as for `cuboid`
///   - `normalize`: `false` to skip the correction that keeps the field a distance when a rim's size varies; see the notes
///
/// A rim's size may vary along the cone, as for `cylinder`.
/// A rounded point is a ball of the rim's radius.
///
/// Notes:
/// - Field: exact, with rounded rims too; with `sides`, exact inside and a bound outside near the edges between the faces.
/// - Two rims of different sizes are each exact as long as neither reaches the other.
/// - A rim's size that varies keeps the field a distance to first order, at the cost of a second evaluation.
/// - `normalize: false` skips that correction: twice as fast, but offsets and shells come out uneven.
///
/// See also: `cylinder`, `loft`.
///
/// References:
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Capped Cone"
///
/// From OpenSCAD: `cylinder(h, r1, r2)` is `cone([r1, r2], [0, h])`.
///
/// Example: a foot for a box, standing on z = 0, its rims rounded.
/// ```
/// cone([6, 4], [0, 5], #{round: 1})
/// ```
/// Example: a hexagonal pyramid with a rounded base and tip.
/// ```
/// cone([10, 0], [0, 15], #{round: 1, sides: 6})
/// ```
fn cone(r, h) {
    cone(r, h, #{})
}

fn cone(r, h, opts) {
    _opts(opts, ["round", "sides", "anchor", "normalize"], "cone");
    let r = _pair(r, "cone: r");
    let r1 = _num(r[0], "cone: r");
    let r2 = _num(r[1], "cone: r");
    let zs = _height(h, "cone: h");
    // With sides, the distance from the axis square to the nearest face,
    // and the radii of the faces' middles: the nearest face's own cross
    // section, as the cone's.
    let qx = _hypot(x, y);
    if "sides" in opts {
        let n = opts.sides;
        if type_of(n) != "i64" || n < 3 {
            throw `cone: sides must be an integer of at least 3, got ${n}`;
        }
        let an = PI / n;
        qx = qx * cos(_atan2(y, x) % (2.0 * an) - an);
        r1 = r1 * cos(an);
        r2 = r2 * cos(an);
    }
    let k = (r2 - r1) / (zs[1] - zs[0]);
    let shape = if "round" in opts {
        _cone_rims(qx, r1, k, zs, opts)
    } else {
        _capped_cone(qx, r1, r2, zs[0], zs[1])
    };
    _anchor_round(shape, opts, max(r[0], r[1]), zs, "cone")
}

// The exact field of a cone cut square to its axis, from the bottom cap at
// `zb`, of radius `rb`, up to the top cap at `zt`, of radius `rt`: Inigo
// Quilez's capped cone, `qx` the distance from the axis.  Any of them may
// be a tree.
fn _capped_cone(qx, rb, rt, zb, zt) {
    let mid = (zb + zt) * 0.5;
    let hh = (zt - zb) * 0.5;
    let qy = if _is_number(mid) && mid == 0.0 { z } else { z - mid };
    // Outside, the distance to the nearer of the caps (ca) and the slanted
    // side; inside, the larger of the signed distances to the caps' plane
    // and to the side's line, exact in a convex solid.
    let r_cap = rt + (rb - rt) * _less(qy, 0.0);
    let cax = qx - min(qx, r_cap);
    let cay = abs(qy) - hh;
    let kx = rt - rb;
    let ky = 2.0 * hh;
    let kl = _hypot(kx, ky);
    let side = ((qx - rb) * ky - (qy + hh) * kx) / kl;
    let t = ((qx - rb) * kx + (qy + hh) * ky) / (kx * kx + ky * ky);
    _corner_of(max(cay, side), min(square(cax) + square(cay), _segment_dd(side, t, kl)))
}

// A cone of radius `r1` at `zs[0]`, widening by `k` per unit of height, up
// to `zs[1]`, its rims rounded as `opts.round` says.
//
// One radius for both rims: the cone whose caps and side are moved in by
// it, grown by it again, which rounds every rim exactly.  Two: each rim on
// a cone that runs on past the other cap, the solid their intersection, as
// `extrude` does.
fn _cone_rims(qx, r1, k, zs, opts) {
    let t = linstep(zs[0], zs[1], z);
    let v = _rim(opts.round, t, "cone: round");
    let limit = _cone_limit(r1, k, zs[1] - zs[0]);
    let v = [min(v[0], limit), min(v[1], limit)];
    if !_rim_pair(opts.round) || _is_number(v[0]) && _is_number(v[1]) && v[0] == v[1] {
        return _vary(|v| _cone_round(qx, r1, k, zs[0], zs[1], v), v[0], opts);
    }
    let h = zs[1] - zs[0];
    let bottom = _vary(|v| _cone_round(qx, r1, k, zs[0], zs[1] + h, v), v[0], opts);
    let top = _vary(|v| _cone_round(qx, r1 - k * h, k, zs[0] - h, zs[1], v), v[1], opts);
    max(bottom, top)
}

// The cone of radius `r1` at `z0`, widening by `k` per unit of height, up
// to `z1`, every rim rounded with radius `v`, which may be a tree.  Where
// the side moved in by `v` reaches the axis before a cap does, that is the
// tip of the smaller cone, and the rounded tip is a ball.
fn _cone_round(qx, r1, k, z0, z1, v) {
    let s = sqrt(1.0 + k * k);
    let zb = z0 + v;
    let zt = z1 - v;
    if k != 0.0 {
        let tip = z0 + (v * s - r1) / k;
        if k < 0.0 { zt = min(zt, tip) } else { zb = max(zb, tip) }
    }
    let rb = max(r1 + k * (zb - z0) - v * s, 0.0);
    let rt = max(r1 + k * (zt - z0) - v * s, 0.0);
    _capped_cone(qx, rb, rt, zb, zt) - v
}

// The largest rounding a cone of radius `r1` at its bottom, widening by
// `k` per unit of height, `h` tall, has room for: the radius of the
// largest ball on its axis, from the height where it touches the bottom
// and the side, where it touches the top and the side, or halfway.
fn _cone_limit(r1, k, h) {
    let s = sqrt(1.0 + k * k);
    let best = 0.0;
    for u in [h * 0.5, r1 / (s - k), (s * h - r1) / (s + k)] {
        if u >= 0.0 && u <= h {
            best = max(best, min(min(u, h - u), (r1 + k * u) / s));
        }
    }
    best
}

// A round solid anchored by its box: `r` from the axis, or a prism's
// corners at that circumradius with `opts.sides`, and `zs` along Z.
fn _anchor_round(shape, opts, r, zs, what) {
    if !("anchor" in opts) {
        return shape;
    }
    let lo = [-r, -r];
    let hi = [r, r];
    if "sides" in opts {
        let an = PI / opts.sides;
        lo = [r, 0.0];
        hi = [r, 0.0];
        for i in 1..opts.sides {
            let p = [r * cos(2.0 * an * i), r * sin(2.0 * an * i)];
            lo = [min(lo[0], p[0]), min(lo[1], p[1])];
            hi = [max(hi[0], p[0]), max(hi[1], p[1])];
        }
    }
    _anchor(shape, opts.anchor, [lo[0], lo[1], zs[0]], [hi[0], hi[1], zs[1]], what)
}

/// torus(r_major: number, r_minor: number, opts: #{ anchor?: Anchor3 } = #{}): Shape
/// type Anchor3 = Vec3 | "center" | "left" | "right" | "front" | "back" | "bottom" | "top"
///
/// Torus around the Z axis, centred on the origin.
///
/// - `r_major`: the radius of the circle through the middle of the tube
/// - `r_minor`: the radius of the tube
/// - `opts`:
///   - `anchor`: the point put on the origin, as for `cuboid`
///
/// Notes:
/// - Field: exact.
///
/// See also: `revolve`, `tube`.
///
/// Example: an O-ring, 40 across the middle of its tube and 6 thick.
/// ```
/// torus(20, 3)
/// ```
fn torus(r_major, r_minor) {
    torus(r_major, r_minor, #{})
}

fn torus(r_major, r_minor, opts) {
    _opts(opts, ["anchor"], "torus");
    let rm = _num(r_major, "torus: r_major");
    let rn = _num(r_minor, "torus: r_minor");
    let shape = _hypot(_hypot(x, y) - rm, z) - rn;
    let reach = rm + rn;
    _anchor(shape, _opt(opts, "anchor", ()), [-reach, -reach, -rn], [reach, reach, rn], "torus")
}

/// ellipsoid(radii: Vec3 | number, opts: #{ anchor?: Anchor3 } = #{}): Shape
/// type Anchor3 = Vec3 | "center" | "left" | "right" | "front" | "back" | "bottom" | "top"
///
/// Ellipsoid centred on the origin, with its radii along X, Y and Z.
///
/// - `radii`: `[rx, ry, rz]`, positive, or one number for a sphere
/// - `opts`:
///   - `anchor`: the point put on the origin, as for `cuboid`
///
/// fidget's `sphere(1).scale([rx, ry, rz])` has the same surface, but its field is off by a factor of the radius along each axis.
///
/// Notes:
/// - Field: approx, as `ellipse`'s: exact on the axes and at the surface, off by a little in between.
///
/// See also: `ellipse`, `scale_bound`.
///
/// References:
/// - Inigo Quilez, [Ellipsoid SDF](https://iquilezles.org/articles/ellipsoids/) (SDF, signed distance field)
///
/// From OpenSCAD: `scale([rx, ry, rz]) sphere(1)` is `ellipsoid([rx, ry, rz])`.
///
/// Example: a lentil-shaped bead, 20 across and 8 thick.
/// ```
/// ellipsoid([10, 10, 4])
/// ```
fn ellipsoid(radii) {
    ellipsoid(radii, #{})
}

fn ellipsoid(radii, opts) {
    _opts(opts, ["anchor"], "ellipsoid");
    let r = _vec3(radii, "ellipsoid: radii", 0.0);
    if r[0] <= 0.0 || r[1] <= 0.0 || r[2] <= 0.0 {
        throw `ellipsoid: radii must be three positive numbers, got ${radii}`;
    }
    // As `ellipse`, a dimension up.
    let k0 = _hypot(x / r[0], y / r[1], z / r[2]);
    let k1 = _hypot(x / (r[0] * r[0]), y / (r[1] * r[1]), z / (r[2] * r[2]));
    let lo = min(r[0], min(r[1], r[2]));
    let hi = max(r[0], max(r[1], r[2]));
    let shape = (k0 - 1.0) * clamp(k0 / max(k1, 1e-12), lo, hi);
    _anchor(shape, _opt(opts, "anchor", ()), r.map(|v| -v), r, "ellipsoid")
}

/// capsule(a: Vec3, b: Vec3, r: Tree): Shape
/// capsule(points: Vec3[], r: Tree): Shape
///
/// Every point within `r` of a segment, or of a path of segments: a rod with round ends.
///
/// - `a`, `b`: the segment's ends, `[x, y, z]`
/// - `points`: the path's points, at least two
/// - `r`: the radius; it may vary over space
///
/// Along a path, each segment is a capsule of its own, and their union rounds the joints.
///
/// Notes:
/// - Field: exact; along a path, exact outside, and a bound inside where the segments overlap.
///
/// See also: `rod`, `stroke`, `elongate`.
///
/// References:
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Capsule / Line"
///
/// From OpenSCAD: `hull() { translate(a) sphere(r); translate(b) sphere(r); }` is `capsule(a, b, r)`.
///
/// Example: a strut between two points.
/// ```
/// capsule([0, 0, 0], [10, 10, 20], 2)
/// ```
/// Example: a wire hook, bent through four points.
/// ```
/// let spine = [[0, 0, 0], [0, 0, 30], [8, 0, 34], [12, 0, 26]];
/// capsule(spine, 1.5)
/// ```
fn capsule(a, b, r) {
    let a = _vec3(a, "capsule: a", 0.0);
    let b = _vec3(b, "capsule: b", 0.0);
    let e = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    let wx = x - a[0];
    let wy = y - a[1];
    let wz = z - a[2];
    let ee = e[0] * e[0] + e[1] * e[1] + e[2] * e[2];
    let h = if ee > 0.0 { clamp((wx * e[0] + wy * e[1] + wz * e[2]) / ee, 0.0, 1.0) } else { 0.0 };
    _hypot(wx - e[0] * h, wy - e[1] * h, wz - e[2] * h) - _field(r, "capsule: r")
}

fn capsule(points, r) {
    if type_of(points) != "array" || points.len() < 2 {
        throw `capsule: needs at least 2 points, got ${points}`;
    }
    let parts = [];
    for i in 1..points.len() {
        parts.push(capsule(points[i - 1], points[i], r));
    }
    if parts.len() == 1 { parts[0] } else { union(parts) }
}

/// rod(a: Vec3, b: Vec3, r: Tree): Shape
///
/// Cylinder from `a` to `b`, its ends flat and square to it.
///
/// - `a`, `b`: the centres of its ends, `[x, y, z]`, different
/// - `r`: the radius; it may vary over space
///
/// It is a `cylinder` placed between two points, without working out the turns that would put it there.
///
/// Notes:
/// - Field: exact.
///
/// See also: `capsule`, `cylinder`.
///
/// Example: two posts and a diagonal brace between them.
/// ```
/// let post = cylinder(2, [0, 30]);
/// let brace = rod([-15, 0, 4], [15, 0, 26], 1.5);
/// union(post.move([-15, 0, 0]), post.move([15, 0, 0]), brace)
/// ```
fn rod(a, b, r) {
    let a = _vec3(a, "rod: a", 0.0);
    let b = _vec3(b, "rod: b", 0.0);
    let e = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    let l = norm(e);
    if l == 0.0 {
        throw `rod: a and b must differ, got ${a} twice`;
    }
    let u = e.map(|v| v / l);
    // The place along the axis, and the distance from it.
    let wx = x - a[0];
    let wy = y - a[1];
    let wz = z - a[2];
    let t = wx * u[0] + wy * u[1] + wz * u[2];
    let d = _hypot(wx - u[0] * t, wy - u[1] * t, wz - u[2] * t);
    _corner(d - _field(r, "rod: r"), abs(t - l * 0.5) - l * 0.5)
}

// --- Polyhedra ---

/// octahedron(r: Tree, opts: #{ anchor?: Anchor3 } = #{}): Shape
/// type Anchor3 = Vec3 | "center" | "left" | "right" | "front" | "back" | "bottom" | "top"
///
/// Regular octahedron centred on the origin, its vertices on the axes.
///
/// - `r`: the distance from the centre to each vertex; it may vary over space
/// - `opts`:
///   - `anchor`: the point put on the origin, as for `cuboid`; `r` must then be a number
///
/// It is every point whose distances from the origin along X, Y and Z add up to at most `r`.
/// A box grown by an octahedron has 45-degree chamfers on its edges and corners, as `cuboid` makes them with `chamfer`.
///
/// Notes:
/// - Field: exact.
///
/// See also: `cuboid`, `cone`.
///
/// References:
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Octahedron"
/// - [Octahedron, Wikipedia](https://en.wikipedia.org/wiki/Octahedron)
///
/// Example: a diamond standing on its tip.
/// ```
/// octahedron(10)
/// ```
fn octahedron(r) {
    octahedron(r, #{})
}

fn octahedron(r, opts) {
    _opts(opts, ["anchor"], "octahedron");
    let r = _field(r, "octahedron: r");
    let px = abs(x);
    let py = abs(y);
    let pz = abs(z);
    let m = px + py + pz - r;
    // Inside, and outside facing a face, the distance to the face's plane;
    // elsewhere, the distance to the nearest edge, found from the
    // coordinate that is small enough to put the point beyond an edge.
    let face = m / sqrt(3.0);
    let shape = _select_less(3.0 * px, m, _octahedron_edge(px, py, pz, r),
        _select_less(3.0 * py, m, _octahedron_edge(py, pz, px, r),
            _select_less(3.0 * pz, m, _octahedron_edge(pz, px, py, r), face)));
    // No closer than the face's plane: changes no value, but lets interval
    // arithmetic see where the octahedron ends, which the choice hides.
    let shape = max(shape, face);
    if !("anchor" in opts) {
        return shape;
    }
    let r = _num(r, "octahedron: r with an anchor");
    _anchor(shape, opts.anchor, [-r, -r, -r], [r, r, r], "octahedron")
}

// The distance to the octahedron's edges beside the face of the +X +Y +Z
// octant, for a point folded there, its small coordinate first.
fn _octahedron_edge(a, b, c, r) {
    let k = clamp(0.5 * (c - b + r), 0.0, r);
    _hypot(a, b - r + k, c - k)
}

// --- Half-spaces and slabs ---

/// half_space(p: Vec3, n: Vec3): Shape
///
/// Every point behind a plane, given by a point on it and its normal.
///
/// - `p`: a point on the plane, `[x, y, z]`
/// - `n`: the plane's normal, pointing out of the solid; any length
///
/// It is endless: intersect it with something finite.
/// Several half-spaces intersected make a convex polyhedron, such as a tooth or a blade given by its faces.
///
/// Notes:
/// - Field: exact.
///
/// See also: `plane_through`, `slab`, `half`, `plane`.
///
/// References:
/// - [Half-space, Wikipedia](https://en.wikipedia.org/wiki/Half-space_(geometry))
///
/// Example: a tube's end cut at 45 degrees, for a mitre joint.
/// ```
/// tube([10, 8], [0, 40])
///     .intersection(half_space([0, 0, 30], [1, 0, 1]))
/// ```
fn half_space(p, n) {
    let p = _vec3(p, "half_space: p", 0.0);
    let n = normalize(_vec3(n, "half_space: n", 0.0));
    (x - p[0]) * n[0] + (y - p[1]) * n[1] + (z - p[2]) * n[2]
}

/// plane_through(a: Vec3, b: Vec3, c: Vec3): Shape
///
/// The half-space behind the plane through three points.
///
/// - `a`, `b`, `c`: three points on the plane, not in a line, anticlockwise seen from outside
///
/// The outside is the side that `cross(b - a, c - a)` points to.
///
/// Notes:
/// - Field: exact.
///
/// See also: `half_space`.
///
/// From OpenSCAD: `polyhedron` lists a face's points clockwise seen from outside, so its face `[a, b, c]` is `plane_through(a, c, b)`.
///
/// Example: a cube with one corner cut off.
/// ```
/// let cut = plane_through([10, 0, 10], [10, 10, 0], [0, 10, 10]);
/// cuboid(20).intersection(cut)
/// ```
fn plane_through(a, b, c) {
    let a = _vec3(a, "plane_through: a", 0.0);
    let b = _vec3(b, "plane_through: b", 0.0);
    let c = _vec3(c, "plane_through: c", 0.0);
    let n = cross([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [c[0] - a[0], c[1] - a[1], c[2] - a[2]]);
    if norm(n) < 1e-9 {
        throw `plane_through: the points are in a line, ${a}, ${b} and ${c}`;
    }
    half_space(a, n)
}

/// slab(h: Height): Shape
/// type Height = number | [number, number]
///
/// Every point between two heights: an endless slab across X and Y.
///
/// - `h`: the thickness, centred on z = 0, or `[z0, z1]`, from `z0` up to `z1`
///
/// It is endless: intersect it with something finite, or use `flatten`.
///
/// Notes:
/// - Field: exact.
///
/// See also: `flatten`, `half_space`.
///
/// Example: a ball cut to a disc 4 thick, its edge round.
/// ```
/// sphere(10).intersection(slab(4))
/// ```
fn slab(h) {
    let zs = _height(h, "slab: h");
    let mid = (zs[0] + zs[1]) * 0.5;
    let half = (zs[1] - zs[0]) * 0.5;
    if mid == 0.0 { abs(z) - half } else { abs(z - mid) - half }
}

/// flatten(shape: Shape, h: Height): Shape
/// type Height = number | [number, number]
///
/// The part of a shape between two heights.
///
/// - `shape`: the shape
/// - `h`: the thickness, centred on z = 0, or `[z0, z1]`, from `z0` up to `z1`
///
/// It is the shape intersected with `slab(h)`.
///
/// Notes:
/// - Field: exact inside; outside, a bound near the cut edges.
///
/// See also: `slab`, `half`.
///
/// Example: a flat washer, 3 thick, cut from the middle of a torus.
/// ```
/// torus(20, 5).flatten(3)
/// ```
fn flatten(shape, h) {
    max(_tree(shape), slab(h))
}

/// half(shape: Shape, which: string): Shape
///
/// The half of a shape on one side of a plane through the origin.
///
/// - `shape`: the shape, 2D or 3D
/// - `which`: the half to keep: `"x+"`, `"x-"`, `"y+"`, `"y-"`, `"z+"` or `"z-"`; `"z+"` keeps z >= 0
///
/// It splits a part that prints better as two halves, each standing on its cut face.
///
/// Notes:
/// - Field: exact inside; outside, a bound near the cut edges.
///
/// See also: `flatten`, `half_space`, `symmetric_x`.
///
/// Example: a dome, the top half of a ball.
/// ```
/// sphere(10).half("z+")
/// ```
fn half(shape, which) {
    let s = _tree(shape);
    switch which {
        "x+" => max(s, -x),
        "x-" => max(s, x),
        "y+" => max(s, -y),
        "y-" => max(s, y),
        "z+" => max(s, -z),
        "z-" => max(s, z),
        _ => throw `half: which must be "x+", "x-", "y+", "y-", "z+" or "z-", got ${which}`,
    }
}

// --- Method forms ---

// Rhai calls a script function as a method only through `this`, so each
// function above whose first argument is a shape gets a twin for
// `shape.f(...)`.

fn flatten(h) { flatten(this, h) }
fn half(which) { half(this, which) }
