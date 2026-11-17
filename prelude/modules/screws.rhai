// SPDX-License-Identifier: MPL-2.0
//
// keycap module: metric screws and their holes.
//
// kind: 3d
//
//     import "keycap/screws" as screws;
//
// `screw` and `hole` take dimensions; the standards' tables only supply
// them, by size.  A screw stands as the prelude's cutters do: its axis
// along Z, z = 0 under its head, or on the surface a countersunk head ends
// flush with, its shank going down.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources, by the keys of keycap's parts research; the standards themselves
// were not read, only tables that restate them:
// - [W2] https://mechcodex.com/reference/metric-clearance-hole-sizes ,
//   https://www.noramark.com/resources/charts/clearance-hole-chart/
// - [F1] https://www.fasteners.eu/standards/ISO/4762/
// - [F2] https://fullerfasteners.com/tech/iso-7380-1-specifications-hex-socket-button-head-screws/
// - [F3] https://www.fasteners.eu/standards/iso/7380/
// - [F4] https://fullerfasteners.com/tech/iso-10642-specifications-hex-socket-countersunk-head-screws/
// - [F5] https://www.westfieldfasteners.co.uk/Standards/ScrewBolt-SHCsk-M.html
// - [F6] https://fullerfasteners.com/tech/iso-7046-1-specifications-countersunk-flat-head-screws/
// - [F7] https://www.mechlabgeek.com/en/fasteners/din-965
// - [F8] https://www.fasteners.eu/standards/ISO/4017/

import "keycap/threads" as threads;

// --- Tables ---

/// iso_4762(): #{ [size: string]: #{ dk: number, k: number, s: number, t: number } }
///
/// Socket head cap screws' heads (ISO 4762), by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `dk`: the head's diameter, the standard's maximum
/// - `k`: the head's height, the standard's maximum
/// - `s`: the hex socket's width across its flats
/// - `t`: the socket's depth, the least the key goes in
///
/// See also: `screws::spec`, `screws::screw`, `screw_hole`.
///
/// References:
/// - [ISO 4762, Hexagon socket head cap screws](https://www.iso.org/standard/34460.html)
/// - [fasteners.eu's table of ISO 4762](https://www.fasteners.eu/standards/ISO/4762/), the values' source
///
/// Example: an M3 socket head's diameter.
/// ```
/// screws::iso_4762()["M3"].dk
/// ```
fn iso_4762() {
    #{
        "M2": #{dk: 3.8, k: 2.0, s: 1.5, t: 1.0},       // [F1]
        "M2.5": #{dk: 4.5, k: 2.5, s: 2.0, t: 1.1},     // [F1]
        "M3": #{dk: 5.5, k: 3.0, s: 2.5, t: 1.3},       // [F1]
        "M4": #{dk: 7.0, k: 4.0, s: 3.0, t: 2.0},       // [F1]
        "M5": #{dk: 8.5, k: 5.0, s: 4.0, t: 2.5},       // [F1]
        "M6": #{dk: 10.0, k: 6.0, s: 5.0, t: 3.0},      // [F1]
        "M8": #{dk: 13.0, k: 8.0, s: 6.0, t: 4.0},      // [F1]
    }
}

/// iso_7380(): #{ [size: string]: #{ dk: number, k: number, s?: number, t?: number } }
///
/// Button head screws' heads (ISO 7380-1), by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `dk`: the head's diameter, the standard's maximum
/// - `k`: the head's height, the standard's maximum
/// - `s`: the hex socket's width across its flats
/// - `t`: the socket's depth, the least the key goes in
///
/// ISO 7380-1 starts at M3.
/// M2 and M2.5 are common supplier sizes, with no socket given.
/// Button heads with a collar, ISO 7380-2, are larger.
///
/// Notes:
/// - M2 and M2.5 are unverified.
///
/// See also: `screws::spec`, `screws::screw`, `screw_hole`.
///
/// References:
/// - [ISO 7380-1, Hexagon socket button head screws](https://www.iso.org/standard/78699.html)
/// - [Fuller Fasteners' table of ISO 7380-1](https://fullerfasteners.com/tech/iso-7380-1-specifications-hex-socket-button-head-screws/), the heads' source
/// - [fasteners.eu's table of ISO 7380](https://www.fasteners.eu/standards/iso/7380/), the sockets' depths' source
///
/// Example: an M4 button head's height.
/// ```
/// screws::iso_7380()["M4"].k
/// ```
fn iso_7380() {
    #{
        "M2": #{dk: 3.5, k: 1.3},                         // supplier size, unverified
        "M2.5": #{dk: 4.7, k: 1.5},                       // supplier size, unverified
        "M3": #{dk: 5.7, k: 1.65, s: 2.0, t: 1.04},       // [F2], [F3]
        "M4": #{dk: 7.6, k: 2.2, s: 2.5, t: 1.3},         // [F2], [F3]
        "M5": #{dk: 9.5, k: 2.75, s: 3.0, t: 1.56},       // [F2], [F3]
        "M6": #{dk: 10.5, k: 3.3, s: 4.0, t: 2.08},       // [F2], [F3]
        "M8": #{dk: 14.0, k: 4.4, s: 5.0, t: 2.6},        // [F2], [F3]
    }
}

