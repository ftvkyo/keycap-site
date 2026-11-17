// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: transforms beyond fidget's `move`, `rotate*`,
// `scale*` and `reflect*`.
//
// kind: transform

// --- Rotation ---

/// rotate_xyz(shape: Shape, angles: Vec3): Shape
///
/// Turns a shape about X, then Y, then Z.
///
/// - `shape`: the shape
/// - `angles`: `[ax, ay, az]`, the turn about each axis, in degrees
///
/// Each turn is about the world's axis through the origin, as `rotate_x`, `rotate_y` and `rotate_z` turn.
/// The order matters: the turn about X comes first.
///
/// Notes:
/// - Field: exact where the shape's is.
///
/// See also: `rotate`, `rotate_x`, `rotate_y`, `rotate_z`.
///
/// From OpenSCAD: `rotate([ax, ay, az])` is `rotate_xyz(shape, [ax, ay, az])`.
///
/// Example: a rod laid along Y, then turned 45 degrees about Z.
/// ```
/// cylinder(2, 20).rotate_xyz([90, 0, 45])
/// ```
fn rotate_xyz(shape, angles) {
    let a = _vec3(angles, "rotate_xyz: angles", 0.0);
    rotate_z(rotate_y(rotate_x(shape, a[0]), a[1]), a[2])
}

// --- Symmetry ---

/// symmetric_x(shape: Shape): Shape
///
/// Mirrors a shape's +X half onto -X.
///
/// - `shape`: the shape; only its part at x >= 0 counts
///
/// Whatever the shape has at -X is replaced by the mirror image.
/// A part that is symmetric across the YZ plane can be drawn as its +X half only.
///
/// Notes:
/// - Field: exact, as long as the shape's +X half ends at x = 0 or crosses it square.
/// - Costs one evaluation of the shape, where `union(shape, shape.reflect_x())` costs two; the two agree when the shape lies at x >= 0.
///
/// See also: `symmetric_y`, `symmetric_z`, `reflect_x`, `kaleidoscope`.
///
/// References:
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Symmetry and repetition"
///
/// Example: a plate with a hole near each end, drawn as its +X half.
/// ```
/// cuboid([20, 10, 3], #{anchor: "left"})
///     .difference(cylinder(1.7, 4).move([15, 0, 0]))
///     .symmetric_x()
/// ```
fn symmetric_x(shape) {
    remap(_tree(shape), abs(x), y, z)
}

/// symmetric_y(shape: Shape): Shape
///
/// Mirrors a shape's +Y half onto -Y.
///
/// - `shape`: the shape; only its part at y >= 0 counts
///
/// Whatever the shape has at -Y is replaced by the mirror image, as `symmetric_x` does across X.
///
/// Notes:
/// - Field: exact, as long as the shape's +Y half ends at y = 0 or crosses it square.
///
/// See also: `symmetric_x`, `symmetric_z`, `reflect_y`.
///
/// Example: two pegs, one either side of the X axis.
/// ```
/// cylinder(2, 10)
///     .move([0, 15, 0])
///     .symmetric_y()
/// ```
fn symmetric_y(shape) {
    remap(_tree(shape), x, abs(y), z)
}

/// symmetric_z(shape: Shape): Shape
///
/// Mirrors a shape's +Z half onto -Z.
///
/// - `shape`: the shape; only its part at z >= 0 counts
///
/// Whatever the shape has at -Z is replaced by the mirror image, as `symmetric_x` does across X.
///
/// Notes:
/// - Field: exact, as long as the shape's +Z half ends at z = 0 or crosses it square.
///
/// See also: `symmetric_x`, `symmetric_y`, `reflect_z`.
///
/// Example: a double cone, from a cone standing on z = 0.
/// ```
/// cone([5, 0], [0, 10]).symmetric_z()
/// ```
fn symmetric_z(shape) {
    remap(_tree(shape), x, y, abs(z))
}

// --- Scaling ---

/// scale_exact(shape: Shape, k: Tree): Shape
///
/// Scales a shape by the same factor along every axis, about the origin, keeping its field a distance.
///
/// - `shape`: the shape
/// - `k`: the factor, positive; it may vary over space, such as with height
///
/// fidget's `scale_uniform` resizes the shape, but leaves its field in the shape's old units, `k` times too small or too large.
/// Offsets, shells and rounded combinations after it then come out `k` times too thick or too thin.
/// `scale_exact` multiplies the field by `k`, which makes it a distance again.
///
/// A 2D shape has no Z to scale, so a `k` that varies with z scales its slices, as `extrude`'s `scale` does.
///
/// Notes:
/// - Field: exact where the shape's is; with a `k` that varies, close to a distance only where `k` changes slowly.
///
/// See also: `scale_bound`, `scale_uniform`.
///
/// Example: a rounded cube scaled up, then offset by an even 1 mm.
/// ```
/// cuboid(10, #{round: 1})
///     .scale_exact(2)
///     .offset(1)
/// ```
/// Example: a rounded square post that tapers to half its width over 40 mm.
/// ```
/// let factor = lerp(1.0, 0.5, linstep(0, 40, z));
/// rect(20, #{round: 3})
///     .scale_exact(factor)
///     .flatten([0, 40])
/// ```
fn scale_exact(shape, k) {
    let k = _field(k, "scale_exact: k");
    if _is_number(k) {
        scale_uniform(shape, k) * k
    } else {
        // fidget's `scale_uniform` reads a tree factor as the shape.
        remap(_tree(shape), x / k, y / k, z / k) * k
    }
}

