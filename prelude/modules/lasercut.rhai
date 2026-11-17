// SPDX-License-Identifier: MPL-2.0
//
// keycap module: shapes for laser-cut designs.
//
// kind: 2d
//
//     import "keycap/lasercut" as lc;
//
// Joints, living hinges, a box and a sheet, all 2D, in millimetres.  The
// joints take dimensions, the material's thickness `t` always among them;
// a standard part only supplies them, by size.  A joint lies along an edge
// on the X axis, centred on the origin, with the part it is cut into
// below, at y < 0: move and turn it onto the part's edge.  Its cutters
// reach past the edge, so that the cut is open there.
//
// `fit` is the clearance a joint is drawn with: positive slides, 0 is as
// drawn, negative presses.  It is the clearance of the parts as they are
// cut once the 2D export's kerf is the laser's: the export grows the
// shapes to cut by half the kerf, so they come out as drawn.  Exported
// with no kerf, a joint comes out looser by twice the kerf.
//
// keycap knows shapes, not materials.  Never laser-cut PVC or vinyl, and
// don't cut polycarbonate or unidentified plastics: ask your makerspace,
// or read the material's safety data sheet.  Cut acrylic only if it is
// cast acrylic (PMMA), extract the fumes of every job, and don't leave a
// laser running unattended.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources:
// - [B1] https://github.com/florianfesti/boxes/blob/master/boxes/edges.py ,
//   boxes.py's FingerJointSettings: fingers and spaces 2 thicknesses wide,
//   no play
// - [B2] https://github.com/florianfesti/boxes/blob/master/boxes/__init__.py ,
//   boxes.py's burn, half the kerf, 0.1 mm by default
//
// Living hinges, by the keys of keycap's hinge research:
// - [H1] http://marksabino.com/defproc/blog/2011/laser-cut-lattice-living-hinges/
// - [H2] http://marksabino.com/defproc/blog/2011/lattice-hinge-test-results/
// - [H3] http://marksabino.com/defproc/blog/2012/minimum-bend-radius/
// - [H4] https://www.defproc.co.uk/analysis/lattice-hinge-design-choosing-torsional-stress/
// - [H5] https://www.proceedings.com/content/069/069179-0481open.pdf (Néron, WCTE 2023)
// - [H6] https://www.graphics.rwth-aachen.de/media/papers/359/Freeform_Shape_Fabrication_by_Kerfing_Stiff_Materials.pdf
// - [H7] https://engineeringlibrary.org/reference/beam-torsion-air-force-stress-manual
// - [H8] https://github.com/florianfesti/boxes/blob/master/boxes/edges.py ,
//   boxes.py's FlexSettings: rows half a thickness apart, bridges a
//   thickness long, slots nine (from its code)
// - [H12] https://www.troteclaser.com/en-za/helpcenter/materials/application-techniques/bending-technique
// - [H15] https://flatcad.com/living-hinge-generator
// - [H19] https://www.metsagroup.com/globalassets/metsa-wood/dop-documents/dop_metsa_wood_birch_plywood_muf_2019-12-2_en.pdf
// - [H22] https://www.plexiglas.de/files/plexiglas-content/pdf/technische-informationen/211-1-PLEXIGLAS-GS-XT-EN.pdf

import "keycap/nuts" as nuts;
import "keycap/screws" as screws;

// --- Helpers ---

// The exact rectangle from `x0` to `x1` and `y0` to `y1`.
private fn _lasercut_box(x0, x1, y0, y1) {
    rect([x1 - x0, y1 - y0]).move([(x0 + x1) * 0.5, (y0 + y1) * 0.5])
}

// Places along an edge of `length` for `n` parts evenly spaced: their
// centres.
private fn _lasercut_spread(length, n) {
    let c = [];
    for i in 0..n {
        c.push(length * ((i.to_float() + 0.5) / n.to_float() - 0.5));
    }
    c
}

// The odd count of segments nearest to `length` cut into pieces `width`
// long, at least 3.
private fn _lasercut_odd(length, width) {
    let q = length / width;
    max(3, (q / 2.0).floor().to_int() * 2 + 1)
}

// --- Finger joints ---