/// iso_10642(): #{ [size: string]: #{ dk: number, dk_min: number, k: number, s: number } }
///
/// Countersunk socket head screws' heads (ISO 10642), 90 degrees, by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `dk`: the head's theoretical diameter, its sharp edge's
/// - `dk_min`: the smallest actual diameter, after the edge's break
/// - `k`: the head's height, the standard's maximum
/// - `s`: the hex socket's width across its flats
///
/// The table starts at M3; `screws::iso_7046` has M2 and M2.5.
///
/// Notes:
/// - ISO 10642's 2019 edition has M2 and M2.5 too, which the table lacks.
///
/// See also: `screws::iso_7046`, `screws::spec`, `screws::screw`, `screw_hole`.
///
/// References:
/// - [ISO 10642, Hexagon socket countersunk head screws](https://www.iso.org/standard/90795.html)
/// - [Fuller Fasteners' table of ISO 10642](https://fullerfasteners.com/tech/iso-10642-specifications-hex-socket-countersunk-head-screws/), and [Westfield Fasteners'](https://www.westfieldfasteners.co.uk/Standards/ScrewBolt-SHCsk-M.html), the values' sources
///
/// Example: an M3 countersunk head's diameter.
/// ```
/// screws::iso_10642()["M3"].dk
/// ```
fn iso_10642() {
    #{
        "M3": #{dk: 6.72, dk_min: 5.54, k: 1.86, s: 2.0},      // [F4], [F5]
        "M4": #{dk: 8.96, dk_min: 7.53, k: 2.48, s: 2.5},      // [F4], [F5]
        "M5": #{dk: 11.2, dk_min: 9.43, k: 3.1, s: 3.0},       // [F4], [F5]
        "M6": #{dk: 13.44, dk_min: 11.34, k: 3.72, s: 4.0},    // [F4], [F5]
        "M8": #{dk: 17.92, dk_min: 15.24, k: 4.96, s: 5.0},    // [F4], [F5]
    }
}

/// iso_7046(): #{ [size: string]: #{ dk: number, dk_max: number, dk_min: number, k: number } }
///
/// Countersunk cross-recess screws' heads (ISO 7046-1), 90 degrees, by size: the small sizes that `screws::iso_10642` lacks.
///
/// Each size's row, in the standard's symbols:
///
/// - `dk`: the head's theoretical diameter, its sharp edge's
/// - `dk_max`, `dk_min`: the actual diameter's range
/// - `k`: the head's height, the standard's maximum
///
/// A cross recess takes a cross-shaped bit, Phillips or Pozidriv, so the rows have no socket.
///
/// See also: `screws::iso_10642`, `screws::spec`.
///
/// References:
/// - [ISO 7046-1, Countersunk flat head screws with cross recess](https://www.iso.org/standard/57373.html)
/// - [Fuller Fasteners' table of ISO 7046-1](https://fullerfasteners.com/tech/iso-7046-1-specifications-countersunk-flat-head-screws/), the values' source
/// - [mechlabgeek's table of DIN 965](https://www.mechlabgeek.com/en/fasteners/din-965), the same screws in the German standard (DIN: Deutsches Institut für Normung)
///
/// Example: an M2 countersunk head's diameter.
/// ```
/// screws::iso_7046()["M2"].dk
/// ```
fn iso_7046() {
    #{
        "M2": #{dk: 4.4, dk_max: 3.8, dk_min: 3.5, k: 1.2},        // [F6], [F7]
        "M2.5": #{dk: 5.5, dk_max: 4.7, dk_min: 4.4, k: 1.5},      // [F6], [F7]
        "M3": #{dk: 6.3, dk_max: 5.5, dk_min: 5.2, k: 1.65},       // [F6], [F7]
    }
}

