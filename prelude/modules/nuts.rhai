// SPDX-License-Identifier: MPL-2.0
//
// keycap module: metric nuts, washers and their pockets.
//
// kind: 3d
//
//     import "keycap/nuts" as nuts;
//
// `nut`, `washer`, `trap` and `slot` take dimensions; the standards'
// tables only supply them, by size.  A nut stands on z = 0, its axis along
// Z and its flats parallel to X, as the prelude's `nut_trap` has it.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources, by the keys of keycap's parts research; the standards themselves
// were not read, only tables that restate them:
// - [F9] https://www.fasteners.eu/standards/ISO/4032/
// - [F10] https://www.fasteners.eu/standards/ISO/4035/
// - [F11] https://www.fasteners.eu/standards/iso/7040/
// - [F12] https://www.fasteners.eu/standards/ISO/7089/ (a DIN 125 table)
// - [S1] https://www.boltsfastener.com/standards/nuts-standard/din-562.html ,
//   https://www.ssfastenersmfgr.com/square-thin-nuts-specifications-DIN-562.html
// - [S2] https://tdm-neva.ru/upload/nuts/din-562.pdf (from a search snippet)
// - [N1] https://brasscomponents.la/en/iso-7040-prevailing-torque-nuts

import "keycap/threads" as threads;

// --- Tables ---

/// iso_4032(): #{ [size: string]: #{ s: number, m: number, m_min: number, e: number } }
///
/// Hex nuts (ISO 4032), by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `s`: the width across the flats, the standard's maximum
/// - `m`: the height, the standard's maximum
/// - `m_min`: its minimum
/// - `e`: the width across the corners, the standard's minimum
///
/// See also: `nuts::spec`, `nuts::nut`, `nut_trap`.
///
/// References:
/// - [ISO 4032, Hexagon regular nuts](https://www.iso.org/standard/75016.html)
/// - [fasteners.eu's table of ISO 4032](https://www.fasteners.eu/standards/ISO/4032/), the values' source
///
/// Example: an M3 nut's height.
/// ```
/// nuts::iso_4032()["M3"].m
/// ```
fn iso_4032() {
    #{
        "M2": #{s: 4.0, m: 1.6, m_min: 1.35, e: 4.32},       // [F9]
        "M2.5": #{s: 5.0, m: 2.0, m_min: 1.75, e: 5.45},     // [F9]
        "M3": #{s: 5.5, m: 2.4, m_min: 2.15, e: 6.01},       // [F9]
        "M4": #{s: 7.0, m: 3.2, m_min: 2.9, e: 7.66},        // [F9]
        "M5": #{s: 8.0, m: 4.7, m_min: 4.4, e: 8.79},        // [F9]
        "M6": #{s: 10.0, m: 5.2, m_min: 4.9, e: 11.05},      // [F9]
        "M8": #{s: 13.0, m: 6.8, m_min: 6.44, e: 14.38},     // [F9]
    }
}

/// iso_4035(): #{ [size: string]: #{ s: number, m: number, m_min: number } }
///
/// Thin hex nuts (ISO 4035), by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `s`: the width across the flats, the standard's maximum
/// - `m`: the height, the standard's maximum
/// - `m_min`: its minimum
///
/// A thin nut holds less than a regular one; ISO 4035 means it as a jam nut, tightened against a regular nut.
///
/// Notes:
/// - The source's width across the corners is left out: its M5 value disagrees with ISO 4032's for the same hexagon.
///
/// See also: `nuts::iso_4032`, `nuts::spec`.
///
/// References:
/// - [ISO 4035, Hexagon thin nuts](https://www.iso.org/standard/75019.html)
/// - [fasteners.eu's table of ISO 4035](https://www.fasteners.eu/standards/ISO/4035/), the values' source
///
/// Example: an M3 thin nut's height.
/// ```
/// nuts::iso_4035()["M3"].m
/// ```
fn iso_4035() {
    #{
        "M2": #{s: 4.0, m: 1.2, m_min: 0.95},      // [F10]
        "M2.5": #{s: 5.0, m: 1.6, m_min: 1.35},    // [F10]
        "M3": #{s: 5.5, m: 1.8, m_min: 1.55},      // [F10]
        "M4": #{s: 7.0, m: 2.2, m_min: 1.95},      // [F10]
        "M5": #{s: 8.0, m: 2.7, m_min: 2.45},      // [F10]
        "M6": #{s: 10.0, m: 3.2, m_min: 2.9},      // [F10]
        "M8": #{s: 13.0, m: 4.0, m_min: 3.7},      // [F10]
    }
}

