// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: metric screws, nuts and heat-set inserts.
//
// kind: 3d
//
// Every function here returns a cutter: subtract it from a part.
// Cutters stand on the plane their doc names as z = 0 and stay open above
// it, without end, so they clear whatever lies over the hole.
//
// The modules `keycap/screws`, `keycap/nuts` and `keycap/inserts` have the
// standards' full tables, the parts themselves, and these cutters for
// dimensions of any size.
//
// Sources of `metric`'s table, by the keys of keycap's parts research; the
// standards themselves were not read, only tables that restate them.  The
// docs list the same sources, and the standards, as References.
// - [W1] https://en.wikipedia.org/wiki/ISO_metric_screw_thread
// - [W2] https://mechcodex.com/reference/metric-clearance-hole-sizes
// - [F1] https://www.fasteners.eu/standards/ISO/4762/
// - [F2] https://fullerfasteners.com/tech/iso-7380-1-specifications-hex-socket-button-head-screws/
// - [F4] https://fullerfasteners.com/tech/iso-10642-specifications-hex-socket-countersunk-head-screws/
// - [F6] https://fullerfasteners.com/tech/iso-7046-1-specifications-countersunk-flat-head-screws/
// - [F9] https://www.fasteners.eu/standards/ISO/4032/
// - [I1] https://www.3djake.com/ruthex/threaded-insert-m3-100-pieces
// - [I2] https://www.3djake.com/cnc-kitchen/threaded-insert-set-xl
// - [I4] https://www.printables.com/model/707184-ruthex-practice-and-measurement-tools

// --- Dimensions ---

