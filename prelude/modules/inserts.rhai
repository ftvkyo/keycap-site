// SPDX-License-Identifier: MPL-2.0
//
// keycap module: heat-set threaded inserts and their holes.
//
// kind: 3d
//
//     import "keycap/inserts" as inserts;
//
// `insert` and `hole` take dimensions; the makers' tables only supply them,
// by size.  An insert is pressed in from z = 0, its axis along Z, and lies
// below it, as the prelude's `insert_hole` has it.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources, by the keys of keycap's parts research:
// - [I1] https://www.3djake.com/ruthex/threaded-insert-m3-100-pieces ,
//   https://www.3djake.com/ruthex/threaded-inserts-m4-50-pieces ,
//   https://www.3djake.com/ruthex/threaded-inserts-m6-25-pieces (Ruthex's drawing tables)
// - [I2] https://www.3djake.com/cnc-kitchen/threaded-insert-set-xl (CNC Kitchen's sheet)
// - [I3] https://www.cnckitchen.com/blog/are-our-heat-set-insert-datasheets-wrong
// - [I4] https://www.printables.com/model/707184-ruthex-practice-and-measurement-tools

// --- Tables ---

/// ruthex(): #{ [size: string]: Insert }
/// type Insert = #{ length: number, d?: number, hole: number, wall: number }
///
/// Ruthex's standard heat-set inserts, its RX series, by size.
///
/// Each size's row, with the makers' symbols:
///
/// - `length`: the insert's length (L)
/// - `d`: its outer diameter, across the knurl (D1)
/// - `hole`: the hole Ruthex asks for (D3)
/// - `wall`: the least wall around the hole (W)
///
/// Ruthex asks for a hole at least 1 mm deeper than the insert is long.
///
/// Notes:
/// - M2, M2.5, M5 and M8 have no outer diameter.
/// - M5's hole is from one table only, and M8's is 9.6 in one table and 9.7 in another: both unverified.
/// - From a reseller's copies of Ruthex's drawings.
///
/// See also: `inserts::spec`, `inserts::hole`, `inserts::cnc_kitchen`.
///
/// References:
/// - Ruthex's drawing tables, as 3DJake reproduces them, for [M3](https://www.3djake.com/ruthex/threaded-insert-m3-100-pieces), [M4](https://www.3djake.com/ruthex/threaded-inserts-m4-50-pieces) and [M6](https://www.3djake.com/ruthex/threaded-inserts-m6-25-pieces)
/// - [Ruthex's CAD files of its inserts](https://www.ruthex.de/en/pages/cad-daten)
///
/// Example: the hole for Ruthex's M3 insert.
/// ```
/// inserts::ruthex()["M3"].hole
/// ```
fn ruthex() {
    #{
        "M2": #{length: 4.0, hole: 3.2, wall: 1.3},              // [I1]; d unverified
        "M2.5": #{length: 5.7, hole: 4.0, wall: 1.6},            // [I1]; d unverified
        "M3": #{length: 5.7, d: 4.6, hole: 4.0, wall: 1.6},      // [I1]
        "M4": #{length: 8.1, d: 6.3, hole: 5.6, wall: 2.1},      // [I1]
        "M5": #{length: 9.5, hole: 6.4, wall: 2.6},              // [I1]; d and hole unverified
        "M6": #{length: 12.7, d: 8.7, hole: 8.0, wall: 3.3},     // [I1]
        "M8": #{length: 12.7, hole: 9.6, wall: 4.5},             // [I1]; d and hole unverified
    }
}

