// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: easing functions, keyframes and morphs.
//
// kind: math
//
// The easings are those of easings.net, the set OpenSCAD libraries copy.
// Each maps 0 to 0 and 1 to 1, takes a number or a tree, and clamps its
// argument to the range from 0 to 1, so that a tree such as
// `ease_in_cubic(z / 40)` holds still beyond its ends.

// --- Sine ---

/// ease_in_sine(t: Tree): Tree
///
/// Eases in along a quarter of a sine wave: slow at the start, fastest at the end.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_out_sine`, `ease_in_out_sine`, `ease_in_asine`.
///
/// References:
/// - [easeInSine, easings.net](https://easings.net/#easeInSine)
///
/// Example: a vase whose wall starts upright and leans out more and more towards the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_sine(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_sine(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    1.0 - _cos_poly(t * FRAC_PI_2)
}

/// ease_out_sine(t: Tree): Tree
///
/// Eases out along a quarter of a sine wave: fastest at the start, slow at the end.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_sine`, `ease_in_out_sine`, `ease_out_asine`.
///
/// References:
/// - [easeOutSine, easings.net](https://easings.net/#easeOutSine)
///
/// Example: a vase whose wall leans out at the foot and stands upright at the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_out_sine(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_out_sine(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    _sin_poly(t * FRAC_PI_2)
}

/// ease_in_out_sine(t: Tree): Tree
///
/// Eases in and out along half a cosine wave: slow at both ends.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_sine`, `ease_out_sine`, `ease_in_out_asine`.
///
/// References:
/// - [easeInOutSine, easings.net](https://easings.net/#easeInOutSine)
///
/// Example: a vase whose wall stands upright at the foot and the rim, and leans out between them. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_out_sine(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_out_sine(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    (1.0 - _cos_poly(t * PI)) * 0.5
}

// --- Arcsine ---

/// ease_in_asine(t: Tree): Tree
///
/// Eases in along an arcsine curve, the inverse of `ease_in_sine`: steepest at the start, where its graph is upright.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_out_asine`, `ease_in_out_asine`, `ease_in_sine`.
///
/// Example: a vase whose wall leaves the foot level, then turns upward. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_asine(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_asine(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    _ease_ends(t, acos(1.0 - t) / FRAC_PI_2)
}

/// ease_out_asine(t: Tree): Tree
///
/// Eases out along an arcsine curve, the inverse of `ease_out_sine`: steepest at the end, where its graph is upright.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_asine`, `ease_in_out_asine`, `ease_out_sine`.
///
/// Example: a vase whose wall rises steadily, then turns level at the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_out_asine(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_out_asine(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    _ease_ends(t, asin(t) / FRAC_PI_2)
}

/// ease_in_out_asine(t: Tree): Tree
///
/// Eases in and out along an arcsine curve, the inverse of `ease_in_out_sine`: steepest at both ends, where its graph is upright.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_asine`, `ease_out_asine`, `ease_in_out_sine`.
///
/// Example: a vase whose wall is level at the foot and the rim, and steepest halfway up. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_out_asine(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_out_asine(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    _ease_ends(t, acos(1.0 - 2.0 * t) / PI)
}

// --- Powers ---

/// ease_in_quadratic(t: Tree): Tree
///
/// Eases in as `t` squared.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_out_quadratic`, `ease_in_out_quadratic`, `ease_in_pow`.
///
/// References:
/// - [easeInQuad, easings.net](https://easings.net/#easeInQuad)
///
/// Example: a vase whose wall starts upright and leans out steadily more towards the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_quadratic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_quadratic(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    t * t
}

/// ease_out_quadratic(t: Tree): Tree
///
/// Eases out as `ease_in_quadratic` turned end for end: `1 - (1 - t)` squared.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_quadratic`, `ease_in_out_quadratic`, `ease_out_pow`.
///
/// References:
/// - [easeOutQuad, easings.net](https://easings.net/#easeOutQuad)
///
/// Example: a vase whose wall leans out at the foot and stands upright at the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_out_quadratic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_out_quadratic(t) {
    let u = 1.0 - clamp(_float(t), 0.0, 1.0);
    1.0 - u * u
}