/// scale_bound(shape: Shape, k: Vec3 | Vec2): Shape
///
/// Scales a shape by a different factor along each axis, about the origin, keeping its field a bound.
///
/// - `shape`: the shape
/// - `k`: `[kx, ky, kz]`, the factors, positive; `[kx, ky]` for a 2D shape
///
/// fidget's `scale` gives the same surface, but leaves its field in the shape's old units.
/// That field is too small by up to the largest factor, or too large by up to the smallest.
/// `scale_bound` multiplies the field by the smallest factor, so it is never more than the distance.
///
/// A stretched circle or sphere is better made as an `ellipse` or an `ellipsoid`, and a stretched polygon as a `polygon` of scaled points.
/// Their fields are closer to a distance.
///
/// Notes:
/// - Field: bound; exact where the surface faces along the axis of the smallest factor, down to the smallest factor over the largest where it faces along the axis of the largest.
/// - Renders come out right, but offsets, shells and rounded combinations after it are thinner along the stretched axes.
///
/// See also: `scale_exact`, `scale`, `ellipse`, `ellipsoid`.
///
/// From OpenSCAD: `scale([kx, ky, kz])` is `scale_bound(shape, [kx, ky, kz])`.
///
/// Example: a hexagonal prism squashed to half its depth.
/// ```
/// cylinder(10, 5, #{sides: 6})
///     .scale_bound([1, 0.5, 1])
/// ```
fn scale_bound(shape, k) {
    let two = type_of(k) == "array" && k.len() == 2 || type_of(k) == "Vec2";
    let k = if two { _vec2(k, "scale_bound: k") + [1.0] } else { _vec3(k, "scale_bound: k", 1.0) };
    if k.some(|v| v <= 0.0) {
        throw `scale_bound: the factors must be positive, got ${k}`;
    }
    let least = if two { min(k[0], k[1]) } else { min(k[0], min(k[1], k[2])) };
    remap(_tree(shape), x / k[0], y / k[1], z / k[2]) * least
}

// --- Elongation ---

/// elongate(shape: Shape, e: Vec3 | Vec2 | number): Shape
///
/// Stretches a shape by moving its halves apart along each axis, the slice through the origin filling the gap.
///
/// - `shape`: the shape, centred where it is to be pulled apart
/// - `e`: `[ex, ey, ez]`, the length added along each axis; `[ex, ey]` for a 2D shape, or one number for every axis
///
/// The round parts keep their shape: a sphere becomes a capsule or a rounded box, a circle a slot, a torus a racetrack.
/// For a convex shape, the result is the hull of copies moved apart along each axis.
///
/// Notes:
/// - Field: exact outside when the shape's is; inside, a bound.
///
/// See also: `capsule`, `cuboid`.
///
/// References:
/// - Inigo Quilez, [Distance functions](https://iquilezles.org/articles/distfunctions/), "Elongation"
///
/// Example: a slot through a plate, for a screw that slides along it.
/// ```
/// let plate = cuboid([40, 20, 4]);
/// let hole = cylinder(1.7, 6).elongate([12, 0, 0]);
/// plate.difference(hole)
/// ```
fn elongate(shape, e) {
    let h = _vec3(e, "elongate: e", 0.0).map(|v| v * 0.5);
    if h.some(|v| v < 0.0) {
        throw `elongate: e must not be negative, got ${e}`;
    }
    let px = x - clamp(x, -h[0], h[0]);
    let py = y - clamp(y, -h[1], h[1]);
    remap(_tree(shape), px, py, z - clamp(z, -h[2], h[2]))
}

// --- Method forms ---

// Rhai calls a script function as a method only through `this`, so each
// function above whose first argument is a shape gets a twin for
// `shape.f(...)`.

fn rotate_xyz(angles) { rotate_xyz(this, angles) }
fn symmetric_x() { symmetric_x(this) }
fn symmetric_y() { symmetric_y(this) }
fn symmetric_z() { symmetric_z(this) }
fn scale_exact(k) { scale_exact(this, k) }
fn scale_bound(k) { scale_bound(this, k) }
fn elongate(e) { elongate(this, e) }