/// iso_4017(): #{ [size: string]: #{ s: number, k: number, k_max: number, e: number } }
///
/// Hex head screws' heads (ISO 4017), by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `s`: the head's width across its flats, the standard's maximum
/// - `k`: the head's nominal height
/// - `k_max`: its maximum, for product grade B
/// - `e`: the head's width across its corners, the standard's minimum for product grade B
///
/// ISO 4017's screws are threaded all along; ISO 4014's bolts, threaded part of the way, have the same heads.
///
/// Notes:
/// - M2 and M2.5 are from one table only, unverified.
///
/// See also: `screws::spec`, `screws::screw`.
///
/// References:
/// - [ISO 4017, Hexagon head screws](https://www.iso.org/standard/72585.html)
/// - [ISO 4014, Hexagon head bolts](https://www.iso.org/standard/72579.html)
/// - [fasteners.eu's table of ISO 4017](https://www.fasteners.eu/standards/ISO/4017/), the values' source
///
/// Example: an M5 hex head's width across its flats.
/// ```
/// screws::iso_4017()["M5"].s
/// ```
fn iso_4017() {
    #{
        "M2": #{s: 4.0, k: 1.4, k_max: 1.6, e: 4.18},      // [F8], unverified
        "M2.5": #{s: 5.0, k: 1.7, k_max: 1.9, e: 5.31},    // [F8], unverified
        "M3": #{s: 5.5, k: 2.0, k_max: 2.2, e: 5.88},      // [F8]
        "M4": #{s: 7.0, k: 2.8, k_max: 3.0, e: 7.5},       // [F8]
        "M5": #{s: 8.0, k: 3.5, k_max: 3.74, e: 8.63},     // [F8]
        "M6": #{s: 10.0, k: 4.0, k_max: 4.24, e: 10.89},   // [F8]
        "M8": #{s: 13.0, k: 5.3, k_max: 5.54, e: 14.2},    // [F8]
    }
}

/// iso_273(): #{ [size: string]: #{ fine: number, medium: number, coarse: number } }
///
/// Clearance holes for bolts and screws (ISO 273), by size.
///
/// - `fine`, `medium`, `coarse`: the hole's diameter in each of the standard's series, from the tightest to the loosest
///
/// The prelude's `metric` names the series `close`, `normal` and `loose`, and `screw_hole` takes `normal` unless told otherwise.
/// The holes follow the standard, which is for drilled holes.
/// Printed holes come out small, so a printed hole may need to be drawn larger: print a test.
///
/// See also: `screws::hole`, `screw_hole`, `metric`.
///
/// References:
/// - [ISO 273, Clearance holes for bolts and screws](https://www.iso.org/standard/4183.html)
/// - [MechCodex's table of metric clearance holes](https://mechcodex.com/reference/metric-clearance-hole-sizes), and [Noramark's](https://www.noramark.com/resources/charts/clearance-hole-chart/), the values' sources
///
/// Example: the usual hole for an M3 screw.
/// ```
/// screws::iso_273()["M3"].medium
/// ```
fn iso_273() {
    #{
        "M2": #{fine: 2.2, medium: 2.4, coarse: 2.6},      // [W2]
        "M2.5": #{fine: 2.7, medium: 2.9, coarse: 3.1},    // [W2]
        "M3": #{fine: 3.2, medium: 3.4, coarse: 3.6},      // [W2]
        "M4": #{fine: 4.3, medium: 4.5, coarse: 4.8},      // [W2]
        "M5": #{fine: 5.3, medium: 5.5, coarse: 5.8},      // [W2]
        "M6": #{fine: 6.4, medium: 6.6, coarse: 7.0},      // [W2]
        "M8": #{fine: 8.4, medium: 9.0, coarse: 10.0},     // [W2]
    }
}