/// ease_in_out_quadratic(t: Tree): Tree
///
/// Eases in and out with two halves of `ease_in_quadratic`, the second turned end for end.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_quadratic`, `ease_out_quadratic`, `ease_in_out_pow`.
///
/// References:
/// - [easeInOutQuad, easings.net](https://easings.net/#easeInOutQuad)
///
/// Example: a vase whose wall stands upright at the foot and the rim, and leans out most halfway up. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_out_quadratic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_out_quadratic(t) {
    _ease_in_out(t, |v| v * v)
}

/// ease_in_cubic(t: Tree): Tree
///
/// Eases in as `t` cubed.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_out_cubic`, `ease_in_out_cubic`, `ease_in_pow`.
///
/// References:
/// - [easeInCubic, easings.net](https://easings.net/#easeInCubic)
///
/// Example: a vase whose wall stays upright for longer, then leans out sharply towards the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_cubic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_cubic(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    t * t * t
}

/// ease_out_cubic(t: Tree): Tree
///
/// Eases out as `ease_in_cubic` turned end for end: `1 - (1 - t)` cubed.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_cubic`, `ease_in_out_cubic`, `ease_out_pow`.
///
/// References:
/// - [easeOutCubic, easings.net](https://easings.net/#easeOutCubic)
///
/// Example: a vase whose wall leans out sharply at the foot and soon stands upright. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_out_cubic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_out_cubic(t) {
    let u = 1.0 - clamp(_float(t), 0.0, 1.0);
    1.0 - u * u * u
}

/// ease_in_out_cubic(t: Tree): Tree
///
/// Eases in and out with two halves of `ease_in_cubic`, the second turned end for end.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_cubic`, `ease_out_cubic`, `ease_in_out_pow`.
///
/// References:
/// - [easeInOutCubic, easings.net](https://easings.net/#easeInOutCubic)
///
/// Example: a vase whose wall stays upright near the foot and the rim, and leans out sharply halfway up. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_out_cubic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_out_cubic(t) {
    _ease_in_out(t, |v| v * v * v)
}

/// ease_in_pow(t: Tree, n: number): Tree
/// ease_in_pow(n: number): Ease
///
/// Eases in as `t` to the power `n`.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
/// - `n`: the exponent, positive; 1 is linear, 2 `ease_in_quadratic`, 3 `ease_in_cubic`
///
/// Given `n` alone, it is the easing as a function of `t`, for `ease` and the `ease` options of `extrude`, `loft` and `keyframes`.
///
/// See also: `ease_out_pow`, `ease_in_out_pow`, `ease_in_cubic`.
///
/// Example: a vase whose wall stays upright, then leans out sharply near the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_pow(z / 40, 4));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
///
/// Example: a square column that narrows slowly at first, then sharply near the top.
/// ```
/// rect(20)
///     .extrude([0, 30], #{scale: 0.3, ease: ease_in_pow(3)})
/// ```
fn ease_in_pow(t, n) {
    pow(clamp(_float(t), 0.0, 1.0), _num(n, "ease_in_pow: n"))
}

/// ease_out_pow(t: Tree, n: number): Tree
/// ease_out_pow(n: number): Ease
///
/// Eases out as `ease_in_pow` turned end for end: `1 - (1 - t)` to the power `n`.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
/// - `n`: the exponent, positive; 1 is linear, 2 `ease_out_quadratic`, 3 `ease_out_cubic`
///
/// Given `n` alone, it is the easing as a function of `t`, for `ease` and the `ease` options of `extrude`, `loft` and `keyframes`.
///
/// See also: `ease_in_pow`, `ease_in_out_pow`, `ease_out_cubic`.
///
/// Example: a vase whose wall leans out sharply at the foot and soon stands upright. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_out_pow(z / 40, 4));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_out_pow(t, n) {
    1.0 - ease_in_pow(1.0 - clamp(_float(t), 0.0, 1.0), n)
}