/// cnc_kitchen(): #{ [size: string]: Insert }
/// type Insert = #{ length: number, d?: number, hole: number, wall: number }
///
/// CNC Kitchen's standard heat-set inserts, its short ones and its M3 Voron insert, by name.
///
/// Each insert's row, with the makers' symbols:
///
/// - `length`: the insert's length (L)
/// - `d`: its outer diameter, across the knurl (D1)
/// - `hole`: the hole CNC Kitchen asks for (D3)
/// - `wall`: the least wall around the hole (W)
///
/// The Voron insert is the short, wide M3 insert the Voron printers' parts are drawn for.
/// CNC Kitchen asks for a hole about 1 mm deeper than the insert is long.
///
/// CNC Kitchen also suggests drawing the M3 hole 4.2 across, since printed holes come out about 0.25 small.
/// That is printing practice, for its printer; the rows keep the datasheet's holes.
///
/// Notes:
/// - An older table of CNC Kitchen's gives holes 0.1 smaller for M4, M5 and M6 (5.6, 6.4, 8.0), as Ruthex's; which is current is unverified.
///
/// See also: `inserts::spec`, `inserts::hole`, `inserts::ruthex`, `metric`.
///
/// References:
/// - CNC Kitchen's insert datasheet, [as 3DJake reproduces it](https://www.3djake.com/cnc-kitchen/threaded-insert-set-xl)
/// - CNC Kitchen, [Tips & Tricks for Heat-Set Inserts](https://www.cnckitchen.com/blog/tips-and-tricks-for-heat-set-inserts)
/// - CNC Kitchen, [Are Our Heat-Set Insert Datasheets Wrong?](https://www.cnckitchen.com/blog/are-our-heat-set-insert-datasheets-wrong)
///
/// Example: the length of CNC Kitchen's short M3 insert.
/// ```
/// inserts::cnc_kitchen()["M3 short"].length
/// ```
fn cnc_kitchen() {
    #{
        "M2": #{length: 3.0, d: 3.6, hole: 3.2, wall: 1.3},           // [I2]
        "M2.5": #{length: 4.0, d: 4.6, hole: 4.0, wall: 1.6},         // [I2]
        "M3": #{length: 5.7, d: 4.6, hole: 4.0, wall: 1.6},           // [I2]
        "M3 short": #{length: 3.0, d: 4.6, hole: 4.0, wall: 1.6},     // [I2]
        "M3 Voron": #{length: 4.0, d: 5.0, hole: 4.4, wall: 1.3},     // [I2]
        "M4": #{length: 8.1, d: 6.3, hole: 5.7, wall: 2.1},           // [I2]
        "M4 short": #{length: 4.0, d: 6.3, hole: 5.7, wall: 2.1},     // [I2]
        "M5": #{length: 9.5, d: 7.1, hole: 6.5, wall: 2.6},           // [I2]
        "M5 short": #{length: 5.8, d: 7.1, hole: 6.5, wall: 2.6},     // [I2]
        "M6": #{length: 12.7, d: 8.7, hole: 8.1, wall: 3.3},          // [I2]
        "M8": #{length: 12.7, d: 10.2, hole: 9.7, wall: 4.5},         // [I2]
    }
}

/// spec(size: string, maker: string = "cnc-kitchen"): Insert
/// type Insert = #{ length: number, d?: number, hole: number, wall: number }
///
/// An insert's dimensions by its size and maker.
///
/// - `size`: `"M3"`, an insert for an ISO metric screw 3 mm across; for CNC Kitchen also `"M3 short"`, `"M3 Voron"`, ...
/// - `maker`: `"cnc-kitchen"`, the prelude's `metric` default, or `"ruthex"`
///
/// The returned map is a row of `inserts::cnc_kitchen` or `inserts::ruthex`, and what `inserts::insert` and `inserts::hole` take.
///
/// See also: `inserts::cnc_kitchen`, `inserts::ruthex`, `inserts::hole`.
///
/// Example: Ruthex's M2 insert, longer than CNC Kitchen's.
/// ```
/// inserts::spec("M2", "ruthex")
/// ```
fn spec(size) {
    _inserts_spec(size, "cnc-kitchen")
}

fn spec(size, maker) {
    _inserts_spec(size, maker)
}

private fn _inserts_spec(size, maker) {
    let table = switch maker {
        "cnc-kitchen" => cnc_kitchen(),
        "ruthex" => ruthex(),
        _ => throw `inserts::spec: maker must be cnc-kitchen or ruthex, got ${maker}`,
    };
    if !(size in table) {
        throw `inserts::spec: ${maker} has no ${size}; known: ${table.keys()}`;
    }
    table[size]
}

// An insert's name, looked up for `maker`, or its `Insert` map as it is.
private fn _inserts_of(insert, maker, what) {
    if type_of(insert) == "string" {
        _inserts_spec(insert, maker)
    } else if type_of(insert) == "map" && "length" in insert && "hole" in insert {
        insert
    } else {
        throw `${what}: an insert is a size such as "M3" or a map from inserts::spec, got ${insert}`;
    }
}