/// metric(size: string | number): Metric
/// type Metric = #{ size: string, d: number, hole: #{ close: number, normal: number, loose: number }, tap: number, socket: #{ d: number, h: number }, button: #{ d: number, h: number }, countersunk: #{ d: number }, nut: #{ af: number, h: number }, insert: #{ d: number, h: number, depth: number } }
///
/// Dimensions of a metric screw size, in mm: its holes, its heads, its nut and its heat-set insert.
///
/// - `size`: `"M3"`, an ISO metric thread 3 mm across, or the number `3`; M2, M2.5, M3, M4, M5, M6 or M8
///
/// The returned map:
///
/// - `size`: the size's name, `"M3"`
/// - `d`: the nominal diameter
/// - `hole`: clearance holes from ISO 273: `close`, `normal` and `loose`, the standard's fine, medium and coarse series
/// - `tap`: the usual tap drill, for a screw that cuts its own thread into plastic
/// - `socket`: a socket head cap screw's head (ISO 4762), its diameter `d` and height `h`
/// - `button`: a button head's (ISO 7380-1), `d` and `h`
/// - `countersunk`: a 90-degree countersunk head's (ISO 10642), `d`, its theoretical sharp-edged diameter
/// - `nut`: a hex nut's (ISO 4032), `af` across its flats and its height `h`
/// - `insert`: a heat-set insert's, from CNC Kitchen's standard series: `d` the hole it asks for, `h` the insert's length, and `depth` the hole's, 1 more
///
/// Heads and nuts are at the standards' maximum sizes.
/// Every value is the part's own, with no clearance.
/// Printed holes come out small, so a printed hole for a head or a nut needs a clearance on top; the cutters here add one.
///
/// Notes:
/// - ISO 7380-1 starts at M3: the M2 and M2.5 button heads are common supplier sizes, unverified.
/// - The M2 and M2.5 countersunk heads are from ISO 7046-1, cross-recess screws with the same 90-degree head, as `screws::iso_10642` starts at M3.
/// - `keycap/inserts` has Ruthex's inserts and the short ones.
///
/// See also: `screw_hole`, `nut_trap`, `nut_slot`, `insert_hole`.
///
/// References:
/// - [ISO metric screw thread, Wikipedia](https://en.wikipedia.org/wiki/ISO_metric_screw_thread), for the coarse pitches behind `tap`
/// - [ISO 273, Clearance holes for bolts and screws](https://www.iso.org/standard/4183.html), and [a table of its holes](https://mechcodex.com/reference/metric-clearance-hole-sizes)
/// - [ISO 4762, Hexagon socket head cap screws](https://www.iso.org/standard/34460.html), and [fasteners.eu's table](https://www.fasteners.eu/standards/ISO/4762/)
/// - [ISO 7380-1, Hexagon socket button head screws](https://www.iso.org/standard/78699.html), and [Fuller Fasteners' table](https://fullerfasteners.com/tech/iso-7380-1-specifications-hex-socket-button-head-screws/)
/// - [ISO 10642, Hexagon socket countersunk head screws](https://www.iso.org/standard/90795.html), and [Fuller Fasteners' table](https://fullerfasteners.com/tech/iso-10642-specifications-hex-socket-countersunk-head-screws/)
/// - [ISO 7046-1, Countersunk flat head screws with cross recess](https://www.iso.org/standard/57373.html), and [Fuller Fasteners' table](https://fullerfasteners.com/tech/iso-7046-1-specifications-countersunk-flat-head-screws/)
/// - [ISO 4032, Hexagon regular nuts](https://www.iso.org/standard/75016.html), and [fasteners.eu's table](https://www.fasteners.eu/standards/ISO/4032/)
/// - CNC Kitchen's insert datasheet, [as 3DJake reproduces it](https://www.3djake.com/cnc-kitchen/threaded-insert-set-xl)
/// - CNC Kitchen, [Tips & Tricks for Heat-Set Inserts](https://www.cnckitchen.com/blog/tips-and-tricks-for-heat-set-inserts), for the hole 1 mm deeper than the insert
///
/// Example: an M3 nut's width across its flats.
/// ```
/// metric("M3").nut.af
/// ```
fn metric(size) {
    let key = if type_of(size) == "string" {
        size
    } else if type_of(size) == "i64" {
        `M${size}`
    } else if type_of(size) == "f64" && size == size.floor() {
        `M${size.to_int()}`
    } else {
        `M${size}`
    };
    let table = #{
        "M2": #{
            d: 2.0, hole: #{close: 2.2, normal: 2.4, loose: 2.6}, tap: 1.6,
            socket: #{d: 3.8, h: 2.0}, button: #{d: 3.5, h: 1.3}, countersunk: #{d: 4.4},
            nut: #{af: 4.0, h: 1.6}, insert: #{d: 3.2, h: 3.0, depth: 4.0},
        },
        "M2.5": #{
            d: 2.5, hole: #{close: 2.7, normal: 2.9, loose: 3.1}, tap: 2.05,
            socket: #{d: 4.5, h: 2.5}, button: #{d: 4.7, h: 1.5}, countersunk: #{d: 5.5},
            nut: #{af: 5.0, h: 2.0}, insert: #{d: 4.0, h: 4.0, depth: 5.0},
        },
        "M3": #{
            d: 3.0, hole: #{close: 3.2, normal: 3.4, loose: 3.6}, tap: 2.5,
            socket: #{d: 5.5, h: 3.0}, button: #{d: 5.7, h: 1.65}, countersunk: #{d: 6.72},
            nut: #{af: 5.5, h: 2.4}, insert: #{d: 4.0, h: 5.7, depth: 6.7},
        },
        "M4": #{
            d: 4.0, hole: #{close: 4.3, normal: 4.5, loose: 4.8}, tap: 3.3,
            socket: #{d: 7.0, h: 4.0}, button: #{d: 7.6, h: 2.2}, countersunk: #{d: 8.96},
            nut: #{af: 7.0, h: 3.2}, insert: #{d: 5.7, h: 8.1, depth: 9.1},
        },
        "M5": #{
            d: 5.0, hole: #{close: 5.3, normal: 5.5, loose: 5.8}, tap: 4.2,
            socket: #{d: 8.5, h: 5.0}, button: #{d: 9.5, h: 2.75}, countersunk: #{d: 11.2},
            nut: #{af: 8.0, h: 4.7}, insert: #{d: 6.5, h: 9.5, depth: 10.5},
        },
        "M6": #{
            d: 6.0, hole: #{close: 6.4, normal: 6.6, loose: 7.0}, tap: 5.0,
            socket: #{d: 10.0, h: 6.0}, button: #{d: 10.5, h: 3.3}, countersunk: #{d: 13.44},
            nut: #{af: 10.0, h: 5.2}, insert: #{d: 8.1, h: 12.7, depth: 13.7},
        },
        "M8": #{
            d: 8.0, hole: #{close: 8.4, normal: 9.0, loose: 10.0}, tap: 6.8,
            socket: #{d: 13.0, h: 8.0}, button: #{d: 14.0, h: 4.4}, countersunk: #{d: 17.92},
            nut: #{af: 13.0, h: 6.8}, insert: #{d: 9.7, h: 12.7, depth: 13.7},
        },
    };
    if !(key in table) {
        throw `metric: unknown size ${size}; known: M2, M2.5, M3, M4, M5, M6, M8`;
    }
    let m = table[key];
    m.size = key;
    m
}