/// ease_in_out_pow(t: Tree, n: number): Tree
/// ease_in_out_pow(n: number): Ease
///
/// Eases in and out with two halves of `ease_in_pow`, the second turned end for end.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
/// - `n`: the exponent, positive; 1 is linear, 2 `ease_in_out_quadratic`, 3 `ease_in_out_cubic`
///
/// Given `n` alone, it is the easing as a function of `t`, for `ease` and the `ease` options of `extrude`, `loft` and `keyframes`.
///
/// See also: `ease_in_pow`, `ease_out_pow`, `ease_in_out_cubic`.
///
/// Example: a vase whose wall stays upright near the foot and the rim, and leans out sharply halfway up. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_out_pow(z / 40, 4));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_out_pow(t, n) {
    _ease_in_out(t, |v| ease_in_pow(v, n))
}

// The easings of power `n`, as functions of `t` for `ease` and `loft`, as
// OpenSCAD's curried ones are.
fn ease_in_pow(n) {
    |t| ease_in_pow(t, n)
}

fn ease_out_pow(n) {
    |t| ease_out_pow(t, n)
}

fn ease_in_out_pow(n) {
    |t| ease_in_out_pow(t, n)
}

// --- Elastic ---

/// ease_in_elastic(t: Tree): Tree
///
/// Eases in with a growing wobble, which dips below 0 just before the end.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_out_elastic`, `ease_in_out_elastic`.
///
/// References:
/// - [easeInElastic, easings.net](https://easings.net/#easeInElastic)
///
/// Example: a vase whose wall ripples more and more towards the rim, pinches in just below it, then flares out. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_elastic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_elastic(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    let v = -exp((10.0 * t - 10.0) * LN_2) * _sin_poly((t * 10.0 - 10.75) * (TAU / 3.0));
    _ease_ends(t, v)
}

/// ease_out_elastic(t: Tree): Tree
///
/// Eases out with a wobble that overshoots past 1 at the start and settles.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_elastic`, `ease_in_out_elastic`.
///
/// References:
/// - [easeOutElastic, easings.net](https://easings.net/#easeOutElastic)
///
/// Example: a vase that bulges out just above the foot and ripples less and less towards the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_out_elastic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_out_elastic(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    let v = exp(-10.0 * t * LN_2) * _sin_poly((t * 10.0 - 0.75) * (TAU / 3.0)) + 1.0;
    _ease_ends(t, v)
}

/// ease_in_out_elastic(t: Tree): Tree
///
/// Eases in and out with a wobble at each end.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_elastic`, `ease_out_elastic`.
///
/// References:
/// - [easeInOutElastic, easings.net](https://easings.net/#easeInOutElastic)
///
/// Example: a vase that ripples near the foot and the rim, and widens sharply halfway up. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_out_elastic(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_out_elastic(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    let w = _sin_poly((20.0 * t - 11.125) * (TAU / 4.5)) * 0.5;
    let low = -exp((20.0 * t - 10.0) * LN_2) * w;
    let high = exp((10.0 - 20.0 * t) * LN_2) * w + 1.0;
    _ease_ends(t, _select_less(t, 0.5, low, high))
}

// --- Bounce ---

/// ease_out_bounce(t: Tree): Tree
///
/// Eases out like a ball dropped onto the floor at 1, bouncing three times.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_bounce`, `ease_in_out_bounce`.
///
/// References:
/// - [easeOutBounce, easings.net](https://easings.net/#easeOutBounce)
///
/// Example: a vase that widens to its full width a third of the way up, then dips in three times, less each time. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_out_bounce(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_out_bounce(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    let n = 7.5625;
    let d = 2.75;
    let t1 = t - 1.5 / d;
    let t2 = t - 2.25 / d;
    let t3 = t - 2.625 / d;
    let a = n * t * t;
    let b = n * t1 * t1 + 0.75;
    let c = n * t2 * t2 + 0.9375;
    let e = n * t3 * t3 + 0.984375;
    _select_less(t, 1.0 / d, a, _select_less(t, 2.0 / d, b, _select_less(t, 2.5 / d, c, e)))
}

/// ease_in_bounce(t: Tree): Tree
///
/// Eases in as `ease_out_bounce` turned end for end: the bounces come first.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_out_bounce`, `ease_in_out_bounce`.
///
/// References:
/// - [easeInBounce, easings.net](https://easings.net/#easeInBounce)
///
/// Example: a vase that bulges out three times near the foot, more each time, then widens fast to the rim. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_bounce(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_bounce(t) {
    1.0 - ease_out_bounce(1.0 - clamp(_float(t), 0.0, 1.0))
}

