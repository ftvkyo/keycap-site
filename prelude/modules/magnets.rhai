// SPDX-License-Identifier: MPL-2.0
//
// keycap module: disc magnets and their pockets.
//
// kind: 3d
//
//     import "keycap/magnets" as magnets;
//
// Disc magnets are sold by their nominal size, `"6x3"`, and no size has a
// standard: the name is the table.  A magnet is pressed in from z = 0, its
// axis along Z, and lies below it.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources, by the keys of keycap's parts research:
// - [G1] https://totalelement.com/blogs/magnet-projects/how-to-embed-magnets-in-3d-prints ,
//   https://tensor3d.com/products/round-neomydium-magnets-6mm-x-3mm
// - [G2] https://totalelement.com/blogs/magnet-projects/how-to-embed-magnets-in-3d-prints
// - [G3] https://magnetenspecialist.nl/en/blogs/applications/magnets-for-3d-printed-applications
// - [G4] https://ozfdm.com.au/blogs/knowledge-base/embedding-magnets-in-3d-prints
// - [G5] https://neomagnets.net/standard-magnet-size-for-3d-printing/

// --- Sizes ---

/// size(size: string): Magnet
/// type Magnet = #{ d: number, h: number }
///
/// A disc magnet's nominal dimensions from its name.
///
/// - `size`: the diameter and the thickness in mm, `"6x3"`; common ones are 6x2 (the Gridfinity storage system's), 6x3, 8x3, 10x3 and 12x3
///
/// The returned map has the diameter `d` and the thickness `h`.
/// Disc magnets are sold by these nominal sizes; no standard defines them.
///
/// Notes:
/// - Suppliers quote 0.1 either way on both, some 0.05: measure a few before drawing a pocket.
///
/// See also: `magnets::pocket`, `magnets::magnet`.
///
/// References:
/// - [Total Element's guide to embedding magnets](https://totalelement.com/blogs/magnet-projects/how-to-embed-magnets-in-3d-prints), and [Tensor3D's 6 by 3 magnets](https://tensor3d.com/products/round-neomydium-magnets-6mm-x-3mm), for the tolerances
///
/// Example: a 6 by 3 magnet.
/// ```
/// magnets::size("6x3")
/// ```
fn size(size) {
    _magnets_size(size)
}

private fn _magnets_size(size) {
    let parts = if type_of(size) == "string" { size.split("x") } else { [] };
    if parts.len() != 2 {
        throw `magnets::size: a size is a diameter and a thickness, "6x3", got ${size}`;
    }
    #{d: parse_float(parts[0]), h: parse_float(parts[1])}
}

// A magnet's name or its `Magnet` map as it is.
private fn _magnets_of(magnet, what) {
    if type_of(magnet) == "string" {
        _magnets_size(magnet)
    } else if type_of(magnet) == "map" && "d" in magnet && "h" in magnet {
        magnet
    } else {
        throw `${what}: a magnet is a size such as "6x3" or a map of d and h, got ${magnet}`;
    }
}

// --- Parts ---

/// magnet(size: string | Magnet): Shape
/// type Magnet = #{ d: number, h: number }
///
/// A disc magnet, for reference and assemblies, from z = -`h` up to z = 0.
///
/// - `size`: a size, `"6x3"`, as `magnets::size` takes it, or the dimensions, a map of `d` and `h`
///
/// Notes:
/// - Field: exact.
///
/// See also: `magnets::pocket`, `magnets::size`.
///
/// Example: a 10 by 3 magnet.
/// ```
/// magnets::magnet("10x3")
/// ```
fn magnet(size) {
    let m = _magnets_of(size, "magnets::magnet");
    cylinder(m.d * 0.5, [-m.h, 0.0])
}

/// pocket(size: string | Magnet, opts: #{ fit?: string | [number, number], closed?: bool } = #{}): Shape
/// type Magnet = #{ d: number, h: number }
///
/// Cutter for a disc magnet: a pocket from z = 0 down, larger than the magnet by its fit.
///
/// - `size`: a size, `"6x3"`, as `magnets::size` takes it, or the dimensions, a map of `d` and `h`
/// - `opts`:
///   - `fit`: `"press"` (the default), `"glue"`, or `[diameter, depth]`, added to the magnet's
///   - `closed`: the pocket ends at z = 0, for a magnet dropped in while the print is paused and printed over; open above without end by default
///
/// The fits are printing practice, not a standard:
///
/// - `"press"`: 0.1 on the diameter and 0.1 on the depth; makers press magnets in with 0.1 to 0.2 more on the diameter and 0.1 to 0.2 on the depth
/// - `"glue"`: 0.2 on the diameter and 0.1 on the depth; makers glue them with 0.2 to 0.3 more on the diameter
///
/// Leave 0.4 to 0.8 behind a magnet, so that it keeps its pull.
///
/// Notes:
/// - Field: exact.
/// - The sources give fits for 6 by 3 and 8 by 3 magnets; for 10 by 3 and 12 by 3, the same rule is unverified.
///
/// See also: `magnets::magnet`, `magnets::size`.
///
/// References:
/// - [Total Element's guide to embedding magnets](https://totalelement.com/blogs/magnet-projects/how-to-embed-magnets-in-3d-prints)
/// - [Magnetenspecialist's guide to magnets in 3D prints](https://magnetenspecialist.nl/en/blogs/applications/magnets-for-3d-printed-applications)
/// - [OzFDM's guide to embedding magnets](https://ozfdm.com.au/blogs/knowledge-base/embedding-magnets-in-3d-prints), for 6 by 3 magnets
/// - [Neo Magnets' sizes for 3D printing](https://neomagnets.net/standard-magnet-size-for-3d-printing/), for 8 by 3 magnets
///
/// Example: a 6 by 3 magnet glued into a block whose top is at z = 5.
/// ```
/// let block = cuboid([12, 12, 10]);
/// let pocket = magnets::pocket("6x3", #{fit: "glue"}).move([0, 0, 5]);
/// block.difference(pocket)
/// ```
fn pocket(size) {
    _magnets_pocket(size, #{})
}

fn pocket(size, opts) {
    _magnets_pocket(size, opts)
}

private fn _magnets_pocket(size, opts) {
    _opts(opts, ["fit", "closed"], "magnets::pocket");
    let m = _magnets_of(size, "magnets::pocket");
    let fit = _opt(opts, "fit", "press");
    let fit = if fit == "press" {
        [0.1, 0.1]
    } else if fit == "glue" {
        [0.2, 0.1]
    } else if type_of(fit) == "array" && fit.len() == 2 {
        [_num(fit[0], "magnets::pocket: fit"), _num(fit[1], "magnets::pocket: fit")]
    } else {
        throw `magnets::pocket: fit must be press, glue or [diameter, depth], got ${fit}`;
    };
    let r = (m.d + fit[0]) * 0.5;
    let depth = m.h + fit[1];
    if _opt(opts, "closed", false) {
        cylinder(r, [-depth, 0.0])
    } else {
        _bore(r, -depth)
    }
}