/// din_562(): #{ [size: string]: #{ s: number, m: number, m_min?: number, e?: number } }
///
/// Square thin nuts (DIN 562), by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `s`: the width across the flats, the standard's maximum
/// - `m`: the height, the standard's maximum
/// - `m_min`: its minimum
/// - `e`: the width across the corners, the standard's minimum
///
/// DIN 562 is a German standard (DIN: Deutsches Institut für Normung), with no ISO counterpart.
/// Square nuts are common in printed parts' nut slots and in laser-cut T-slots.
///
/// Notes:
/// - M2 and M2.5 are from a single catalogue, unverified, and have no `m_min` or `e`.
///
/// See also: `nuts::spec`, `nuts::slot`, `lc::t_slot`.
///
/// References:
/// - [DIN 562, Square thin nuts](https://www.dinmedia.de/en/standard/din-562/178392223)
/// - [Bolts Fastener's table of DIN 562](https://www.boltsfastener.com/standards/nuts-standard/din-562.html), and [SS Fasteners'](https://www.ssfastenersmfgr.com/square-thin-nuts-specifications-DIN-562.html), the sources of M3 to M8
/// - [A catalogue's table of DIN 562](https://tdm-neva.ru/upload/nuts/din-562.pdf), the source of M2 and M2.5
///
/// Example: an M3 square nut's width.
/// ```
/// nuts::din_562()["M3"].s
/// ```
fn din_562() {
    #{
        "M2": #{s: 4.0, m: 1.2},                          // [S2], unverified
        "M2.5": #{s: 5.0, m: 1.6},                        // [S2], unverified
        "M3": #{s: 5.5, m: 1.8, m_min: 1.4, e: 7.0},      // [S1]
        "M4": #{s: 7.0, m: 2.2, m_min: 1.8, e: 8.9},      // [S1]
        "M5": #{s: 8.0, m: 2.7, m_min: 2.3, e: 10.2},     // [S1]
        "M6": #{s: 10.0, m: 3.2, m_min: 2.72, e: 12.7},   // [S1]
        "M8": #{s: 13.0, m: 4.0, m_min: 3.52, e: 16.5},   // [S1]
    }
}

/// iso_7040(): #{ [size: string]: #{ s: number, h: number, h_min: number } }
///
/// Nyloc nuts (ISO 7040), by size: hex nuts with a nylon ring that grips the screw, so that they do not work loose.
///
/// Each size's row, in the standard's symbols:
///
/// - `s`: the width across the flats, the standard's maximum
/// - `h`: the whole height, with the nylon ring's dome, the standard's maximum
/// - `h_min`: its minimum
///
/// M3 and M4 are in the standard's annex; there is no M2 or M2.5.
///
/// Notes:
/// - For M5, ISO 7040:2025 gives `h` 6.8, while older tables and the German DIN 982 (DIN: Deutsches Institut für Normung) give 6.3.
/// - For M6, older tables give `h_min` 7.7.
///
/// See also: `nuts::spec`, `nuts::nut`.
///
/// References:
/// - [ISO 7040, Prevailing torque hexagon nuts with non-metallic insert](https://www.iso.org/standard/86033.html)
/// - [Brass Components' page on ISO 7040](https://brasscomponents.la/en/iso-7040-prevailing-torque-nuts), the values' source
/// - [fasteners.eu's table of ISO 7040](https://www.fasteners.eu/standards/iso/7040/), an older table
/// - [Nyloc nut, Wikipedia](https://en.wikipedia.org/wiki/Nyloc_nut)
///
/// Example: an M3 nyloc nut's height.
/// ```
/// nuts::iso_7040()["M3"].h
/// ```
fn iso_7040() {
    #{
        "M3": #{s: 5.5, h: 4.5, h_min: 4.02},     // [N1], [F11]
        "M4": #{s: 7.0, h: 6.0, h_min: 5.52},     // [N1], [F11]
        "M5": #{s: 8.0, h: 6.8, h_min: 6.22},     // [N1]; 6.3 in [F11]
        "M6": #{s: 10.0, h: 8.0, h_min: 7.42},    // [N1]; h_min 7.7 in older tables
        "M8": #{s: 13.0, h: 9.5, h_min: 8.92},    // [N1], [F11]
    }
}