/// ease_in_out_bounce(t: Tree): Tree
///
/// Eases in and out with bounces at both ends.
///
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// See also: `ease_in_bounce`, `ease_out_bounce`.
///
/// References:
/// - [easeInOutBounce, easings.net](https://easings.net/#easeInOutBounce)
///
/// Example: a vase with small bulges near the foot and small dips near the rim, widening fast between them. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease_in_out_bounce(z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease_in_out_bounce(t) {
    let t = clamp(_float(t), 0.0, 1.0);
    let low = (1.0 - ease_out_bounce(1.0 - 2.0 * t)) * 0.5;
    let high = (1.0 + ease_out_bounce(2.0 * t - 1.0)) * 0.5;
    _select_less(t, 0.5, low, high)
}

// --- Steps ---

/// smootherstep(e0: number, e1: number, v: Tree): Tree
///
/// A step from 0 to 1 as `v` goes from edge `e0` to edge `e1`, smoother than `smoothstep`.
///
/// - `e0`, `e1`: the edges, `e0 != e1`
/// - `v`: the value
///
/// The result is 0 where `v <= e0` and 1 where `v >= e1`.
/// Its slope and its curvature are 0 at both edges.
/// So a size that follows it leaves no crease where it starts and stops changing.
///
/// See also: `smoothstep`, `linstep`, `ease_in_out_sine`.
///
/// References:
/// - [Smoothstep, Wikipedia](https://en.wikipedia.org/wiki/Smoothstep): smootherstep is Ken Perlin's variation
///
/// Example: a block whose edges are sharp up to its middle, then rounded more and more, by 4 mm at the top.
/// ```
/// let corner = 4 * smootherstep(0, 6, z);
/// cuboid([30, 20, 12], #{round: corner})
/// ```
fn smootherstep(e0, e1, v) {
    let t = linstep(e0, e1, v);
    t * t * t * (t * (6.0 * t - 15.0) + 10.0)
}

// --- By name ---

/// ease(name: Ease, t: Tree): Tree
///
/// Applies an easing, given by its name or as a function, to `t`.
///
/// - `name`: the easing, a name such as `"in_out_sine"`, or a function of `t`
/// - `t`: how far along, from 0 to 1; clamped to that range
///
/// A name is that of an easing function without `ease_`.
/// The names are `"linear"` and `"in_sine"`, `"out_sine"`, `"in_out_sine"`, and the same for `asine`, `quadratic`, `cubic`, `elastic` and `bounce`.
/// A function may be `ease_in_pow(3)`, `|t| ease_in_pow(t, 3)` or `Fn("ease_in_cubic")`.
///
/// The `ease` options of `extrude` and `loft`, and the easings of `keyframes`, take the same names and functions.
///
/// See also: `keyframes`, `ease_in_pow`.
///
/// References:
/// - [Easing functions, easings.net](https://easings.net/)
/// - Robert Penner, [Easing equations](http://robertpenner.com/easing/)
///
/// Example: a vase whose wall stands upright at the foot and the rim, its easing chosen by name. [view: camera front]
/// ```
/// let r = lerp(10, 20, ease("in_out_cubic", z / 40));
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 40))
/// ```
fn ease(name, t) {
    if type_of(name) == "Fn" {
        return name.call(clamp(_float(t), 0.0, 1.0));
    }
    switch name {
        "linear" => clamp(_float(t), 0.0, 1.0),
        "in_sine" => ease_in_sine(t),
        "out_sine" => ease_out_sine(t),
        "in_out_sine" => ease_in_out_sine(t),
        "in_asine" => ease_in_asine(t),
        "out_asine" => ease_out_asine(t),
        "in_out_asine" => ease_in_out_asine(t),
        "in_quadratic" => ease_in_quadratic(t),
        "out_quadratic" => ease_out_quadratic(t),
        "in_out_quadratic" => ease_in_out_quadratic(t),
        "in_cubic" => ease_in_cubic(t),
        "out_cubic" => ease_out_cubic(t),
        "in_out_cubic" => ease_in_out_cubic(t),
        "in_elastic" => ease_in_elastic(t),
        "out_elastic" => ease_out_elastic(t),
        "in_out_elastic" => ease_in_out_elastic(t),
        "in_bounce" => ease_in_bounce(t),
        "out_bounce" => ease_out_bounce(t),
        "in_out_bounce" => ease_in_out_bounce(t),
        "spline" => throw "ease: a spline needs the keys on either side; it is an easing of keyframes only",
        _ => throw `ease: unknown easing ${name}`,
    }
}