// --- Parts ---

/// insert(size: string | Insert, opts: #{ maker?: string } = #{}): Shape
/// type Insert = #{ length: number, d?: number, hole: number, wall: number }
///
/// A heat-set insert, for reference and assemblies: a plain cylinder from z = -`length` up to z = 0.
///
/// - `size`: a size, `"M3"`, as `inserts::spec` takes it, or the dimensions, a map from `inserts::spec`
/// - `opts`:
///   - `maker`: for a size, as `inserts::spec` names them, `"cnc-kitchen"` by default
///
/// It is drawn as wide as its knurl, or as its hole where the table has no outer diameter.
///
/// Notes:
/// - Field: exact.
///
/// See also: `inserts::hole`, `inserts::spec`.
///
/// Example: CNC Kitchen's M3 insert.
/// ```
/// inserts::insert("M3")
/// ```
fn insert(size) {
    _inserts_insert(size, #{})
}

fn insert(size, opts) {
    _inserts_insert(size, opts)
}

private fn _inserts_insert(size, opts) {
    _opts(opts, ["maker"], "inserts::insert");
    let i = _inserts_of(size, _opt(opts, "maker", "cnc-kitchen"), "inserts::insert");
    cylinder(_opt(i, "d", i.hole) * 0.5, [-i.length, 0.0])
}

// --- Holes ---

/// hole(size: string | Insert, opts: #{ maker?: string, depth?: number, clearance?: number } = #{}): Shape
/// type Insert = #{ length: number, d?: number, hole: number, wall: number }
///
/// Cutter for a heat-set insert: a pocket of the hole its maker asks for, from z = -`depth` up without end.
///
/// - `size`: a size, `"M3"`, as `inserts::spec` takes it, or the dimensions, a map from `inserts::spec`
/// - `opts`:
///   - `maker`: for a size, as `inserts::spec` names them, `"cnc-kitchen"` by default
///   - `depth`: the pocket's depth below z = 0; by default 1 more than the insert is long, as both makers ask, since melting it in pushes plastic down
///   - `clearance`: added to the hole's diameter, 0 by default
///
/// The hole is the datasheet's.
/// The clearance is printing practice, not a datasheet's: printed holes come out small, about 0.25 on CNC Kitchen's printer, which draws its M3 hole 0.2 larger.
/// A test print with a few holes tells what yours needs.
/// Leave at least the insert's `wall` around the hole.
///
/// Notes:
/// - Field: exact.
///
/// See also: `insert_hole`, the same for CNC Kitchen's inserts by size; `inserts::insert`, `inserts::spec`.
///
/// References:
/// - CNC Kitchen, [Tips & Tricks for Heat-Set Inserts](https://www.cnckitchen.com/blog/tips-and-tricks-for-heat-set-inserts)
/// - CNC Kitchen, [Are Our Heat-Set Insert Datasheets Wrong?](https://www.cnckitchen.com/blog/are-our-heat-set-insert-datasheets-wrong)
/// - [Ruthex's practice and measurement tools, Printables](https://www.printables.com/model/707184-ruthex-practice-and-measurement-tools), for the hole 1 mm deeper than the insert
///
/// Example: Ruthex's M3 insert's hole in a part whose top is at z = 10.
/// ```
/// let block = cuboid([12, 12, 20]);
/// let hole = inserts::hole("M3", #{maker: "ruthex"}).move([0, 0, 10]);
/// block.difference(hole)
/// ```
fn hole(size) {
    _inserts_hole(size, #{})
}

fn hole(size, opts) {
    _inserts_hole(size, opts)
}

private fn _inserts_hole(size, opts) {
    _opts(opts, ["maker", "depth", "clearance"], "inserts::hole");
    let i = _inserts_of(size, _opt(opts, "maker", "cnc-kitchen"), "inserts::hole");
    let depth = _num(_opt(opts, "depth", i.length + 1.0), "inserts::hole: depth");
    let c = _num(_opt(opts, "clearance", 0.0), "inserts::hole: clearance");
    _bore((i.hole + c) * 0.5, -depth)
}