/// iso_7089(): #{ [size: string]: Washer }
/// type Washer = #{ d1: number, d2: number, h: number }
///
/// Plain washers, normal series, product grade A (ISO 7089), by size.
///
/// Each size's row, in the standard's symbols:
///
/// - `d1`: the hole, the standard's minimum
/// - `d2`: the outer diameter, the standard's maximum
/// - `h`: the thickness, nominal
///
/// The German DIN 125-A washers (DIN: Deutsches Institut für Normung) are the same size.
///
/// Notes:
/// - From a table of DIN 125, not from the standard's own text.
///
/// See also: `nuts::washer`.
///
/// References:
/// - [ISO 7089, Plain washers, normal series, product grade A](https://www.iso.org/standard/13666.html)
/// - [fasteners.eu's table of ISO 7089](https://www.fasteners.eu/standards/ISO/7089/), the values' source
///
/// Example: an M3 washer's outer diameter.
/// ```
/// nuts::iso_7089()["M3"].d2
/// ```
fn iso_7089() {
    #{
        "M2": #{d1: 2.2, d2: 5.0, h: 0.3},      // [F12]
        "M2.5": #{d1: 2.7, d2: 6.0, h: 0.5},    // [F12]
        "M3": #{d1: 3.2, d2: 7.0, h: 0.5},      // [F12]
        "M4": #{d1: 4.3, d2: 9.0, h: 0.8},      // [F12]
        "M5": #{d1: 5.3, d2: 10.0, h: 1.0},     // [F12]
        "M6": #{d1: 6.4, d2: 12.0, h: 1.6},     // [F12]
        "M8": #{d1: 8.4, d2: 16.0, h: 1.6},     // [F12]
    }
}

/// spec(size: string, kind: string = "hex"): Nut
/// type Nut = #{ d: number, pitch: number, shape: string, s: number, m: number }
///
/// A nut's dimensions by its size and kind, from the tables.
///
/// - `size`: `"M3"`, or a fine thread, `"M8x1"`: M for metric, the nominal diameter, and after the x the pitch, in mm
/// - `kind`: `"hex"` (ISO 4032), `"thin"` (ISO 4035), `"square"` (DIN 562) or `"nyloc"` (ISO 7040)
///
/// The returned map is what `nuts::nut`, `nuts::trap` and `nuts::slot` take, to change before passing it on:
///
/// - `d`, `pitch`: the thread's
/// - `shape`: `"hex"` or `"square"`
/// - `s`: the width across the flats
/// - `m`: the height; a nyloc nut's whole height, with its dome
///
/// A fine thread has the same nut as its coarse size.
///
/// See also: `nuts::nut`, `nuts::trap`, `nuts::slot`, `nuts::iso_4032`, `nuts::iso_4035`, `nuts::din_562`, `nuts::iso_7040`.
///
/// Example: an M3 square nut's dimensions.
/// ```
/// nuts::spec("M3", "square")
/// ```
fn spec(size) {
    _nuts_spec(size, "hex")
}

fn spec(size, kind) {
    _nuts_spec(size, kind)
}