// --- Keyframes ---

/// keyframes(v: Tree, keys: Key[]): Tree
/// type Key = [number, Tree] | [number, Tree, Ease]
///
/// A value that runs through `keys` as `v` goes up, easing from each key to the next.
///
/// - `v`: where to read the keys, usually `z`; a number gives a number
/// - `keys`: `[at, value]` or `[at, value, easing]`, at least one, `at` increasing:
///   - `at`: where the key is
///   - `value`: the value there, a number or a tree
///   - `easing`: how the value is reached from the key before, `"linear"` by default; see `ease`
///
/// At `v = at`, the result is the key's `value`.
/// Between two keys, it moves along the second key's easing.
/// Below the first key it holds the first value, above the last key the last.
///
/// The easing `"spline"` reaches the key along a Catmull-Rom spline, which runs through every key smoothly.
/// At each key, the spline runs parallel to the line between the keys on either side.
///
/// Values that are trees blend as fields, so keyframes of shapes morph one into the next.
///
/// Notes:
/// - The result is a sum with a term for each change of value, so it costs little more than its easings.
/// - A spline overshoots between keys whose steps differ a lot.
///   The named easings never leave the range between two keys, except the elastic ones.
///
/// See also: `ease`, `loft`, `bezier_graph`, `catmull_rom`.
///
/// References:
/// - [Catmull-Rom spline, Wikipedia](https://en.wikipedia.org/wiki/Cubic_Hermite_spline#Catmull%E2%80%93Rom_spline)
///
/// Example: a vase whose radius runs through three keys, each reached along its own easing. [view: camera front]
/// ```
/// let r = keyframes(z, [
///     [0, 15],
///     [25, 25, "out_quadratic"],
///     [60, 20, "in_out_sine"],
/// ]);
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 60))
/// ```
/// Example: a vase whose radius runs smoothly through five keys. [view: camera front]
/// ```
/// let r = keyframes(z, [
///     [0, 14],
///     [15, 22, "spline"],
///     [30, 12, "spline"],
///     [45, 16, "spline"],
///     [60, 10, "spline"],
/// ]);
/// normalize_z(hypot(x, y) - r)
///     .intersection(max(-z, z - 60))
/// ```
fn keyframes(v, keys) {
    let at = [];
    let values = [];
    let eases = [];
    for k in keys {
        if type_of(k) != "array" || k.len() < 2 || k.len() > 3 {
            throw `keyframes: a key must be [at, value] or [at, value, easing], got ${k}`;
        }
        at.push(_num(k[0], "keyframes: a key's position"));
        values.push(_float(k[1]));
        eases.push(if k.len() == 3 { k[2] } else { "linear" });
    }
    _keyframes(v, at, values, eases)
}

// The telescoping sum behind `keyframes`: the first value plus, for every
// key, its change from the one before times its easing over the span.  An
// easing is 0 below its span and 1 above, so every span sees the sum of the
// changes before it, which is the value at its start.
fn _keyframes(v, at, values, eases) {
    if at.is_empty() {
        throw "keyframes: needs at least one key";
    }
    let out = values[0];
    for i in 1..at.len() {
        if at[i] <= at[i - 1] {
            throw `keyframes: keys must be in increasing order, got ${at[i - 1]} then ${at[i]}`;
        }
        let a = values[i - 1];
        let b = values[i];
        let e = eases[i];
        if type_of(e) == "string" && e == "spline" {
            out = out + _spline_span(v, at, values, i);
        } else if !(_is_number(a) && _is_number(b) && a == b) {
            out = out + (b - a) * ease(e, linstep(at[i - 1], at[i], v));
        }
    }
    out
}

