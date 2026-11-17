// SPDX-License-Identifier: MPL-2.0
//
// keycap module: ISO metric screw threads.
//
// kind: 3d
//
//     import "keycap/threads" as threads;
//
// A thread is its profile in the plane through the axis, swept along a
// helix: a point's field is its distance, in that plane, from the profile,
// at its distance from the axis and its height above the nearest turn.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources, by the keys of keycap's parts research:
// - [W1] https://en.wikipedia.org/wiki/ISO_metric_screw_thread (ISO 68-1's
//   profile, ISO 261's coarse pitches; the standards were not read)
// - [T1] https://all3dp.com/2/3d-printing-threads-and-screws-all-you-need-to-know/
// - [T2] https://forum.prusa3d.com/forum/original-prusa-i3-mk3s-mk3-how-do-i-print-this-printing-help/mechanical-parts-threading-help-quality/
// - [T3] https://www.3dprinterstuff.com/workshop/3d-printing-threads-bolts

// --- Dimensions ---

/// iso_261(): #{ [size: string]: number }
///
/// Coarse pitches of ISO metric threads, by size.
///
/// A size is `"M"` and the thread's nominal diameter in mm: `"M3"` is 3 mm across.
/// The pitch is how far the thread rises in one turn.
/// ISO 261 lists the coarse and fine pitches of every size, and ISO 262 picks the sizes for bolts, screws and nuts; these are those sizes' coarse pitches.
///
/// Notes:
/// - From Wikipedia's table of the standards, not from their own text.
///
/// See also: `threads::size`, `threads::basic`.
///
/// References:
/// - [ISO metric screw thread, Wikipedia](https://en.wikipedia.org/wiki/ISO_metric_screw_thread)
/// - [ISO 261, General plan](https://www.iso.org/standard/4165.html)
/// - [ISO 262, Selected sizes for bolts, screws, studs and nuts](https://www.iso.org/standard/85105.html)
///
/// Example: the pitch of an M3 screw.
/// ```
/// threads::iso_261()["M3"]
/// ```
fn iso_261() {
    #{
        "M2": 0.4,      // [W1]
        "M2.5": 0.45,   // [W1]
        "M3": 0.5,      // [W1]
        "M4": 0.7,      // [W1]
        "M5": 0.8,      // [W1]
        "M6": 1.0,      // [W1]
        "M8": 1.25,     // [W1]
    }
}

/// basic(d: number, pitch: number): Thread
/// type Thread = #{ d: number, pitch: number, H: number, d2: number, d1: number, d3: number }
///
/// The diameters of an ISO metric thread's basic profile, from its diameter and pitch.
///
/// - `d`: the major diameter, the thread's nominal size
/// - `pitch`: the rise per turn; negative for a left-hand thread
///
/// The returned map:
///
/// - `d`, `pitch`: as given
/// - `H`: the height of the sharp 60-degree V the profile is cut from, `sqrt(3) / 2` times the pitch
/// - `d2`: the pitch diameter, `d - 0.75 H`, where the thread's ridges and grooves are equally wide
/// - `d1`: the minor diameter, `d - 1.25 H`: the internal thread's crests, and the basic profile's roots
/// - `d3`: an external thread's minor diameter with ISO 724's rounded root, `d - 1.226869 pitch`
///
/// The basic profile is ISO 68-1's: the V with `H / 8` cut off at the crests and `H / 4` at the roots.
///
/// Notes:
/// - `d3` is from Wikipedia, unverified against ISO 724.
///
/// See also: `threads::size`, `threads::external`, `threads::internal`.
///
/// References:
/// - [ISO metric screw thread, Wikipedia](https://en.wikipedia.org/wiki/ISO_metric_screw_thread)
/// - [ISO 68-1, Basic and design profiles](https://www.iso.org/standard/85107.html)
/// - [ISO 724, Basic dimensions](https://www.iso.org/standard/85104.html)
///
/// Example: the minor diameter of an M8x1 thread, 8 mm across with a fine pitch of 1 mm.
/// ```
/// threads::basic(8, 1.0).d1
/// ```
fn basic(d, pitch) {
    _threads_basic(d, pitch)
}

private fn _threads_basic(d, pitch) {
    let d = _num(d, "threads::basic: d");
    let pitch = _num(pitch, "threads::basic: pitch");
    if d <= 0.0 || pitch == 0.0 {
        throw `threads::basic: d must be positive and pitch not 0, got ${d} and ${pitch}`;
    }
    let p = abs(pitch);
    let h = sqrt(3.0) * 0.5 * p;
    #{d: d, pitch: pitch, H: h, d2: d - 0.75 * h, d1: d - 1.25 * h, d3: d - 1.226869 * p}
}