private fn _nuts_spec(size, kind) {
    let t = threads::size(size);
    let name = size.split("x")[0];
    let table = switch kind {
        "hex" => iso_4032(),
        "thin" => iso_4035(),
        "square" => din_562(),
        "nyloc" => iso_7040(),
        _ => throw `nuts::spec: kind must be hex, thin, square or nyloc, got ${kind}`,
    };
    if !(name in table) {
        throw `nuts::spec: no ${kind} nut for ${name}; known: ${table.keys()}`;
    }
    let row = table[name];
    #{
        d: t.d,
        pitch: t.pitch,
        shape: if kind == "square" { "square" } else { "hex" },
        s: row.s,
        m: if kind == "nyloc" { row.h } else { row.m },
    }
}

// A nut's name, looked up as `kind`, or its `Nut` map as it is.
private fn _nuts_of(nut, kind, what) {
    if type_of(nut) == "string" {
        _nuts_spec(nut, kind)
    } else if type_of(nut) == "map" && "s" in nut && "m" in nut {
        nut
    } else {
        throw `${what}: a nut is a size such as "M3" or a map from nuts::spec, got ${nut}`;
    }
}

// A nut's outline, `grow` larger across its flats.
private fn _nuts_outline(n, grow) {
    let shape = _opt(n, "shape", "hex");
    if shape == "hex" {
        hexagon_af(n.s + grow)
    } else if shape == "square" {
        rect(n.s + grow)
    } else {
        throw `nuts: a nut's shape is hex or square, got ${shape}`;
    }
}

// --- Parts ---