// A span of a spline, as a term of the sum: a cubic Hermite curve from
// key `i - 1` to key `i`, whose slope at each end is Catmull-Rom's.  The
// Hermite terms for the slopes are 0 at both ends of the span, so the
// term is 0 below it and the change of value above it, as an easing's.
fn _spline_span(v, at, values, i) {
    let u = linstep(at[i - 1], at[i], v);
    let span = at[i] - at[i - 1];
    let m0 = _key_slope(at, values, i - 1) * span;
    let m1 = _key_slope(at, values, i) * span;
    let w = u * (1.0 - u);
    (values[i] - values[i - 1]) * u * u * (3.0 - 2.0 * u) + (m0 * (1.0 - u) - m1 * u) * w
}

// Catmull-Rom's slope at key `j`: that of the line between the keys on
// either side, or to the one neighbour of an end key.
fn _key_slope(at, values, j) {
    let lo = if j > 0 { j - 1 } else { j };
    let hi = if j + 1 < at.len() { j + 1 } else { j };
    (values[hi] - values[lo]) / (at[hi] - at[lo])
}

// --- Morphs ---

/// morph(a: Ray, b: Ray, t: Tree): Shape
/// type Ray = #{ r: Tree, slope: Tree }
///
/// An outline on the way from outline `a` to outline `b`, their points paired by direction from the origin.
///
/// - `a`, `b`: the outlines as rays, as `squircle_ray` gives them:
///   - `r`: the radius towards each point, a tree of its direction
///   - `slope`: the radius's derivative by the angle, divided by `r`
/// - `t`: from 0 at `a` to 1 at `b`, a number or a tree such as `linstep(0, 40, z)`
///
/// Each direction's radius runs from `a`'s to `b`'s.
/// So a corner of `a` moves straight out or in, to where `b` is in its direction.
///
/// Both outlines must be star-shaped about the origin: every ray from it crosses each outline once.
/// A circle of radius `r` is `#{r: r, slope: 0}`.
/// Any ray scales by multiplying its `r`.
///
/// Notes:
/// - Field: a distance to first order, as `polar_outline`'s.
/// - A `t` that varies with `z` makes slices that are each a distance; `normalize_z` makes the solid one in 3D, as `loft` does.
/// - `lerp(a, b, t)` of two shapes blends their fields instead: it pairs no points, and the outlines between differ.
///
/// See also: `squircle_ray`, `polar_outline`, `loft`, `lerp`.
///
/// References:
/// - [Star domain, Wikipedia](https://en.wikipedia.org/wiki/Star_domain)
///
/// From OpenSCAD: point-paired layers, their points set out by angle, morph the same way.
///
/// Example: a circle that becomes a squircle as it rises.
/// ```
/// let q = squircle_ray(x, y, 0.95);
/// let start = #{r: 10, slope: 0};
/// let end = #{r: 12 * q.r, slope: q.slope};
/// morph(start, end, linstep(0, 30, z))
///     .normalize_z()
///     .intersection(max(-z, z - 30))
/// ```
fn morph(a, b, t) {
    let a = _ray(a, "morph: a");
    let b = _ray(b, "morph: b");
    let t = _field(t, "morph: t");
    polar_outline(lerp(a.r, b.r, t), lerp(a.r * a.slope, b.r * b.slope, t))
}

// A `Ray`, checked, its values as floats or trees.
fn _ray(v, what) {
    if type_of(v) != "map" || !("r" in v) || !("slope" in v) {
        throw `${what} must be a ray #{r, slope}, as squircle_ray gives, got ${v}`;
    }
    #{r: _field(v.r, `${what}.r`), slope: _field(v.slope, `${what}.slope`)}
}

// --- Internals ---

// Symmetric in-out easing from an in-easing on 0..1: the in-easing over the
// first half, its point mirror over the second.
fn _ease_in_out(t, ease_in) {
    let t = clamp(_float(t), 0.0, 1.0);
    let low = ease_in.call(2.0 * t) * 0.5;
    let high = 1.0 - ease_in.call(2.0 - 2.0 * t) * 0.5;
    _select_less(t, 0.5, low, high)
}

// 0 at t = 0 and 1 at t = 1 exactly, where the elastic formulas are off by
// a thousandth and the arcsine ones have no gradient.
fn _ease_ends(t, v) {
    _select_less(0.0, t, _select_less(t, 1.0, v, 1.0), 0.0)
}