// --- Screws ---

/// screw_hole(size: string | number, length: number, opts: #{ head?: string, fit?: string | number, clearance?: number } = #{}): Shape
///
/// Cutter for a metric screw: its clearance hole and the room for its head.
///
/// - `size`: `"M3"`, `3`, ..., as `metric` takes it
/// - `length`: the hole's depth below z = 0; longer than the material, so that the hole goes through
/// - `opts`:
///   - `head`: `"socket"` (the default), `"button"`, `"countersunk"`, or `"none"` for the hole alone
///   - `fit`: the hole: `"close"`, `"normal"` (the default) or `"loose"`, ISO 273's fine, medium and coarse series; `"tap"` for a screw that cuts its own thread; or a diameter
///   - `clearance`: added to the head's diameter, 0.4 by default
///
/// z = 0 is where the underside of the head rests.
/// The hole goes `length` below it, and the head's room goes up from it without end.
/// For a head on the part's surface, put z = 0 on the surface; for a counterbore, below it.
/// A countersunk head ends flush with z = 0, and the countersink goes down from it.
/// With `"none"`, the hole is open above z = 0 too.
///
/// The holes follow the standard.
/// The head's clearance is printing practice, not a standard: printed holes come out small, and 0.4 more on the diameter lets a head drop in.
///
/// Notes:
/// - Field: exact outside, a bound inside where the head's room meets the hole.
///
/// See also: `metric`, `nut_trap`, `screws::hole` for holes of any diameter.
///
/// References:
/// - [ISO 273, Clearance holes for bolts and screws](https://www.iso.org/standard/4183.html)
/// - CNC Kitchen, [Are Our Heat-Set Insert Datasheets Wrong?](https://www.cnckitchen.com/blog/are-our-heat-set-insert-datasheets-wrong), on printed holes coming out small
///
/// Example: a counterbore 3 mm deep for an M3 socket head, in a plate whose top is at z = 6.
/// ```
/// let plate = cuboid([20, 20, 12]);
/// let hole = screw_hole("M3", 10).move([0, 0, 3]);
/// plate.difference(hole)
/// ```
fn screw_hole(size, length) {
    screw_hole(size, length, #{})
}

fn screw_hole(size, length, opts) {
    _opts(opts, ["head", "fit", "clearance"], "screw_hole");
    let m = metric(size);
    let length = _num(length, "screw_hole: length");
    let fit = _opt(opts, "fit", "normal");
    let d = if type_of(fit) == "string" {
        if fit == "tap" {
            m.tap
        } else if fit in m.hole {
            m.hole[fit]
        } else {
            throw `screw_hole: fit must be close, normal, loose, tap or a diameter, got ${fit}`;
        }
    } else {
        _num(fit, "screw_hole: fit")
    };
    let clearance = _num(_opt(opts, "clearance", 0.4), "screw_hole: clearance");
    let head = _opt(opts, "head", "socket");
    if head == "none" {
        _screw_hole(d, length, "none", 0.0)
    } else if head == "socket" || head == "button" {
        _screw_hole(d, length, "bore", (m[head].d + clearance) * 0.5)
    } else if head == "countersunk" {
        _screw_hole(d, length, "sink", (m.countersunk.d + clearance) * 0.5)
    } else {
        throw `screw_hole: head must be socket, button, countersunk or none, got ${head}`;
    }
}

// A screw's cutter: a hole of diameter `d`, `length` below z = 0, and
// above z = 0, by `head`, the hole itself ("none"), a counterbore of radius
// `r` ("bore"), or a 90-degree countersink of radius `r` at z = 0 ("sink"),
// open above without end.
fn _screw_hole(d, length, head, r) {
    let shank = _bore(d * 0.5, -length);
    if head == "none" {
        return shank;
    }
    let room = min(shank, _bore(r, 0.0));
    if head == "bore" {
        return room;
    }
    // A 90-degree cone: its radius falls by 1 for every 1 down.
    min(room, max((_hypot(x, y) - r - z) / SQRT_2, z))
}

// A cylinder of radius `r` from z = `bottom` up without end.
fn _bore(r, bottom) {
    _corner(_hypot(x, y) - r, bottom - z)
}

// --- Nuts ---

/// nut_trap(size: string | number, depth: number, opts: #{ clearance?: number } = #{}): Shape
///
/// Cutter for a hex nut dropped in from above: a hexagonal pocket from z = -`depth` up without end.
///
/// - `size`: `"M3"`, `3`, ..., as `metric` takes it
/// - `depth`: the pocket's depth below z = 0, at least the nut's height, `metric(size).nut.h`
/// - `opts`:
///   - `clearance`: added across the flats, 0.4 by default
///
/// The pocket's flats are parallel to the X axis, with a corner on +X; `rotate_z(30)` turns a flat towards +X instead.
/// Union it with a `screw_hole` for the screw.
///
/// The nut follows the standard.
/// The clearance is printing practice, not a standard.
///
/// Notes:
/// - Field: exact inside, a bound outside near the bottom's corners.
///
/// See also: `nut_slot`, `screw_hole`, `nuts::trap` for square and thin nuts.
///
/// References:
/// - [ISO 4032, Hexagon regular nuts](https://www.iso.org/standard/75016.html)
///
/// Example: an M3 nut 3 mm deep in the top of a part, and the hole for its screw.
/// ```
/// let block = cuboid([12, 12, 10]);
/// let trap = union(
///     nut_trap("M3", 3),
///     screw_hole("M3", 10, #{head: "none"})
/// );
/// block.difference(trap.move([0, 0, 5]))
/// ```
fn nut_trap(size, depth) {
    nut_trap(size, depth, #{})
}

fn nut_trap(size, depth, opts) {
    _opts(opts, ["clearance"], "nut_trap");
    let m = metric(size);
    let clearance = _num(_opt(opts, "clearance", 0.4), "nut_trap: clearance");
    _nut_trap(hexagon_af(m.nut.af + clearance), _num(depth, "nut_trap: depth"))
}

// A nut's pocket: its 2D `outline` from z = -`depth` up without end.
fn _nut_trap(outline, depth) {
    max(outline, -depth - z)
}

/// nut_slot(size: string | number, length: number, opts: #{ clearance?: number } = #{}): Shape
///
/// Cutter for a captive hex nut slid in from the side: a hexagonal pocket centred on the origin, with a slot to +X.
///
/// - `size`: `"M3"`, `3`, ..., as `metric` takes it
/// - `length`: the slot's length from the nut's centre; long enough to reach out of the part
/// - `opts`:
///   - `clearance`: added to the nut's height and across its flats, 0.4 by default
///
/// The pocket is the nut's height plus `clearance` tall, centred on z = 0.
/// The slot runs `length` from the centre along +X, as wide as the pocket across its flats.
/// Union it with a `screw_hole` for the screw, along Z through the origin.
///
/// The nut follows the standard.
/// The clearance is printing practice, not a standard.
///
/// Notes:
/// - Field: exact outside, a bound inside where the slot meets the pocket.
///
/// See also: `nut_trap`, `screw_hole`, `nuts::slot` for square and thin nuts.
///
/// References:
/// - [ISO 4032, Hexagon regular nuts](https://www.iso.org/standard/75016.html)
///
/// Example: a nut's slot from the middle of a part out through its side, and the screw's hole across it.
/// ```
/// let block = cuboid([16, 12, 8]);
/// let slot = union(
///     nut_slot("M3", 10),
///     screw_hole("M3", 5, #{head: "none"})
/// );
/// block.difference(slot)
/// ```
fn nut_slot(size, length) {
    nut_slot(size, length, #{})
}

fn nut_slot(size, length, opts) {
    _opts(opts, ["clearance"], "nut_slot");
    let m = metric(size);
    let clearance = _num(_opt(opts, "clearance", 0.4), "nut_slot: clearance");
    let af = m.nut.af + clearance;
    _nut_slot(hexagon_af(af), af, m.nut.h + clearance, _num(length, "nut_slot: length"))
}

// A nut's slot: its 2D `outline`, `h` tall and centred on z = 0, joined
// by a slot `w` wide running `length` from the centre along +X.
fn _nut_slot(outline, w, h, length) {
    extrude(min(outline, rect([length, w]).move([length * 0.5, 0.0])), h)
}

// --- Inserts ---

/// insert_hole(size: string | number, depth: number = metric(size).insert.depth, opts: #{ d?: number } = #{}): Shape
///
/// Cutter for a heat-set insert: a pocket of the insert's hole diameter, from z = -`depth` up without end.
///
/// - `size`: `"M3"`, `3`, ..., as `metric` takes it
/// - `depth`: the pocket's depth below z = 0; by default 1 mm more than the insert is long, as the makers ask, since melting it in pushes plastic down
/// - `opts`:
///   - `d`: the hole's diameter, instead of the table's
///
/// The hole and the length are those of CNC Kitchen's standard inserts.
/// Other makers' differ: check the datasheet of yours.
/// The hole is the datasheet's, with no clearance; printed holes come out small, so a test print tells whether yours needs `d` larger.
///
/// Notes:
/// - Field: exact.
///
/// See also: `metric`, `inserts::hole` for Ruthex's inserts and the short ones.
///
/// References:
/// - CNC Kitchen's insert datasheet, [as 3DJake reproduces it](https://www.3djake.com/cnc-kitchen/threaded-insert-set-xl)
/// - CNC Kitchen, [Tips & Tricks for Heat-Set Inserts](https://www.cnckitchen.com/blog/tips-and-tricks-for-heat-set-inserts)
///
/// Example: an M3 insert's pocket in a part whose top is at z = 10.
/// ```
/// let block = cuboid([12, 12, 20]);
/// let hole = insert_hole("M3").move([0, 0, 10]);
/// block.difference(hole)
/// ```
fn insert_hole(size) {
    insert_hole(size, metric(size).insert.depth, #{})
}

fn insert_hole(size, depth) {
    insert_hole(size, depth, #{})
}

fn insert_hole(size, depth, opts) {
    _opts(opts, ["d"], "insert_hole");
    let m = metric(size);
    let d = _num(_opt(opts, "d", m.insert.d), "insert_hole: d");
    _bore(d * 0.5, -_num(depth, "insert_hole: depth"))
}
