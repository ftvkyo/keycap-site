// SPDX-License-Identifier: MPL-2.0
//
// keycap module: rolling bearings and their seats.
//
// kind: 3d
//
//     import "keycap/bearings" as bearings;
//
// `bearing` and `seat` take a bearing's bore, outer diameter and width;
// the tables only supply them, by name.  A bearing is pressed in from
// z = 0, its axis along Z, and lies below it.
//
// Its functions call one another only by private names of its own: Rhai
// remembers which function a name called, across modules and the script,
// so a name that another file also defines may call that one instead.
//
// Sources, by the keys of keycap's parts research; SKF's pages were read
// through search snippets and distributors' copies:
// - [B1] https://www.skf.com/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-623
// - [B2] https://www.skf.com/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-625
// - [B3] https://www.skf.com/group/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-608-Z
// - [B4] https://bearingsize.info/catalogue-online/deep-groove-ball-bearings/bearing-61800-skf-obj208259.html
// - [B5] https://www.tuli-shop.com/us/skf-bearing-61800-10x19x5mm ,
//   DSF Bearings' "61800 Series SKF Bearings 61800-61808 (6800-6808)"
// - [B6] https://www.skf.com/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-61803
// - [B7] https://iskbearing.com/product-details/lm8uu
// - [B8] https://www.motedis-usa.com/en/Linear-bearing-8mm-LM8UU

// --- Tables ---

/// deep_groove(): #{ [name: string]: Bearing }
/// type Bearing = #{ d: number, D: number, B: number, r?: number }
///
/// Deep groove ball bearings, by name: 623, 625, 608, and 61800 to 61803, also named 6800 to 6803.
///
/// Each bearing's row, in ISO 15's symbols:
///
/// - `d`: the bore
/// - `D`: the outer diameter
/// - `B`: the width
/// - `r`: the least chamfer of the rings' edges
///
/// The sizes follow ISO 15.
/// The 618 series and the 68 series are two names for the same bearings: 61800 is 6800.
///
/// Notes:
/// - 61801 to 61803 have no `r`.
/// - From copies of SKF's product pages, unverified against SKF's own.
///
/// See also: `bearings::bearing`, `bearings::seat`, `bearings::linear_ball`.
///
/// References:
/// - [ISO 15, Radial bearings, boundary dimensions](https://www.iso.org/standard/69977.html)
/// - SKF's pages of the [623](https://www.skf.com/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-623), the [625](https://www.skf.com/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-625), the [608](https://www.skf.com/group/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-608-Z) and the [61803](https://www.skf.com/products/rolling-bearings/ball-bearings/deep-groove-ball-bearings/productid-61803)
/// - Distributors' pages of SKF's 618 series: [bearingsize.info](https://bearingsize.info/catalogue-online/deep-groove-ball-bearings/bearing-61800-skf-obj208259.html), [Tuli](https://www.tuli-shop.com/us/skf-bearing-61800-10x19x5mm), DSF Bearings
/// - [Ball bearing, Wikipedia](https://en.wikipedia.org/wiki/Ball_bearing)
///
/// Example: a 608's outer diameter, the skateboard bearing's.
/// ```
/// bearings::deep_groove()["608"].D
/// ```
fn deep_groove() {
    let table = #{
        "623": #{d: 3.0, D: 10.0, B: 4.0, r: 0.15},      // [B1]
        "625": #{d: 5.0, D: 16.0, B: 5.0, r: 0.3},       // [B2]
        "608": #{d: 8.0, D: 22.0, B: 7.0, r: 0.3},       // [B3]
        "61800": #{d: 10.0, D: 19.0, B: 5.0, r: 0.3},    // [B4], [B5]
        "61801": #{d: 12.0, D: 21.0, B: 5.0},            // [B5]; r unverified
        "61802": #{d: 15.0, D: 24.0, B: 5.0},            // [B5]; r unverified
        "61803": #{d: 17.0, D: 26.0, B: 5.0},            // [B5], [B6]; r unverified
    };
    // The 618/ series is the 68xx one, by its other name [B5].
    for n in ["0", "1", "2", "3"] {
        table[`680${n}`] = table[`6180${n}`];
    }
    table
}

