// SPDX-License-Identifier: MPL-2.0
//
// keycap prelude: involute spur gears.
//
// kind: 2d
//
// The involute of a circle has a closed-form distance: its normals are the
// tangents of the base circle, so every involute of one base circle is an
// offset of every other, and the distance to the flank is the base radius
// times the angle between the point and the flank at the point's radius.

// --- Gears ---

/// gear_radii(teeth: number, m: number, opts: #{ pressure_angle?: number, clearance?: number, backlash?: number, fillet?: number } = #{}): #{ pitch: number, base: number, tip: number, root: number }
///
/// The radii of the circles of an `involute_gear`, as a map.
///
/// - `teeth`, `m`, `opts`: as for `involute_gear`
///
/// The map has the radii of four circles:
///
/// - `pitch`: the pitch circle, `m * teeth / 2`, where two meshing gears roll on each other
/// - `base`: the base circle, which the flanks unwind from
/// - `tip`: the tip circle (the addendum circle), the outside of the teeth
/// - `root`: the root circle (the dedendum circle), the bottom of the gaps between the teeth
///
/// Two gears mesh when their centres are the sum of their pitch radii apart.
/// `fillet` changes no radius, and is accepted so that one map of options serves both functions.
///
/// See also: `involute_gear`.
///
/// References:
/// - [List of gear nomenclature, Wikipedia](https://en.wikipedia.org/wiki/List_of_gear_nomenclature)
///
/// Example: the radii of a gear of 12 teeth, module 2.
/// ```
/// gear_radii(12, 2)
/// ```
/// Example: gears of 12 and 20 teeth in mesh, the larger turned by half a tooth so that a gap faces the smaller's tooth.
/// ```
/// let d = gear_radii(12, 2).pitch + gear_radii(20, 2).pitch;
/// let small = involute_gear(12, 2);
/// let large = involute_gear(20, 2).rotate_z(9).move([d, 0]);
/// union(small, large).extrude(6)
/// ```
fn gear_radii(teeth, m) {
    gear_radii(teeth, m, #{})
}

fn gear_radii(teeth, m, opts) {
    _opts(opts, ["pressure_angle", "clearance", "backlash", "fillet"], "gear_radii");
    let g = _gear(teeth, m, opts, "gear_radii");
    #{pitch: g.rp, base: g.rb, tip: g.ra, root: g.rf}
}

/// involute_gear(teeth: number, m: number, opts: #{ pressure_angle?: number, clearance?: number, backlash?: number, fillet?: number } = #{}): Shape
///
/// Profile of an involute spur gear in XY, centred on the origin, with a tooth on +X.
///
/// - `teeth`: the number of teeth, an integer, 3 or more
/// - `m`: the module, the size of the teeth: the pitch diameter over the number of teeth
/// - `opts`:
///   - `pressure_angle`: in degrees, 20 by default; it sets how steep the flanks are
///   - `clearance`: the gap between the tips of a mating gear and the bottom of the gaps, as a fraction of `m`; 0.25 by default, as in the gear standard ISO 53
///   - `backlash`: how much thinner each tooth is along the pitch circle, in mm; 0 by default
///   - `fillet`: the radius of the fillet where the teeth meet the root circle; 0 by default, 0.38 times `m` in ISO 53
///
/// The flanks are involutes of the base circle: the curve that the end of a taut string draws as it unwinds from the circle.
/// Below the base circle, the flanks run straight towards the centre.
/// The teeth reach `m` beyond the pitch circle, and the gaps go `m` times 1 + `clearance` below it.
///
/// Two gears mesh when they have the same `m` and `pressure_angle`, and their centres are the sum of their pitch radii apart; `gear_radii` gives the radii.
/// The play between two meshing gears' teeth is the sum of their `backlash`.
/// `extrude` makes a spur gear of the profile; with a `twist`, a helical gear, and with a twist that turns back, a herringbone gear.
///
/// Notes:
/// - Field: exact near the flanks and the root circle; a bound beyond the corners of the tips; steep on the flanks below the base circle, by the base radius over the radius; near a fillet, as `union_round` makes it.
/// - The teeth are not undercut, as a gear cutter would make them: below about 17 teeth at a pressure angle of 20 degrees, the tips of a mating gear may rub the roots of the flanks.
///
/// See also: `gear_radii`, `extrude`.
///
/// References:
/// - [Involute gear, Wikipedia](https://en.wikipedia.org/wiki/Involute_gear)
/// - [List of gear nomenclature, Wikipedia](https://en.wikipedia.org/wiki/List_of_gear_nomenclature): module, pressure angle, addendum, dedendum, backlash, undercut
/// - [ISO 53:1998](https://www.iso.org/standard/22643.html), the standard basic rack tooth profile, for `clearance` and `fillet`
///
/// Example: a spur gear 6 thick, with a bore for a 5 mm shaft.
/// ```
/// involute_gear(12, 2, #{fillet: 0.76})
///     .extrude([0, 6])
///     .difference(cylinder(2.5, 20))
/// ```
/// Example: a herringbone gear, its teeth turning one way and then back as it rises.
/// ```
/// involute_gear(16, 2)
///     .extrude([0, 10], #{twist: [[0, 0], [0.5, 12], [1, 0]]})
/// ```
fn involute_gear(teeth, m) {
    involute_gear(teeth, m, #{})
}

fn involute_gear(teeth, m, opts) {
    _opts(opts, ["pressure_angle", "clearance", "backlash", "fillet"], "involute_gear");
    let g = _gear(teeth, m, opts, "involute_gear");
    let fillet = _num(_opt(opts, "fillet", 0.0), "involute_gear: fillet");
    let r = _hypot(x, y);
    let sector = TAU / teeth;
    // Fold every tooth onto the one on +X, and its two flanks onto one.
    let a = abs((_atan2(y, x) + sector * 0.5) % sector - sector * 0.5);
    // The involute's polar angle at radius r: tan(alpha) - alpha, alpha the
    // pressure angle there; 0 at and below the base circle, where the flank
    // continues radially, and where `sqrt` and `acos` have no gradient.
    let rr = max(r, g.rb);
    let inv = sqrt(max(square(rr) - g.rb * g.rb, 0.0)) / g.rb - acos(g.rb / rr);
    let inv = _select_less(g.rb, r, inv, 0.0);
    let flank = g.rb * (a - g.half_base + inv);
    let teeth_field = max(flank, r - g.ra);
    let root = r - g.rf;
    if fillet > 0.0 {
        union_round(teeth_field, root, fillet)
    } else {
        min(teeth_field, root)
    }
}

// The numbers behind a gear.
fn _gear(teeth, m, opts, what) {
    if type_of(teeth) != "i64" || teeth < 3 {
        throw `${what}: teeth must be an integer of at least 3, got ${teeth}`;
    }
    let m = _num(m, `${what}: m`);
    let alpha = _num(_opt(opts, "pressure_angle", 20.0), `${what}: pressure_angle`) * PI / 180.0;
    let clearance = _num(_opt(opts, "clearance", 0.25), `${what}: clearance`);
    let backlash = _num(_opt(opts, "backlash", 0.0), `${what}: backlash`);
    let rp = m * teeth * 0.5;
    let rb = rp * alpha.cos();
    // Half a tooth's angle at the pitch circle, then at the base circle,
    // where the flank's involute starts.
    let half_pitch = PI / (2.0 * teeth) - backlash / (2.0 * rp);
    let half_base = half_pitch + alpha.tan() - alpha;
    #{rp: rp, rb: rb, ra: rp + m, rf: rp - m * (1.0 + clearance), half_base: half_base}
}