/// size(size: string): Thread
/// type Thread = #{ d: number, pitch: number, H: number, d2: number, d1: number, d3: number }
///
/// A metric thread by its name: `"M3"` with its coarse pitch, `"M8x1"` with the pitch given.
///
/// - `size`: `"M"`, the nominal diameter in mm, and optionally `"x"` and the pitch in mm
///
/// The map is `threads::basic`'s.
/// Without a pitch, the size must be one of `threads::iso_261`'s.
///
/// See also: `threads::basic`, `threads::iso_261`.
///
/// References:
/// - [ISO metric screw thread, Wikipedia](https://en.wikipedia.org/wiki/ISO_metric_screw_thread)
///
/// Example: an M3 thread's pitch diameter.
/// ```
/// threads::size("M3").d2
/// ```
fn size(size) {
    _threads_size(size)
}

private fn _threads_size(size) {
    if type_of(size) != "string" || !size.starts_with("M") {
        throw `threads::size: a size is a name such as "M3" or "M8x1", got ${size}`;
    }
    let parts = size.sub_string(1).split("x");
    let d = parse_float(parts[0]);
    if parts.len() == 2 {
        return _threads_basic(d, parse_float(parts[1]));
    }
    let pitches = iso_261();
    if !(size in pitches) {
        throw `threads::size: no coarse pitch for ${size}; known: ${pitches.keys()}; or give one, "${size}x1.5"`;
    }
    _threads_basic(d, pitches[size])
}

// A size's name, or a `Thread` map as it is.
private fn _threads_of(t, what) {
    if type_of(t) == "string" {
        _threads_size(t)
    } else if type_of(t) == "map" && "d" in t && "pitch" in t && "d1" in t {
        t
    } else {
        throw `${what}: a thread is a size such as "M3" or a map from threads::basic, got ${t}`;
    }
}

// --- Threads ---