/// linear_ball(): #{ [name: string]: Bearing }
/// type Bearing = #{ d: number, D: number, B: number, groove?: #{ spacing: number, width: number, d: number } }
///
/// Linear ball bearings, which slide along a shaft, by name: LM8UU.
///
/// The bearing's row:
///
/// - `d`: the bore, for the shaft
/// - `D`: the outer diameter
/// - `B`: the length
/// - `groove`: the grooves for the retaining rings: `spacing`, their distance apart, `width`, and `d`, the diameter at their bottom
///
/// LM8UU is a linear motion (LM) bearing for an 8 mm shaft, sealed at both ends (UU).
/// The LM series has no ISO standard; its dimensions are makers' practice.
///
/// See also: `bearings::bearing`, `bearings::seat`, `bearings::deep_groove`.
///
/// References:
/// - [ISK Bearing's LM8UU](https://iskbearing.com/product-details/lm8uu), and [Motedis's](https://www.motedis-usa.com/en/Linear-bearing-8mm-LM8UU), the values' sources
/// - [Linear-motion bearing, Wikipedia](https://en.wikipedia.org/wiki/Linear-motion_bearing)
///
/// Example: an LM8UU's length.
/// ```
/// bearings::linear_ball()["LM8UU"].B
/// ```
fn linear_ball() {
    #{
        "LM8UU": #{d: 8.0, D: 15.0, B: 24.0, groove: #{spacing: 17.5, width: 1.1, d: 14.3}},    // [B7], [B8]
    }
}

// A bearing's name, from either table, or its `Bearing` map as it is.
private fn _bearings_of(bearing, what) {
    if type_of(bearing) == "string" {
        let table = deep_groove() + linear_ball();
        if !(bearing in table) {
            throw `${what}: unknown bearing ${bearing}; known: ${table.keys()}`;
        }
        table[bearing]
    } else if type_of(bearing) == "map" && "d" in bearing && "D" in bearing && "B" in bearing {
        bearing
    } else {
        throw `${what}: a bearing is a name such as "608" or a map of d, D and B, got ${bearing}`;
    }
}

// --- Parts ---

/// bearing(size: string | Bearing): Shape
/// type Bearing = #{ d: number, D: number, B: number, r?: number, groove?: #{ spacing: number, width: number, d: number } }
///
/// A bearing, for reference and assemblies: a ring `D` across with a bore `d`, from z = -`B` up to z = 0.
///
/// - `size`: a name from `bearings::deep_groove` or `bearings::linear_ball`, `"608"`, or the dimensions, a map of `d`, `D` and `B`
///
/// Its edges are rounded by `r`, where it is known.
///
/// Notes:
/// - Field: exact.
///
/// See also: `bearings::seat`, `bearings::deep_groove`, `bearings::linear_ball`.
///
/// Example: a 608 bearing.
/// ```
/// bearings::bearing("608")
/// ```
fn bearing(size) {
    let b = _bearings_of(size, "bearings::bearing");
    let opts = if "r" in b { #{round: b.r} } else { #{} };
    tube([b.D * 0.5, b.d * 0.5], [-b.B, 0.0], opts)
}

/// seat(size: string | Bearing, opts: #{ fit?: string | number, depth?: number, shoulder?: number } = #{}): Shape
/// type Bearing = #{ d: number, D: number, B: number, r?: number, groove?: #{ spacing: number, width: number, d: number } }
///
/// Cutter for a bearing pressed in from above: a pocket for its outer ring, and a smaller hole on through below it.
///
/// - `size`: a name from `bearings::deep_groove` or `bearings::linear_ball`, `"608"`, or the dimensions, a map of `d`, `D` and `B`
/// - `opts`:
///   - `fit`: added to the outer diameter: `"press"` (0.1, the default), `"slide"` (0.3), or a number
///   - `depth`: the pocket's depth below z = 0, `B` by default
///   - `shoulder`: the diameter of the hole on through below the pocket, so that the pocket's bottom holds the outer ring only; halfway from `d` to `D` by default; 0 for none
///
/// The pocket is open above z = 0 without end, and the hole below it without end.
/// For a bearing held from both sides, cut two seats, one turned over.
///
/// The fits are printing practice, not a standard, and no source gives them.
/// Printed holes come out small, so print a test ring before a part.
///
/// Notes:
/// - Field: exact outside, a bound inside where the hole meets the pocket.
///
/// See also: `bearings::bearing`, `bearings::deep_groove`.
///
/// Example: a 608 pressed into a plate 10 mm thick, its top at z = 5.
/// ```
/// let block = cuboid([30, 30, 10]);
/// let seat = bearings::seat("608").move([0, 0, 5]);
/// block.difference(seat)
/// ```
fn seat(size) {
    _bearings_seat(size, #{})
}

fn seat(size, opts) {
    _bearings_seat(size, opts)
}

private fn _bearings_seat(size, opts) {
    _opts(opts, ["fit", "depth", "shoulder"], "bearings::seat");
    let b = _bearings_of(size, "bearings::seat");
    let fit = _opt(opts, "fit", "press");
    let fit = switch fit {
        "press" => 0.1,
        "slide" => 0.3,
        _ => _num(fit, "bearings::seat: fit"),
    };
    let depth = _num(_opt(opts, "depth", b.B), "bearings::seat: depth");
    let shoulder = _num(_opt(opts, "shoulder", (b.d + b.D) * 0.5), "bearings::seat: shoulder");
    let pocket = _bore((b.D + fit) * 0.5, -depth);
    if shoulder <= 0.0 {
        return pocket;
    }
    min(pocket, max(_hypot(x, y) - shoulder * 0.5, z))
}