/// nut(size: string | Nut, opts: #{ kind?: string, threaded?: bool } = #{}): Shape
/// type Nut = #{ d: number, pitch: number, shape: string, s: number, m: number }
///
/// A metric nut, for reference and assemblies, standing on z = 0.
///
/// - `size`: a size, `"M3"`, as `nuts::spec` takes it, or the dimensions, a map from `nuts::spec`
/// - `opts`:
///   - `kind`: for a size, as `nuts::spec` names them, `"hex"` by default
///   - `threaded`: an ISO thread in its hole, from `threads::internal`, instead of a plain hole `d` across; false by default
///
/// Its flats are parallel to the X axis.
/// A nyloc nut is drawn as a plain nut as tall as its dome.
///
/// Notes:
/// - Field: exact inside, a bound outside near the hole's edges.
/// - Plain, with sharp edges: the standards' chamfers are left out.
///
/// See also: `nuts::spec`, `nuts::trap`, `nuts::slot`, `nuts::washer`.
///
/// Example: an M5 hex nut.
/// ```
/// nuts::nut("M5")
/// ```
fn nut(size) {
    _nuts_nut(size, #{})
}

fn nut(size, opts) {
    _nuts_nut(size, opts)
}

private fn _nuts_nut(size, opts) {
    _opts(opts, ["kind", "threaded"], "nuts::nut");
    let n = _nuts_of(size, _opt(opts, "kind", "hex"), "nuts::nut");
    let body = _nuts_outline(n, 0.0).extrude([0.0, n.m]);
    let hole = if _opt(opts, "threaded", false) {
        threads::internal(threads::basic(n.d, n.pitch), n.m + 1.0, #{clearance: 0}).move([0.0, 0.0, n.m])
    } else {
        cylinder(n.d * 0.5, [-1.0, n.m + 1.0])
    };
    body.difference(hole)
}

/// washer(size: string | Washer): Shape
/// type Washer = #{ d1: number, d2: number, h: number }
///
/// A plain washer, lying on z = 0.
///
/// - `size`: a size, `"M3"`, from `nuts::iso_7089`, or the dimensions, a map as its rows
///
/// Notes:
/// - Field: exact.
///
/// See also: `nuts::iso_7089`, `nuts::nut`.
///
/// Example: an M8 washer.
/// ```
/// nuts::washer("M8")
/// ```
fn washer(size) {
    let w = if type_of(size) == "string" {
        let table = iso_7089();
        if !(size in table) {
            throw `nuts::washer: no washer for ${size}; known: ${table.keys()}`;
        }
        table[size]
    } else if type_of(size) == "map" && "d1" in size && "d2" in size && "h" in size {
        size
    } else {
        throw `nuts::washer: a washer is a size such as "M3" or a map of d1, d2 and h, got ${size}`;
    };
    tube([w.d2 * 0.5, w.d1 * 0.5], [0.0, w.h])
}

// --- Pockets ---

/// trap(size: string | Nut, depth: number, opts: #{ kind?: string, clearance?: number } = #{}): Shape
/// type Nut = #{ d: number, pitch: number, shape: string, s: number, m: number }
///
/// Cutter for a nut dropped in from above: a pocket of its outline from z = -`depth` up without end.
///
/// - `size`: a size, `"M3"`, as `nuts::spec` takes it, or the dimensions, a map from `nuts::spec`
/// - `depth`: the pocket's depth below z = 0, at least the nut's height
/// - `opts`:
///   - `kind`: for a size, as `nuts::spec` names them, `"hex"` by default
///   - `clearance`: added across the flats, 0.4 by default
///
/// The flats are parallel to the X axis, as the nut's.
///
/// The nut follows the standard.
/// The clearance is printing practice, not a standard; the prelude's `nut_trap` has the same default.
///
/// Notes:
/// - Field: exact inside, a bound outside near the bottom's corners.
///
/// See also: `nut_trap`, `nuts::slot`, `screw_hole`.
///
/// Example: a square M4 nut dropped into a block whose top is at z = 5.
/// ```
/// let block = cuboid([14, 14, 10]);
/// let trap = nuts::trap("M4", 3, #{kind: "square"}).move([0, 0, 5]);
/// block.difference(trap)
/// ```
fn trap(size, depth) {
    _nuts_trap(size, depth, #{})
}

fn trap(size, depth, opts) {
    _nuts_trap(size, depth, opts)
}

private fn _nuts_trap(size, depth, opts) {
    _opts(opts, ["kind", "clearance"], "nuts::trap");
    let n = _nuts_of(size, _opt(opts, "kind", "hex"), "nuts::trap");
    let c = _num(_opt(opts, "clearance", 0.4), "nuts::trap: clearance");
    _nut_trap(_nuts_outline(n, c), _num(depth, "nuts::trap: depth"))
}

/// slot(size: string | Nut, length: number, opts: #{ kind?: string, clearance?: number } = #{}): Shape
/// type Nut = #{ d: number, pitch: number, shape: string, s: number, m: number }
///
/// Cutter for a captive nut slid in from the side: a pocket of its outline centred on the origin, with a slot to +X.
///
/// - `size`: a size, `"M3"`, as `nuts::spec` takes it, or the dimensions, a map from `nuts::spec`
/// - `length`: the slot's length from the nut's centre; long enough to reach out of the part
/// - `opts`:
///   - `kind`: for a size, as `nuts::spec` names them, `"hex"` by default
///   - `clearance`: added to the nut's height and across its flats, 0.4 by default
///
/// The pocket is the nut's height plus `clearance` tall, centred on z = 0.
/// The slot is as wide as the pocket across its flats.
///
/// The nut follows the standard.
/// The clearance is printing practice, not a standard; the prelude's `nut_slot` has the same default.
///
/// Notes:
/// - Field: exact outside, a bound inside where the slot meets the pocket.
///
/// See also: `nut_slot`, `nuts::trap`, `screw_hole`.
///
/// Example: a slot for a square M3 nut from the middle of a part out through its side.
/// ```
/// let block = cuboid([16, 12, 8]);
/// block.difference(nuts::slot("M3", 10, #{kind: "square"}))
/// ```
fn slot(size, length) {
    _nuts_slot(size, length, #{})
}

fn slot(size, length, opts) {
    _nuts_slot(size, length, opts)
}

private fn _nuts_slot(size, length, opts) {
    _opts(opts, ["kind", "clearance"], "nuts::slot");
    let n = _nuts_of(size, _opt(opts, "kind", "hex"), "nuts::slot");
    let c = _num(_opt(opts, "clearance", 0.4), "nuts::slot: clearance");
    _nut_slot(_nuts_outline(n, c), n.s + c, n.m + c, _num(length, "nuts::slot: length"))
}
