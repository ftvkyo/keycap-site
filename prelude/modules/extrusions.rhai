// SPDX-License-Identifier: MPL-2.0
//
// keycap module: aluminium extrusions with T-slots.
//
// kind: 3d
//
//     import "keycap/extrusions" as extrusions;
//
// `profile` and `beam` take a square profile's dimensions, with a slot on
// every side, B-type (Item-style) or V-slot; the table only supplies them,
// by name.  A profile is the 2D cross-section, centred on the origin, and
// a beam the 3D bar, from z = 0 up; the module's kind is the beam's.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources, by the keys of keycap's parts research: Misumi's catalogue
// drawings, read by eye from rendered images.
// - [M1] https://us.misumi-ec.com/pdf/fa/2012/p2_0511.pdf (HFS5-2020)
// - [M2] https://us.misumi-ec.com/pdf/fa/2012/p2_0553.pdf (HFS6's slot)
// - [M3] https://uk.misumi-ec.com/pdf/fa/p2_0511.pdf (HFS6-3030)
// - [M4] https://us.misumi-ec.com/pdf/fa/2010/p2323.pdf (HFS8-6T-4040)
// - [M5] https://us.misumi-ec.com/pdf/fa/2019/2019_US_2768.pdf (HFS8's slot, HFS8-4080)

// --- Tables ---

/// misumi(): #{ [name: string]: Profile }
/// type Profile = #{ size: number, slot: number, lip: number, cavity: [number, number], bore: number, corner: number, v?: number }
///
/// Misumi's HFS aluminium extrusions, with B-type slots, by name: HFS5-2020 (slot 6), HFS6-3030 (slot 8) and HFS8-4040 (slot 10).
///
/// Each profile's row:
///
/// - `size`: the square's side
/// - `slot`: the slot's opening
/// - `lip`: the thickness of the overhang either side of the opening
/// - `cavity`: `[width, depth]`, the T-cavity's width under the lips and its depth below them
/// - `bore`: the centre hole's diameter
/// - `corner`: the outer corners' radius
///
/// A name is Misumi's series, by its slot (HFS5 has slots 6 wide), then the outline: 2020 is 20 by 20 mm.
/// The cavity's sides are drawn at 45 degrees from its width down to its bottom.
/// The drawings' 120-degree V of 0.3 at the slot's bottom is left out.
///
/// Notes:
/// - From Misumi's catalogue drawings, unverified against a real profile.
/// - HFS5-2020's cavity depth may be its whole depth, lip included: unverified.
/// - HFS8's lip is ambiguous on its drawing, and HFS8-4040 is HFS8-4080's 40 mm side: unverified.
/// - Item's own slot 6, 8 and 10 profiles match by slot width only, unverified.
///
/// See also: `extrusions::profile`, `extrusions::beam`.
///
/// References:
/// - Misumi's catalogue drawings of [HFS5-2020](https://us.misumi-ec.com/pdf/fa/2012/p2_0511.pdf), [HFS6's slot](https://us.misumi-ec.com/pdf/fa/2012/p2_0553.pdf), [HFS6-3030](https://uk.misumi-ec.com/pdf/fa/p2_0511.pdf), [HFS8-6T-4040](https://us.misumi-ec.com/pdf/fa/2010/p2323.pdf) and [HFS8-4080](https://us.misumi-ec.com/pdf/fa/2019/2019_US_2768.pdf)
/// - [T-slot structural framing, Wikipedia](https://en.wikipedia.org/wiki/T-slot_structural_framing)
///
/// Example: HFS5-2020's centre hole, to tap for an M5 screw.
/// ```
/// extrusions::misumi()["HFS5-2020"].bore
/// ```
fn misumi() {
    #{
        "HFS5-2020": #{size: 20.0, slot: 6.0, lip: 2.0, cavity: [12.0, 4.0], bore: 4.2, corner: 1.0},     // [M1]; depth unverified
        "HFS6-3030": #{size: 30.0, slot: 8.0, lip: 2.0, cavity: [16.5, 7.0], bore: 6.8, corner: 2.0},     // [M2], [M3]
        "HFS8-4040": #{size: 40.0, slot: 10.0, lip: 5.5, cavity: [20.0, 7.0], bore: 10.5, corner: 3.0},   // [M4], [M5]; lip unverified
    }
}