/// external(size: string | Thread, h: Height, opts: #{ clearance?: number } = #{}): Shape
/// type Thread = #{ d: number, pitch: number, H: number, d2: number, d1: number, d3: number }
/// type Height = number | [number, number]
///
/// Threaded rod along Z: an external ISO metric thread with its basic profile.
///
/// - `size`: a size, `"M8"` or `"M8x1"`, as `threads::size` takes it, or a map from `threads::basic`
/// - `h`: its length, centred on z = 0, or `[z0, z1]`
/// - `opts`:
///   - `clearance`: taken off the profile all round, 0.2 by default; 0 for the nominal thread
///
/// The ends are cut flat.
/// The crests are flat at the major diameter `d`, and the roots flat at the minor diameter `d1`.
/// That is ISO 68-1's basic profile, without ISO 724's rounded root.
///
/// The default clearance is printing practice, not a standard, and printers differ.
/// 0.1 to 0.2 on the radius is the usual first guess for a printed thread.
/// Forum reports put vertical threads in good PLA (polylactic acid) at about 0.1, and horizontal ones, or PETG (glycol-modified polyethylene terephthalate), at about twice that.
/// Printed external threads below M6 come out poorly.
/// Print a test piece first.
///
/// Notes:
/// - Field: steep 1.003 on the flanks, up to 1.003 times the distance for ISO coarse pitches, more for steeper threads; a bound near the ends' edges.
/// - About 60 operations.
///
/// See also: `threads::internal`, `screws::screw` with `threaded`.
///
/// References:
/// - [ISO metric screw thread, Wikipedia](https://en.wikipedia.org/wiki/ISO_metric_screw_thread)
/// - [ISO 68-1, Basic and design profiles](https://www.iso.org/standard/85107.html)
/// - [All3DP's guide to printing threads and screws](https://all3dp.com/2/3d-printing-threads-and-screws-all-you-need-to-know/), for printed threads' clearance and smallest sizes
/// - [A Prusa forum thread on printed threads](https://forum.prusa3d.com/forum/original-prusa-i3-mk3s-mk3-how-do-i-print-this-printing-help/mechanical-parts-threading-help-quality/), its users' reports
///
/// Example: a printed M8 bolt, a hex head on 20 mm of thread.
/// ```
/// let head = hexagon_af(13).extrude([0, 5.3]);
/// let shaft = threads::external("M8", [-20, 1]);
/// union(head, shaft)
/// ```
fn external(size, h) {
    _threads_external(size, h, #{})
}

fn external(size, h, opts) {
    _threads_external(size, h, opts)
}

private fn _threads_external(size, h, opts) {
    _opts(opts, ["clearance"], "threads::external");
    let t = _threads_of(size, "threads::external");
    let zs = _height(h, "threads::external: h");
    let c = _num(_opt(opts, "clearance", 0.2), "threads::external: clearance");
    max(_threads_field(t) + c, max(zs[0] - z, z - zs[1]))
}

/// internal(size: string | Thread, depth: number, opts: #{ clearance?: number } = #{}): Shape
/// type Thread = #{ d: number, pitch: number, H: number, d2: number, d1: number, d3: number }
///
/// Cutter for an internal ISO metric thread: the threaded hole from z = -`depth` up to z = 0, and a plain bore of the major diameter above it, without end.
///
/// - `size`: a size, `"M8"` or `"M8x1"`, as `threads::size` takes it, or a map from `threads::basic`
/// - `depth`: the threaded length below z = 0
/// - `opts`:
///   - `clearance`: added to the profile all round, 0 by default, the nominal thread
///
/// The hole's bottom is flat.
/// The profile is `threads::external`'s, the basic profile.
///
/// A printed bolt from `threads::external` carries the clearance of the pair, so its nut needs none.
/// For a bought bolt, give the hole a clearance, as `threads::external` suggests.
/// Printed internal threads below M4 come out poorly: a heat-set insert or a tapped hole does better.
///
/// Notes:
/// - Field: steep 1.003 on the flanks, as `threads::external`'s; a bound near the bottom's edge.
/// - About 70 operations.
///
/// See also: `threads::external`, `nuts::nut` with `threaded`, `insert_hole`.
///
/// References:
/// - [ISO metric screw thread, Wikipedia](https://en.wikipedia.org/wiki/ISO_metric_screw_thread)
/// - [All3DP's guide to printing threads and screws](https://all3dp.com/2/3d-printing-threads-and-screws-all-you-need-to-know/)
///
/// Example: a printed nut for a printed M8 bolt.
/// ```
/// let nut = hexagon_af(13).extrude([0, 6.8]);
/// let socket = threads::internal("M8", 10).move([0, 0, 8]);
/// nut.difference(socket)
/// ```
fn internal(size, depth) {
    _threads_internal(size, depth, #{})
}

fn internal(size, depth, opts) {
    _threads_internal(size, depth, opts)
}

private fn _threads_internal(size, depth, opts) {
    _opts(opts, ["clearance"], "threads::internal");
    let t = _threads_of(size, "threads::internal");
    let depth = _num(depth, "threads::internal: depth");
    let c = _num(_opt(opts, "clearance", 0.0), "threads::internal: clearance");
    min(max(_threads_field(t) - c, -depth - z), _bore(t.d * 0.5 + c, 0.0))
}

// The basic profile swept along the thread's helix, without end: the
// distance, in the plane through the axis, from the point (r, w) to the
// profile, r being the point's distance from the axis and w its height
// above the middle of the nearest crest, folded to between 0 and half a
// pitch, where the profile is symmetric.
//
// From w = 0 the profile runs along the crest's flat at the major radius
// to w = pitch / 16, down the flank at 30 degrees from the radial to the
// minor radius at w = 3 pitch / 8, then along the root's flat.
//
// Lengths along the helix are measured in that plane, so the flanks'
// field is steeper than the distance by sqrt(1 + 0.75 k^2), k being
// pitch / (2 pi r): at most 1.003 at an ISO coarse thread's minor radius.
private fn _threads_field(t) {
    let p = abs(t.pitch);
    let r_maj = t.d * 0.5;
    let r_min = t.d1 * 0.5;
    let r = _hypot(x, y);
    let w = abs((z - t.pitch * _atan2(y, x) / TAU + p * 0.5) % p - p * 0.5);
    let w1 = p / 16.0;
    let w2 = p * 3.0 / 8.0;
    // The flank, from (r_maj, w1) to (r_min, w2); `line` is the signed
    // distance to its line, positive away from the axis.
    let ex = r_min - r_maj;
    let ey = w2 - w1;
    let el = sqrt(ex * ex + ey * ey);
    let wx = r - r_maj;
    let wy = w - w1;
    let line = (ey * wx - ex * wy) / el;
    let flank = _segment_dd(line, (wx * ex + wy * ey) / (el * el), el);
    let crest = square(r - r_maj) + square(max(w - w1, 0.0));
    let root = square(r - r_min) + square(max(w2 - w, 0.0));
    // Outside where the point is further out than the profile at its w.
    let outside = r - (r_maj + ex * clamp(wy / ey, 0.0, 1.0));
    let nearest = _select_less(w, w1, r - r_maj, _select_less(w2, w, r - r_min, line));
    let d = _signed_sqrt(min(flank, min(crest, root)), compare(outside, 0.0), nearest);
    // No closer than the cylinder of the crests: changes no value, but lets
    // interval arithmetic see where the thread ends.
    max(d, r - r_maj)
}