/// spec(size: string, head: string = "socket"): Screw
/// type Screw = #{ d: number, pitch: number, head: Head }
/// type Head = #{ kind: string, dk?: number, k?: number, s?: number, t?: number }
///
/// A screw's dimensions by its size and head, from the tables.
///
/// - `size`: `"M3"`, or a fine thread, `"M8x1"`: M for metric, the nominal diameter, and after the x the pitch, in mm
/// - `head`: `"socket"` (ISO 4762), `"button"` (ISO 7380-1), `"countersunk"` (ISO 10642, or ISO 7046-1 below M3), `"hex"` (ISO 4017) or `"none"`
///
/// The returned map is what `screws::screw` takes, to change before passing it on:
///
/// - `d`: the nominal diameter
/// - `pitch`: the thread's pitch
/// - `head`: the head's row of its table, with `kind`, the head's name, added
///
/// A fine thread has the same head as its coarse size.
///
/// See also: `screws::screw`, `screws::iso_4762`, `screws::iso_7380`, `screws::iso_10642`, `screws::iso_7046`, `screws::iso_4017`, `threads::size`.
///
/// Example: an M3 button head screw's dimensions.
/// ```
/// screws::spec("M3", "button")
/// ```
fn spec(size) {
    _screws_spec(size, "socket")
}

fn spec(size, head) {
    _screws_spec(size, head)
}

private fn _screws_spec(size, head) {
    let t = threads::size(size);
    // A fine thread has its coarse size's head.
    let name = size.split("x")[0];
    let table = switch head {
        "socket" => iso_4762(),
        "button" => iso_7380(),
        "countersunk" => if name in iso_10642() { iso_10642() } else { iso_7046() },
        "hex" => iso_4017(),
        "none" => #{},
        _ => throw `screws::spec: head must be socket, button, countersunk, hex or none, got ${head}`,
    };
    let h = if head == "none" {
        #{}
    } else if name in table {
        table[name]
    } else {
        throw `screws::spec: no ${head} head for ${name}; known: ${table.keys()}`;
    };
    h.kind = head;
    #{d: t.d, pitch: t.pitch, head: h}
}

// A screw's name or its `Screw` map, its head chosen by `head` if not `()`:
// a kind, looked up for the size, or a `Head` map.
private fn _screws_of(screw, head, what) {
    let s = if type_of(screw) == "string" {
        _screws_spec(screw, if type_of(head) == "string" { head } else { "socket" })
    } else if type_of(screw) == "map" && "d" in screw && "head" in screw {
        screw
    } else {
        throw `${what}: a screw is a size such as "M3" or a map from screws::spec, got ${screw}`;
    };
    if type_of(head) == "map" {
        s.head = head;
    } else if type_of(head) == "string" && type_of(screw) == "map" {
        throw `${what}: a head named for a map of dimensions; give it as a map from screws::spec`;
    }
    s
}

// --- Screws ---