// A profile's name or its `Profile` map as it is.
private fn _extrusions_of(profile, what) {
    if type_of(profile) == "string" {
        let table = misumi();
        if !(profile in table) {
            throw `${what}: unknown profile ${profile}; known: ${table.keys()}`;
        }
        table[profile]
    } else if type_of(profile) == "map" && "size" in profile && "slot" in profile {
        profile
    } else {
        throw `${what}: a profile is a name such as "HFS5-2020" or a map from extrusions::misumi, got ${profile}`;
    }
}

// --- Profiles ---

/// profile(size: string | Profile): Shape
/// type Profile = #{ size: number, slot: number, lip: number, cavity: [number, number], bore: number, corner: number, v?: number }
///
/// 2D cross-section of a square extrusion, a slot on each side, centred on the origin.
///
/// - `size`: a name from `extrusions::misumi`, `"HFS5-2020"`, or the dimensions, a map as its rows, with one more key:
///   - `v`: for a V-slot, the depth of the 45-degree chamfers either side of the opening, which wheels run on; 0 by default, a B-type slot
///
/// The slot's opening runs through the lips, then widens into the cavity, whose sides close in at 45 degrees towards the centre.
/// The bore runs through the middle.
///
/// No table has OpenBuilds' V-slot.
/// For a V-slot profile, measure one, or read its maker's drawing, for `slot`, `lip`, `cavity` and `v`.
///
/// Notes:
/// - Field: exact inside; outside, in the slots, a bound.
/// - One slot is drawn, and the others are folds of it: about 600 operations.
///
/// See also: `extrusions::beam`, `extrusions::misumi`.
///
/// References:
/// - [T-slot structural framing, Wikipedia](https://en.wikipedia.org/wiki/T-slot_structural_framing)
///
/// Example: Misumi's 2020 profile.
/// ```
/// extrusions::profile("HFS5-2020")
/// ```
fn profile(size) {
    _extrusions_profile(size)
}

private fn _extrusions_profile(size) {
    let p = _extrusions_of(size, "extrusions::profile");
    let a = p.size * 0.5;
    let half = p.slot * 0.5;
    let v = _opt(p, "v", 0.0);
    let top = a - p.lip;
    let cw = p.cavity[0] * 0.5;
    let bottom = top - p.cavity[1];
    let bw = max(cw - p.cavity[1], 0.0);
    // The +X slot's outline, from outside the face round to its other side;
    // past the face it runs on, so that the cut opens out.
    let points = [[a + 1.0, half + v], [a, half + v]];
    if v > 0.0 {
        points.push([a - v, half]);
    }
    points += [[top, half], [top, cw], [bottom, bw], [bottom, -bw], [top, -cw], [top, -half]];
    if v > 0.0 {
        points.push([a - v, -half]);
    }
    points += [[a, -half - v], [a + 1.0, -half - v]];
    // Every side's slot is the +X one: fold the plane into the eighth from
    // +X to the diagonal.
    let ax = abs(x);
    let ay = abs(y);
    let slot = remap(polygon(points), max(ax, ay), min(ax, ay), z);
    let outline = rect(p.size, #{round: p.corner});
    max(max(outline, -slot), p.bore * 0.5 - _hypot(x, y))
}

/// beam(size: string | Profile, length: number): Shape
/// type Profile = #{ size: number, slot: number, lip: number, cavity: [number, number], bore: number, corner: number, v?: number }
///
/// A length of extrusion, `extrusions::profile` from z = 0 up to `length`.
///
/// - `size`: a name from `extrusions::misumi`, or the dimensions, as `extrusions::profile` takes them
/// - `length`: the beam's length
///
/// Notes:
/// - Field: `extrusions::profile`'s.
///
/// See also: `extrusions::profile`, `extrusions::misumi`.
///
/// Example: 60 mm of Misumi's 3030.
/// ```
/// extrusions::beam("HFS6-3030", 60)
/// ```
fn beam(size, length) {
    extrude(_extrusions_profile(size), [0.0, _num(length, "extrusions::beam: length")])
}