/// finger_joint(length: number, t: number, opts: #{ count?: number, width?: number, fit?: number, mate?: bool } = #{}): Shape
///
/// Cutter for one part of a finger joint: the notches along its edge where the other part's fingers go.
///
/// - `length`: the edge's length
/// - `t`: the material's thickness, the notches' depth
/// - `opts`:
///   - `count`: how many fingers both parts have together, odd and at least 3; the nearest odd count to `length / width` unless given
///   - `width`: the fingers' width as near as `count` allows, `2 * t` by default, as Boxes.py draws them
///   - `fit`: the clearance between a finger and its notch, 0 by default
///   - `mate`: `true` for the other part
///
/// The edge is cut into `count` segments of one width.
/// The part keeps the segments at the ends and every other one between; its mate keeps the rest.
/// Both parts' notches are `fit / 2` wider than their segments, so each finger is `fit` narrower than the notch it goes in.
/// The notches at the ends of the edge reach `t` past them, so that the mate's corners are cut away.
///
/// `fit` is the clearance as cut when the 2D export's kerf is the laser's; exported with no kerf, the joint comes out looser by twice the kerf.
/// The right fit is cutting practice, not a standard: kerfs differ by machine and material, so cut a test joint first.
///
/// Notes:
/// - Field: exact.
/// - About 10 operations a notch.
///
/// See also: `lc::box_panels`, `lc::tabs`, `lc::cross_lap`.
///
/// References:
/// - [Box joint, Wikipedia](https://en.wikipedia.org/wiki/Box_joint)
/// - [Boxes.py's edges](https://github.com/florianfesti/boxes/blob/master/boxes/edges.py), whose `FingerJointSettings` draw fingers and spaces 2 thicknesses wide
///
/// Example: two plates joined at a right angle, laid flat, one above the other.
/// ```
/// let panel = rect([60, 30]);
/// let joint = lc::finger_joint(60, 3);
/// let mate = lc::finger_joint(60, 3, #{mate: true});
/// union(
///     panel.difference(joint.move([0, 15])),
///     panel.difference(mate.move([0, 15])).move([0, -35])
/// )
/// ```
fn finger_joint(length, t) {
    _lasercut_finger_joint(length, t, #{})
}

fn finger_joint(length, t, opts) {
    _lasercut_finger_joint(length, t, opts)
}

private fn _lasercut_finger_joint(length, t, opts) {
    _opts(opts, ["count", "width", "fit", "mate"], "lc::finger_joint");
    let length = _num(length, "lc::finger_joint: length");
    let t = _num(t, "lc::finger_joint: t");
    let n = if "count" in opts {
        _num(opts.count, "lc::finger_joint: count").to_int()
    } else {
        _lasercut_odd(length, _num(_opt(opts, "width", 2.0 * t), "lc::finger_joint: width"))
    };
    if n < 3 || n % 2 == 0 {
        throw `lc::finger_joint: count must be odd, so that both ends are alike, and at least 3, got ${n}`;
    }
    let fit = _num(_opt(opts, "fit", 0.0), "lc::finger_joint: fit");
    let w = length / n.to_float();
    if abs(fit) >= w {
        throw `lc::finger_joint: fit ${fit} is as wide as a finger, ${w}`;
    }
    // The part keeps the even segments, its mate the odd ones.
    let first = if _opt(opts, "mate", false) { 0 } else { 1 };
    let notches = [];
    for i in range(first, n, 2) {
        let x0 = if i == 0 { -length * 0.5 - t } else { w * i.to_float() - length * 0.5 - fit * 0.25 };
        let x1 = if i == n - 1 { length * 0.5 + t } else { w * (i + 1).to_float() - length * 0.5 + fit * 0.25 };
        notches.push(_lasercut_box(x0, x1, -t, t));
    }
    if notches.len() == 1 { notches[0] } else { union(notches) }
}

// --- Tabs and slots ---

/// tabs(length: number, t: number, opts: #{ count?: number, width?: number, depth?: number } = #{}): Shape
///
/// Tabs along a part's edge, to go through slots in the part it meets.
///
/// - `length`: the edge's length
/// - `t`: the material's thickness
/// - `opts`:
///   - `count`: how many tabs, 2 by default
///   - `width`: each tab's width, `2 * t` by default
///   - `depth`: how far the tabs stand out of the edge, `t` by default, flush with the far face of a part as thick
///
/// The tabs are spread evenly, each in the middle of its share of the edge.
/// They reach `t` into the part below the edge, so that the union has no seam there.
/// `lc::tab_slots` cuts the slots they go through, with the clearance.
///
/// Notes:
/// - Field: exact.
///
/// See also: `lc::tab_slots`, `lc::finger_joint`.
///
/// Example: a plate with two tabs, and the plate they go through, its slots 0.1 wider.
/// ```
/// let tabbed = rect([60, 30]).union(lc::tabs(60, 3).move([0, 15]));
/// let slotted = rect([70, 30])
///     .difference(lc::tab_slots(60, 3, #{fit: 0.1}));
/// union(tabbed, slotted.move([0, 40]))
/// ```
fn tabs(length, t) {
    _lasercut_tabs(length, t, #{})
}

fn tabs(length, t, opts) {
    _lasercut_tabs(length, t, opts)
}

private fn _lasercut_tabs(length, t, opts) {
    _opts(opts, ["count", "width", "depth"], "lc::tabs");
    let length = _num(length, "lc::tabs: length");
    let t = _num(t, "lc::tabs: t");
    let n = _num(_opt(opts, "count", 2), "lc::tabs: count").to_int();
    let w = _num(_opt(opts, "width", 2.0 * t), "lc::tabs: width");
    let depth = _num(_opt(opts, "depth", t), "lc::tabs: depth");
    if n < 1 || w * n.to_float() > length {
        throw `lc::tabs: ${n} tabs ${w} wide do not fit on ${length}`;
    }
    let tabs = [];
    for c in _lasercut_spread(length, n) {
        tabs.push(_lasercut_box(c - w * 0.5, c + w * 0.5, -t, depth));
    }
    if tabs.len() == 1 { tabs[0] } else { union(tabs) }
}

/// tab_slots(length: number, t: number, opts: #{ count?: number, width?: number, fit?: number } = #{}): Shape
///
/// Cutter for the slots that `lc::tabs` of the same `length`, `t`, `count` and `width` go through.
///
/// - `length`: the tabbed edge's length
/// - `t`: the tabbed part's thickness
/// - `opts`:
///   - `count`, `width`: as the tabs', 2 and `2 * t` by default
///   - `fit`: the clearance between a tab and its slot, along and across, 0 by default
///
/// The slots lie on the X axis, centred on y = 0: put them where the tabbed part's middle crosses the slotted part.
/// Each is `width + fit` long and `t + fit` wide.
///
/// `fit` is the clearance as cut when the 2D export's kerf is the laser's; exported with no kerf, the slots come out wider by the kerf.
/// The right fit is cutting practice, not a standard: cut a test slot first.
///
/// Notes:
/// - Field: exact.
///
/// See also: `lc::tabs`, `lc::t_slot`.
///
/// Example: a plate with the slots for three tabs.
/// ```
/// rect([80, 20])
///     .difference(lc::tab_slots(70, 3, #{count: 3}))
/// ```
fn tab_slots(length, t) {
    _lasercut_tab_slots(length, t, #{})
}

fn tab_slots(length, t, opts) {
    _lasercut_tab_slots(length, t, opts)
}

private fn _lasercut_tab_slots(length, t, opts) {
    _opts(opts, ["count", "width", "fit"], "lc::tab_slots");
    let length = _num(length, "lc::tab_slots: length");
    let t = _num(t, "lc::tab_slots: t");
    let n = _num(_opt(opts, "count", 2), "lc::tab_slots: count").to_int();
    let w = _num(_opt(opts, "width", 2.0 * t), "lc::tab_slots: width");
    let fit = _num(_opt(opts, "fit", 0.0), "lc::tab_slots: fit");
    if n < 1 || w * n.to_float() > length {
        throw `lc::tab_slots: ${n} tabs ${w} wide do not fit on ${length}`;
    }
    let half = [(w + fit) * 0.5, (t + fit) * 0.5];
    let slots = [];
    for c in _lasercut_spread(length, n) {
        slots.push(_lasercut_box(c - half[0], c + half[0], -half[1], half[1]));
    }
    if slots.len() == 1 { slots[0] } else { union(slots) }
}

// --- Cross laps ---

/// cross_lap(depth: number, t: number, opts: #{ fit?: number } = #{}): Shape
///
/// Cutter for a cross-lap (halving) joint: a slot into a part's edge, for another part slotted into it the other way.
///
/// - `depth`: how far the slot goes into the part; the two parts' slots together are as deep as the parts are where they cross
/// - `t`: the other part's thickness
/// - `opts`:
///   - `fit`: the clearance across the slot, 0 by default
///
/// The slot is `t + fit` wide, centred on x = 0, from y = -`depth` up past the edge.
///
/// `fit` is the clearance as cut when the 2D export's kerf is the laser's.
/// The right fit is cutting practice, not a standard: cut a test slot first.
///
/// Notes:
/// - Field: exact.
///
/// See also: `lc::finger_joint`, `lc::tab_slots`.
///
/// References:
/// - [Halved joint, Wikipedia](https://en.wikipedia.org/wiki/Halved_joint)
///
/// Example: two parts 20 tall that cross, each slotted halfway.
/// ```
/// let panel = rect([60, 20]);
/// let lap = lc::cross_lap(10, 3);
/// union(
///     panel.difference(lap.move([0, 10])),
///     panel.difference(lap.rotate_z(180).move([0, -10])).move([0, -25])
/// )
/// ```
fn cross_lap(depth, t) {
    _lasercut_cross_lap(depth, t, #{})
}

fn cross_lap(depth, t, opts) {
    _lasercut_cross_lap(depth, t, opts)
}

private fn _lasercut_cross_lap(depth, t, opts) {
    _opts(opts, ["fit"], "lc::cross_lap");
    let depth = _num(depth, "lc::cross_lap: depth");
    let t = _num(t, "lc::cross_lap: t");
    let half = (t + _num(_opt(opts, "fit", 0.0), "lc::cross_lap: fit")) * 0.5;
    _lasercut_box(-half, half, -depth, t)
}

// --- T-slots ---

/// t_slot_spec(size: string, opts: #{ kind?: string, hole?: string } = #{}): TSlot
/// type TSlot = #{ d: number, s: number, m: number }
///
/// A T-slot's dimensions for a metric screw and nut, from the tables of `keycap/screws` and `keycap/nuts`.
///
/// - `size`: `"M3"`, an ISO metric screw 3 mm across
/// - `opts`:
///   - `kind`: the nut, as `nuts::spec` names them, `"hex"` by default; `"square"` is common in T-slots
///   - `hole`: the screw's clearance hole, as `screws::iso_273` names its series, `"medium"` by default
///
/// The returned map is what `lc::t_slot` takes, to change before passing it on:
///
/// - `d`: the screw's slot's width, and its hole's diameter in the other part
/// - `s`: the nut's width across its flats
/// - `m`: the nut's height
///
/// The values follow the standards and have no clearance; `lc::t_slot` adds its `fit`.
///
/// See also: `lc::t_slot`, `nuts::spec`, `screws::iso_273`.
///
/// References:
/// - [ISO 273, Clearance holes for bolts and screws](https://www.iso.org/standard/4183.html)
/// - [ISO 4032, Hexagon regular nuts](https://www.iso.org/standard/75016.html)
/// - [DIN 562, Square thin nuts](https://www.dinmedia.de/en/standard/din-562/178392223), a German standard (DIN: Deutsches Institut für Normung)
///
/// Example: an M3 T-slot's dimensions, for a square nut.
/// ```
/// lc::t_slot_spec("M3", #{kind: "square"})
/// ```
fn t_slot_spec(size) {
    _lasercut_t_slot_spec(size, #{})
}

fn t_slot_spec(size, opts) {
    _lasercut_t_slot_spec(size, opts)
}

private fn _lasercut_t_slot_spec(size, opts) {
    _opts(opts, ["kind", "hole"], "lc::t_slot_spec");
    let nut = nuts::spec(size, _opt(opts, "kind", "hex"));
    let name = size.split("x")[0];
    let holes = screws::iso_273();
    if !(name in holes) {
        throw `lc::t_slot_spec: no clearance hole for ${name}; known: ${holes.keys()}`;
    }
    let series = _opt(opts, "hole", "medium");
    if !(series in holes[name]) {
        throw `lc::t_slot_spec: hole must be fine, medium or coarse, got ${series}`;
    }
    #{d: holes[name][series], s: nut.s, m: nut.m}
}

/// t_slot(size: string | TSlot, length: number, t: number, opts: #{ at?: number, fit?: number, kind?: string, hole?: string } = #{}): Shape
/// type TSlot = #{ d: number, s: number, m: number }
///
/// Cutter for a T-slot: a slot into a part's edge for a screw through the part it meets, and a pocket across it for the nut.
///
/// - `size`: a size, `"M3"`, as `lc::t_slot_spec` takes it, or the dimensions, a map from `lc::t_slot_spec`
/// - `length`: the screw's length, under its head
/// - `t`: the thickness of the part the screw goes through first
/// - `opts`:
///   - `at`: the nut's middle from the edge; unless given, the screw's tip is half a nut past the nut
///   - `fit`: the clearance round the nut, and past the screw's tip, 0 by default
///   - `kind`, `hole`: for a size, as `lc::t_slot_spec` takes them
///
/// The screw's slot is `d` wide and `length - t + fit` deep.
/// The nut's pocket is `s + fit` across and `m + fit` along the screw.
/// The nut stands in it on edge, its flats against the pocket's sides, so that it cannot turn.
/// In the other part, a hole `d` across takes the screw: `circle(lc::t_slot_spec("M3").d / 2)`.
///
/// `fit` is the clearance as cut when the 2D export's kerf is the laser's.
/// The right fit is cutting practice, not a standard: cut a test slot first.
///
/// Notes:
/// - Field: exact outside, a bound inside where the pocket crosses the slot.
///
/// See also: `lc::t_slot_spec`, `lc::tab_slots`.
///
/// Example: an M3 T-slot for a 12 mm screw through 3 mm material, and the hole in the other part.
/// ```
/// let bar = rect([40, 20]);
/// let slot = lc::t_slot("M3", 12, 3).move([0, 10]);
/// let tab = rect([40, 6]).difference(circle(1.7)).move([0, 16]);
/// union(bar.difference(slot), tab)
/// ```
fn t_slot(size, length, t) {
    _lasercut_t_slot(size, length, t, #{})
}

fn t_slot(size, length, t, opts) {
    _lasercut_t_slot(size, length, t, opts)
}

private fn _lasercut_t_slot(size, length, t, opts) {
    _opts(opts, ["at", "fit", "kind", "hole"], "lc::t_slot");
    let s = if type_of(size) == "string" {
        _lasercut_t_slot_spec(size, #{kind: _opt(opts, "kind", "hex"), hole: _opt(opts, "hole", "medium")})
    } else if type_of(size) == "map" && "d" in size && "s" in size && "m" in size {
        if "kind" in opts || "hole" in opts {
            throw "lc::t_slot: kind and hole are for a size; change the map instead";
        }
        size
    } else {
        throw `lc::t_slot: a T-slot is a size such as "M3" or a map from lc::t_slot_spec, got ${size}`;
    };
    let fit = _num(_opt(opts, "fit", 0.0), "lc::t_slot: fit");
    let depth = _num(length, "lc::t_slot: length") - _num(t, "lc::t_slot: t") + fit;
    let at = _num(_opt(opts, "at", depth - fit - s.m), "lc::t_slot: at");
    let pocket = [(s.s + fit) * 0.5, (s.m + fit) * 0.5];
    if at - pocket[1] <= 0.0 || at + pocket[1] > depth {
        throw `lc::t_slot: the nut's pocket, ${s.m + fit} long at ${at}, must lie within the screw's ${depth}`;
    }
    union(
        _lasercut_box(-s.d * 0.5, s.d * 0.5, -depth, s.d),
        _lasercut_box(-pocket[0], pocket[0], -at - pocket[1], -at + pocket[1]),
    )
}

// --- Living hinges ---

/// living_hinge(size: Vec2, t: number, opts: #{ length?: number, width?: number, pitch?: number, bridge?: number, pattern?: string } = #{}): Shape
///
/// Cutter for a living hinge: rows of slots across a sheet, so that it bends about the X axis.
///
/// - `size`: `[width, height]` of the area the slots fill, centred on the origin; the bend runs along its height
/// - `t`: the material's thickness
/// - `opts`:
///   - `length`: each slot's length, along X, `9 * t` by default
///   - `width`: each slot's width, `t / 6` by default, 0.5 for 3 mm
///   - `pitch`: the rows' spacing, centre to centre, `0.5 * t` by default
///   - `bridge`: the material between two slots in a row, `t` by default
///   - `pattern`: `"straight"`, the default, or `"snake"`
///
/// The rows are as many as fit in the area's height, centred on it.
///
/// In a `"straight"` hinge, every other row is shifted along X by half a slot plus half a bridge.
/// Where a slot of one row overlaps those of the next, the strip between them twists as the sheet bends.
/// The area's sides cut the slots that reach them, leaving them open there.
/// An area `n` slots and `n + 1` bridges wide, for any `n`, has whole bridges at the sides of every other row.
///
/// In a `"snake"` hinge, each row is one slot from a side of the area to `bridge` short of the other, from alternate sides, so the strips fold back and forth.
/// `length` is unused.
///
/// Each slot is cut along its outline.
/// With the 2D export's kerf set to the laser's, a slot comes out as wide as drawn, and a slot no wider than the kerf is not cut at all.
///
/// The default length, pitch and bridge are Boxes.py's, in thicknesses; with 3 mm plywood they are close to other published generators'.
/// They are a starting point, not tested values: a hinge's bend depends on the material more than a fit does, so cut a test strip first.
/// `lc::hinge_for` sizes a straight hinge for a bend.
///
/// Notes:
/// - Field: exact inside the area, a bound outside it.
/// - Constant cost, whatever the number of slots.
///
/// See also: `lc::hinge_for`, `lc::hinge_materials`.
///
/// References:
/// - [Living hinge, Wikipedia](https://en.wikipedia.org/wiki/Living_hinge)
/// - [Boxes.py's edges](https://github.com/florianfesti/boxes/blob/master/boxes/edges.py), whose `FlexSettings` set the defaults
/// - Fenner, [Laser-cut Lattice Living Hinges](http://marksabino.com/defproc/blog/2011/laser-cut-lattice-living-hinges/), on how the strips twist
/// - [FlatCAD's living hinge generator](https://flatcad.com/living-hinge-generator), with spacings for plywood, MDF (medium-density fibreboard) and card
/// - Trotec, [Cutting technique for bending applications](https://www.troteclaser.com/en-za/helpcenter/materials/application-techniques/bending-technique), on materials and patterns
///
/// Example: a 3 mm plate with a hinge across its middle.
/// ```
/// rect([120, 60])
///     .difference(lc::living_hinge([120, 30], 3))
/// ```
fn living_hinge(size, t) {
    _lasercut_living_hinge(size, t, #{})
}

fn living_hinge(size, t, opts) {
    _lasercut_living_hinge(size, t, opts)
}

private fn _lasercut_living_hinge(size, t, opts) {
    _opts(opts, ["length", "width", "pitch", "bridge", "pattern"], "lc::living_hinge");
    let s = _vec2(size, "lc::living_hinge: size");
    let t = _num(t, "lc::living_hinge: t");
    let length = _num(_opt(opts, "length", 9.0 * t), "lc::living_hinge: length");
    let width = _num(_opt(opts, "width", t / 6.0), "lc::living_hinge: width");
    let pitch = _num(_opt(opts, "pitch", 0.5 * t), "lc::living_hinge: pitch");
    let bridge = _num(_opt(opts, "bridge", t), "lc::living_hinge: bridge");
    let pattern = _opt(opts, "pattern", "straight");
    if width >= pitch {
        throw `lc::living_hinge: slots ${width} wide leave nothing between rows ${pitch} apart`;
    }
    let rows = ((s[1] - width) / pitch).floor().to_int() + 1;
    if rows < 1 {
        throw `lc::living_hinge: a slot ${width} wide does not fit in an area ${s[1]} high`;
    }
    // Rows from the bottom up, `first` the lowest one's height; the even
    // ones and the odd ones are each a repetition of their own.
    let first = -(rows - 1).to_float() * pitch * 0.5;
    let counts = [(rows + 1) / 2, rows / 2];
    let cuts = if pattern == "straight" {
        let step = length + bridge;
        // An odd count of slots, the middle one on x = 0, reaching past
        // the area's sides; the area cuts them off.
        let across = (s[0] / step * 0.5).floor().to_int() * 2 + 5;
        let slot = rect([length, width]);
        let slots = repeat_grid(slot, [step, 2.0 * pitch], [across, counts[0]], #{center: true})
            .move([0.0, first + (counts[0] - 1).to_float() * pitch]);
        if counts[1] > 0 {
            let odd = repeat_grid(slot, [step, 2.0 * pitch], [across, counts[1]], #{center: true});
            slots = union(slots, odd.move([step * 0.5, first + counts[1].to_float() * pitch]));
        }
        slots
    } else if pattern == "snake" {
        // Each slot reaches a slot's width past its side of the area.
        let w = s[0] * 0.5;
        let slot = _lasercut_box(-w - width, w - bridge, -width * 0.5, width * 0.5);
        let slots = repeat_grid(slot, [0.0, 2.0 * pitch], [1, counts[0]], #{center: true})
            .move([0.0, first + (counts[0] - 1).to_float() * pitch]);
        if counts[1] > 0 {
            let odd = repeat_grid(slot.rotate_z(180), [0.0, 2.0 * pitch], [1, counts[1]], #{center: true});
            slots = union(slots, odd.move([0.0, first + counts[1].to_float() * pitch]));
        }
        slots
    } else {
        throw `lc::living_hinge: pattern must be straight or snake, got ${pattern}`;
    };
    cuts.intersection(rect(s))
}

/// hinge_materials(): #{ [material: string]: #{ pitch: number, bridge: number, strain: number } }
///
/// Straight living hinges' defaults by material, for `lc::hinge_for`: plywood, MDF (medium-density fibreboard) and acrylic.
///
/// Each material's row:
///
/// - `pitch`: the rows' spacing, in thicknesses
/// - `bridge`: the material between two slots in a row, in thicknesses
/// - `strain`: the most shear strain a twisting strip may take, for a bend held for good
///
/// The strains are estimates from the materials' data, not tests of hinges.
/// Birch plywood fails in shear near 1.5%, less Néron's safety factors for a lasting load.
/// MDF is designed at 1%, as Speetzen and Kobbelt do.
/// Acrylic is held to its maker's safe stress.
/// For a bend made once in assembly, plywood takes about 1%, MDF 1.1% and acrylic 0.5%.
///
/// The pitches are for 3 mm sheet.
///
/// Notes:
/// - MDF's and acrylic's pitches are from guides that show no tests: unverified.
/// - The plywood data is for structural birch plywood 4 mm and thicker; 3 mm hobby plywood's is unverified.
///
/// See also: `lc::hinge_for`, `lc::living_hinge`.
///
/// References:
/// - [Boxes.py's edges](https://github.com/florianfesti/boxes/blob/master/boxes/edges.py), for plywood's pitch and bridge
/// - [FlatCAD's living hinge generator](https://flatcad.com/living-hinge-generator), for MDF's pitch
/// - Trotec, [Cutting technique for bending applications](https://www.troteclaser.com/en-za/helpcenter/materials/application-techniques/bending-technique), for acrylic's pitch
/// - Metsä Wood, [Declaration of performance, birch plywood](https://www.metsagroup.com/globalassets/metsa-wood/dop-documents/dop_metsa_wood_birch_plywood_muf_2019-12-2_en.pdf), for plywood's shear strength
/// - Néron, [Bending of CLT by the lattice hinge method](https://www.proceedings.com/content/069/069179-0481open.pdf), WCTE 2023, for the safety factors (CLT: cross-laminated timber)
/// - Speetzen and Kobbelt, [Freeform Shape Fabrication by Kerfing Stiff Materials](https://www.graphics.rwth-aachen.de/media/papers/359/Freeform_Shape_Fabrication_by_Kerfing_Stiff_Materials.pdf), Computer Graphics Forum 2024, for MDF
/// - Röhm, [PLEXIGLAS GS/XT technical information](https://www.plexiglas.de/files/plexiglas-content/pdf/technische-informationen/211-1-PLEXIGLAS-GS-XT-EN.pdf), for acrylic's safe stress
/// - Fenner, [Lattice Hinge Design: Choosing Torsional Stress](https://www.defproc.co.uk/analysis/lattice-hinge-design-choosing-torsional-stress/), for acrylic hinges
///
/// Example: plywood's defaults.
/// ```
/// lc::hinge_materials()["plywood"]
/// ```
fn hinge_materials() {
    #{
        "plywood": #{pitch: 0.5, bridge: 1.0, strain: 0.007},     // [H8]; [H19], [H5]
        "mdf": #{pitch: 0.7, bridge: 1.0, strain: 0.010},         // 1.8 to 2.5 for 3 mm in [H15], unverified; [H6]
        "acrylic": #{pitch: 0.45, bridge: 1.0, strain: 0.003},    // 1 to 1.5 in [H12]; [H22], [H4]
    }
}

/// hinge_for(t: number, span: number, angle: number, radius: number, opts: #{ material?: string, strain?: number, pitch?: number, bridge?: number, width?: number } = #{}): Hinge
/// type Hinge = #{ size: Vec2, opts: #{ length: number, width: number, pitch: number, bridge: number }, rows: number, link: number, strain: number }
///
/// A straight living hinge sized for a bend: as many rows as the bend needs, and slots long enough that the strips between them twist within the material's strain.
///
/// - `t`: the material's thickness
/// - `span`: the hinge's width, along its slots: the part's width where it bends
/// - `angle`: the bend, in degrees
/// - `radius`: the bend's inner radius
/// - `opts`:
///   - `material`: a row of `lc::hinge_materials`, `"plywood"` by default
///   - `strain`, `pitch`, `bridge`: the material's, unless given; `pitch` and `bridge` in millimetres
///   - `width`: the slots' width, 0.5 by default
///
/// The returned map is what `lc::living_hinge` takes, `lc::living_hinge(h.size, t, h.opts)`, and what came out:
///
/// - `size`: the hinge's area, `span` by the length of the bend's arc through the middle of the sheet
/// - `opts`: the slots' `length` and `width`, the rows' `pitch` and the `bridge`
/// - `rows`: how many rows of slots there are
/// - `link`: the length of each twisting strip, from a bridge of one row to the nearest of the next
/// - `strain`: the strips' shear strain at the full bend
///
/// Each row turns by an equal share of the angle.
/// Its strips twist by that, which strains them less the longer they are.
/// The strain is a rectangular bar's in torsion, as Fenner sizes acrylic hinges; the strip's width is the pitch less the slot's.
/// The slots are lengthened so that a whole number of slots and bridges fits `span`.
///
/// It throws when a row's turn would close its slots, or when the strips need more than `span`.
///
/// Notes:
/// - An estimate from published models and data, not from tests of hinges: cut a test strip first.
/// - Strips longer than `4 * t` let the hinge's edges splay as it bends; `link` says how long they came out.
///
/// See also: `lc::living_hinge`, `lc::hinge_materials`.
///
/// References:
/// - [Torsion of a rectangular bar](https://engineeringlibrary.org/reference/beam-torsion-air-force-stress-manual), from the Air Force Stress Manual, for the strain
/// - Fenner, [Laser-cut Lattice Living Hinges](http://marksabino.com/defproc/blog/2011/laser-cut-lattice-living-hinges/), the model
/// - Fenner, [Lattice Hinge Test Results](http://marksabino.com/defproc/blog/2011/lattice-hinge-test-results/), for the `4 * t` limit
/// - Fenner, [Lattice Hinge Design: Minimum Bend Radius](http://marksabino.com/defproc/blog/2012/minimum-bend-radius/), for when the slots close
/// - Fenner, [Lattice Hinge Design: Choosing Torsional Stress](https://www.defproc.co.uk/analysis/lattice-hinge-design-choosing-torsional-stress/)
/// - Néron, [Bending of CLT by the lattice hinge method](https://www.proceedings.com/content/069/069179-0481open.pdf), WCTE 2023, the same model for cross-laminated timber (CLT)
/// - Speetzen and Kobbelt, [Freeform Shape Fabrication by Kerfing Stiff Materials](https://www.graphics.rwth-aachen.de/media/papers/359/Freeform_Shape_Fabrication_by_Kerfing_Stiff_Materials.pdf), Computer Graphics Forum 2024
///
/// Example: a hinge in 3 mm plywood 60 wide, to bend 90 degrees round a 20 mm radius.
/// ```
/// lc::hinge_for(3, 60, 90, 20)
/// ```
fn hinge_for(t, span, angle, radius) {
    _lasercut_hinge_for(t, span, angle, radius, #{})
}

fn hinge_for(t, span, angle, radius, opts) {
    _lasercut_hinge_for(t, span, angle, radius, opts)
}

private fn _lasercut_hinge_for(t, span, angle, radius, opts) {
    _opts(opts, ["material", "strain", "pitch", "bridge", "width"], "lc::hinge_for");
    let t = _num(t, "lc::hinge_for: t");
    let span = _num(span, "lc::hinge_for: span");
    let bend = _num(angle, "lc::hinge_for: angle") * PI / 180.0;
    let r = _num(radius, "lc::hinge_for: radius") + t * 0.5;
    let materials = hinge_materials();
    let name = _opt(opts, "material", "plywood");
    if !(name in materials) {
        throw `lc::hinge_for: no data for ${name}; known: ${materials.keys()}`;
    }
    let m = materials[name];
    let strain = _num(_opt(opts, "strain", m.strain), "lc::hinge_for: strain");
    let bridge = _num(_opt(opts, "bridge", m.bridge * t), "lc::hinge_for: bridge");
    let width = _num(_opt(opts, "width", 0.5), "lc::hinge_for: width");
    // The rows fill the arc through the middle of the sheet, each turning
    // by an equal share of the bend.
    let arc = bend * r;
    // Rounded up; `ceil` of a number is a tree, so through `floor`.
    let rows = -(-arc / _num(_opt(opts, "pitch", m.pitch * t), "lc::hinge_for: pitch")).floor().to_int();
    let pitch = arc / rows.to_float();
    let turn = bend / rows.to_float();
    // A strip turned by `turn` sweeps its corner across the slot [H3].
    let strip = pitch - width;
    let sweep = strip * (cos(turn) - 1.0) + t * sin(turn);
    if strip <= 0.0 || sweep > width {
        throw `lc::hinge_for: each row turns ${turn * 180.0 / PI} degrees, which closes slots ${width} wide; take wider slots, a closer pitch or a larger radius`;
    }
    // Twisted by `turn` over its length, a strip of sides `a` and `b`
    // strains by (beta / alpha) a turn / length at most [H7].
    let a = min(strip, t);
    let k = _lasercut_torsion(max(strip, t) / a);
    let least = k * a * turn / strain;
    // Two strips and a bridge make a slot; then as many slots and bridges
    // as fit the span, each lengthened to fill it.
    let periods = (span / (2.0 * least + 2.0 * bridge)).floor().to_int();
    if periods < 1 {
        throw `lc::hinge_for: the strips need ${least} each, more than a span of ${span} has room for`;
    }
    let length = span / periods.to_float() - bridge;
    let link = (length - bridge) * 0.5;
    #{
        size: [span, arc],
        opts: #{length: length, width: width, pitch: pitch, bridge: bridge},
        rows: rows,
        link: link,
        strain: k * a * turn / link,
    }
}

// Saint-Venant's torsion of a rectangular bar, sides in the ratio `ratio`
// (at least 1): beta / alpha of its table [H7], so that its strain is
// beta / alpha times its short side times its twist per length.
private fn _lasercut_torsion(ratio) {
    let ratios = [1.0, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 6.0, 8.0, 10.0];
    let alpha = [0.208, 0.231, 0.239, 0.246, 0.258, 0.267, 0.282, 0.299, 0.307, 0.313];
    let beta = [0.141, 0.196, 0.214, 0.229, 0.249, 0.263, 0.281, 0.299, 0.307, 0.313];
    if ratio >= 10.0 {
        // Towards 1/3 for both as the bar gets thinner.
        return 1.0;
    }
    let i = 0;
    while ratios[i + 1] < ratio {
        i += 1;
    }
    let f = (ratio - ratios[i]) / (ratios[i + 1] - ratios[i]);
    (beta[i] + (beta[i + 1] - beta[i]) * f) / (alpha[i] + (alpha[i + 1] - alpha[i]) * f)
}

// --- Boxes ---

/// box_panels(size: Vec3, t: number, opts: #{ inner?: bool, finger?: number, fit?: number } = #{}): Panels
/// type Panels = #{ bottom: Shape, top: Shape, front: Shape, back: Shape, left: Shape, right: Shape }
///
/// The six panels of a closed box, finger-jointed along every edge, each centred on the origin.
///
/// - `size`: `[x, y, z]`, the box's outside, or its inside with `inner`
/// - `t`: the material's thickness
/// - `opts`:
///   - `inner`: `true` if `size` is the inside, `t` less than the outside on every face
///   - `finger`: the fingers' width, as near as an odd count of them allows on each edge, `2 * t` by default, as Boxes.py draws them
///   - `fit`: the clearance between a finger and its notch, as `lc::finger_joint` takes it, 0 by default
///
/// Each panel's X runs along the box's X, or its Y for `left` and `right`.
/// Its Y runs along the box's Y for `bottom` and `top`, or its Z for the rest.
/// `bottom` and `top` keep the fingers at the ends of all their edges, and with them the box's corners.
/// `front` and `back` keep them on their upright edges, whose joints run between `bottom` and `top`; `left` and `right` keep none.
/// Opposite panels are the same shape.
///
/// Notes:
/// - Field: exact inside, a bound outside near the notches.
///
/// See also: `lc::box`, `lc::finger_joint`.
///
/// References:
/// - [Boxes.py](https://github.com/florianfesti/boxes), a generator of laser-cut boxes
///
/// Example: the front of a box 60 by 40 by 30 outside, in 3 mm material.
/// ```
/// lc::box_panels([60, 40, 30], 3).front
/// ```
fn box_panels(size, t) {
    _lasercut_box_panels(size, t, #{})
}

fn box_panels(size, t, opts) {
    _lasercut_box_panels(size, t, opts)
}

private fn _lasercut_box_panels(size, t, opts) {
    _opts(opts, ["inner", "finger", "fit"], "lc::box_panels");
    let t = _num(t, "lc::box_panels: t");
    let s = _vec3(size, "lc::box_panels: size", 0.0);
    if _opt(opts, "inner", false) {
        s = [s[0] + 2.0 * t, s[1] + 2.0 * t, s[2] + 2.0 * t];
    }
    let width = _num(_opt(opts, "finger", 2.0 * t), "lc::box_panels: finger");
    let fit = _num(_opt(opts, "fit", 0.0), "lc::box_panels: fit");
    // The upright edges' joints run between the bottom and the top.
    let upright = s[2] - 2.0 * t;
    if upright <= 0.0 {
        throw `lc::box_panels: a box ${s[2]} tall has no room between its bottom and top, ${t} thick`;
    }
    // Each panel's size, then whether it mates along its top and bottom
    // edges and along its sides.
    let bottom = _lasercut_panel([s[0], s[1]], [s[0], s[1]], t, width, fit, [false, false]);
    let front = _lasercut_panel([s[0], s[2]], [s[0], upright], t, width, fit, [true, false]);
    let left = _lasercut_panel([s[1], s[2]], [s[1], upright], t, width, fit, [true, true]);
    #{bottom: bottom, top: bottom, front: front, back: front, left: left, right: left}
}

// A panel `size` across, centred on the origin, its edges finger-jointed:
// the top and bottom ones over `joints[0]`, the sides over `joints[1]`,
// as their mates if `mate[0]` and `mate[1]`.
private fn _lasercut_panel(size, joints, t, width, fit, mate) {
    let w = size[0];
    let h = size[1];
    let x_joint = _lasercut_finger_joint(joints[0], t, #{width: width, fit: fit, mate: mate[0]});
    let y_joint = _lasercut_finger_joint(joints[1], t, #{width: width, fit: fit, mate: mate[1]});
    let cuts = union(
        x_joint.move([0.0, h * 0.5]),
        x_joint.rotate_z(180).move([0.0, -h * 0.5]),
        y_joint.rotate_z(-90).move([w * 0.5, 0.0]),
        y_joint.rotate_z(90).move([-w * 0.5, 0.0]),
    );
    rect([w, h]).difference(cuts)
}

/// box(size: Vec3, t: number, opts: #{ inner?: bool, finger?: number, fit?: number, gap?: number } = #{}): Shape
///
/// The six panels of a closed box, from `lc::box_panels`, laid out flat to cut, their lower left corner on the origin.
///
/// - `size`, `t`: as `lc::box_panels` takes them
/// - `opts`:
///   - `inner`, `finger`, `fit`: as `lc::box_panels` takes them
///   - `gap`: the space between two panels, `2 * t` by default
///
/// The panels lie in three rows from the bottom up: `bottom` and `top`, then `front` and `back`, then `left` and `right`.
/// `lc::sheet` draws the material around them, to see that they fit on it.
///
/// Notes:
/// - Field: as `lc::box_panels`'s.
///
/// See also: `lc::box_panels`, `lc::sheet`.
///
/// Example: a box 60 by 40 by 30 inside, in 3 mm material, its joints with 0.1 of play.
/// ```
/// lc::box([60, 40, 30], 3, #{inner: true, fit: 0.1})
/// ```
fn box(size, t) {
    _lasercut_layout(size, t, #{})
}

fn box(size, t, opts) {
    _lasercut_layout(size, t, opts)
}

private fn _lasercut_layout(size, t, opts) {
    _opts(opts, ["inner", "finger", "fit", "gap"], "lc::box");
    let t = _num(t, "lc::box: t");
    let gap = _num(_opt(opts, "gap", 2.0 * t), "lc::box: gap");
    let s = _vec3(size, "lc::box: size", 0.0);
    if _opt(opts, "inner", false) {
        s = [s[0] + 2.0 * t, s[1] + 2.0 * t, s[2] + 2.0 * t];
    }
    let p = _lasercut_box_panels(s, t, #{finger: _opt(opts, "finger", 2.0 * t), fit: _opt(opts, "fit", 0.0)});
    let rows = [[p.bottom, s[0], s[1]], [p.front, s[0], s[2]], [p.left, s[1], s[2]]];
    let placed = [];
    let y = 0.0;
    for row in rows {
        let w = row[1];
        let h = row[2];
        // Opposite panels are alike: one of each pair, twice.
        placed.push(row[0].move([w * 0.5, y + h * 0.5]));
        placed.push(row[0].move([w * 1.5 + gap, y + h * 0.5]));
        y += h + gap;
    }
    union(placed)
}

// --- Sheets ---

/// sheet(size: Vec2): Shape
///
/// A sheet of material, its lower left corner on the origin, to draw with `#{role: "score"}` around a layout.
///
/// - `size`: `[width, height]`
///
/// Drawn to score, the 2D views show its outline only, so the parts laid out on it show whether they fit.
/// An export scores it too: leave its draw out of the script, or its layer out of the laser's job, to keep the sheet whole.
///
/// Notes:
/// - Field: exact.
///
/// See also: `lc::box`.
///
/// Example: a sheet 300 by 200.
/// ```
/// lc::sheet([300, 200])
/// ```
fn sheet(size) {
    let s = _vec2(size, "lc::sheet: size");
    rect(s).move([s[0] * 0.5, s[1] * 0.5])
}