/// screw(size: string | Screw, length: number, opts: #{ head?: string | Head, threaded?: bool } = #{}): Shape
/// type Screw = #{ d: number, pitch: number, head: Head }
/// type Head = #{ kind: string, dk?: number, k?: number, s?: number, t?: number }
///
/// A metric screw, for reference and assemblies: its head on z = 0 and its shank going down.
///
/// - `size`: a size, `"M3"`, as `screws::spec` takes it, or the dimensions, a map from `screws::spec`
/// - `length`: the screw's nominal length below z = 0, from under the head; the whole screw's for a countersunk one
/// - `opts`:
///   - `head`: the head, a kind as `screws::spec` names them, `"socket"` by default, or its dimensions, a map
///   - `threaded`: an ISO thread, from `threads::external`, instead of a plain shank; false by default
///
/// The heads, from z = 0 up, or down for a countersunk one:
///
/// - `"socket"`: a cylinder `dk` across and `k` tall
/// - `"button"`: a spherical cap `dk` across and `k` tall
/// - `"countersunk"`: a 90-degree cone from `dk` across at z = 0 down to the shank
/// - `"hex"`: a hexagon `s` across its flats, `k` tall, its flats parallel to X
/// - `"none"`: no head
///
/// A head with `s` and `t` has a hex socket `s` across its flats and `t` deep.
///
/// Notes:
/// - Field: exact outside, except in the socket; a bound inside where the head meets the shank; with `threaded`, the thread's.
/// - Plain, with sharp edges: the standards' chamfers and radii are left out.
///
/// See also: `screws::spec`, `screws::hole`, `screw_hole`, `threads::external`.
///
/// Example: an M3 screw, 10 mm long, in a counterbore flush with the top of a plate.
/// ```
/// let block = cuboid([16, 16, 6]).difference(screw_hole("M3", 10));
/// union(block, screws::screw("M3", 10))
/// ```
fn screw(size, length) {
    _screws_screw(size, length, #{})
}

fn screw(size, length, opts) {
    _screws_screw(size, length, opts)
}

private fn _screws_screw(size, length, opts) {
    _opts(opts, ["head", "threaded"], "screws::screw");
    let s = _screws_of(size, _opt(opts, "head", ()), "screws::screw");
    let length = _num(length, "screws::screw: length");
    let h = s.head;
    // The shank reaches into the head, so that they do not meet on a face.
    let sunk = h.kind == "countersunk";
    let top = if sunk || h.kind == "none" { 0.0 } else { _num(h.k, "screws::screw: k") * 0.5 };
    let shank = if _opt(opts, "threaded", false) {
        threads::external(threads::basic(s.d, s.pitch), [-length, top], #{clearance: 0})
    } else {
        cylinder(s.d * 0.5, [-length, top])
    };
    if h.kind == "none" {
        return shank;
    }
    let head = switch h.kind {
        "socket" => cylinder(h.dk * 0.5, [0.0, h.k]),
        "button" => _screws_cap(h.dk * 0.5, h.k),
        "countersunk" => cone([s.d * 0.5, h.dk * 0.5], [-h.k, 0.0]),
        "hex" => hexagon_af(h.s).extrude([0.0, h.k]),
        _ => throw `screws::screw: head must be socket, button, countersunk, hex or none, got ${h.kind}`,
    };
    if h.kind != "hex" && "s" in h && "t" in h {
        let face = if sunk { 0.0 } else { h.k };
        head = head.difference(hexagon_af(h.s).extrude([face - h.t, face + 1.0]));
    }
    min(head, shank)
}

// A spherical cap of base radius `r` on z = 0, `k` tall.
private fn _screws_cap(r, k) {
    let big = (r * r + k * k) / (2.0 * k);
    max(_hypot(x, y, z - (k - big)) - big, -z)
}

// --- Holes ---

/// hole(d: number, length: number, opts: #{ counterbore?: number, countersink?: number } = #{}): Shape
///
/// Cutter for a screw of any size: a hole `d` across, from z = -`length` up, and the room for its head.
///
/// - `d`: the hole's diameter; `screws::iso_273` has the standard ones
/// - `length`: the hole's depth below z = 0
/// - `opts`:
///   - `counterbore`: the diameter of a round head's room, from z = 0 up
///   - `countersink`: the diameter at z = 0 of a 90-degree countersink below it
///
/// With neither, the hole is open above z = 0 too.
/// With either, the head's room is open above z = 0 without end.
///
/// No clearance is added.
/// Printed holes come out small, so a head's room needs some on top of the head's size.
/// `screw_hole` adds 0.4, which is printing practice, not a standard.
///
/// Notes:
/// - Field: exact outside, a bound inside where the room meets the hole.
///
/// See also: `screw_hole` for sizes by name, `screws::iso_273`, `screws::screw`.
///
/// Example: an M2 hole as wide as the screw, under a room 4 mm across for its head.
/// ```
/// let block = cuboid([10, 10, 6]);
/// let hole = screws::hole(2, 10, #{counterbore: 4}).move([0, 0, 1]);
/// block.difference(hole)
/// ```
fn hole(d, length) {
    _screws_hole(d, length, #{})
}

fn hole(d, length, opts) {
    _screws_hole(d, length, opts)
}

private fn _screws_hole(d, length, opts) {
    _opts(opts, ["counterbore", "countersink"], "screws::hole");
    let d = _num(d, "screws::hole: d");
    let length = _num(length, "screws::hole: length");
    if "counterbore" in opts && "countersink" in opts {
        throw "screws::hole: a counterbore or a countersink, not both";
    }
    if "counterbore" in opts {
        _screw_hole(d, length, "bore", _num(opts.counterbore, "screws::hole: counterbore") * 0.5)
    } else if "countersink" in opts {
        _screw_hole(d, length, "sink", _num(opts.countersink, "screws::hole: countersink") * 0.5)
    } else {
        _screw_hole(d, length, "none", 0.0)
    }
}
