// Keycaps as fields: a sculpted MX cap, its stems, legends and the homing dot.
//
// Import with `import "keycap" as keycap;`.
// A cap is described by a map of options, `keycap::options(...)` filling in `mx_v4.scad`'s values; everything is in mm, the cap standing on z = 0.

// --- Defaults ---

// The sculpt of each row, top to bottom, then the thumb row: the height of the pad's middle, its tilt about Y in degrees, and how far along X its middle sits.
export const ROWS = [
    #{height: 12.5, angle: 10.0, offset: -1.0},
    #{height: 9.5, angle: 7.5, offset: -1.0},
    #{height: 7.5, angle: 3.0, offset: -0.5},
    #{height: 7.5, angle: -3.0, offset: 0.0},
    #{height: 8.5, angle: -7.5, offset: -0.5},
    #{height: 8.5, angle: -7.5, offset: -1.0},
    #{height: 7.0, angle: 7.5, offset: 0.0},
];

// The MX grid: the distance between neighbouring keys' middles, 0.75 in.
export const PITCH = 19.05;

// The MX cap's options, with the values of `mx_v4.scad`, and the legends' depth.
export const MX = #{
    row: 1,                     // 1 top, 4 home, 6 bottom, 7 thumb; picks height, angle and offset from ROWS

    base: 18.0,                 // side at z = 0
    base_squareness: 0.99,      // 0 a circle, towards 1 a square
    pad: 13.0,                  // side of the top
    pad_squareness: 0.5,
    dish_depth: 0.75,           // from the rim down to the dish's middle
    dish_flat: 1.0,             // radius of the flat in the dish's middle

    wall: 1.0,

    stem_radius: 2.5,
    stem_lift: 1.0,             // the stem's foot above z = 0
    stem_height: 4.5,           // the stem's free length, below the supports
    cross: [1.4, 4.1],          // the cross's slot width and arm length
    cross_depth: 3.5,
    cross_rounding: 0.0,        // fillets in the cross's inner corners
    reinforced: false,          // a solid block round the cross; not for box switches
    reinforced_size: [5.0, 6.5],
    support: 1.0,               // thickness of the ribs from the stem to the walls

    markers: true,              // a post inside the -X wall per row number
    dot: false,                 // a homing bump in the dish

    double: false,              // 2u along Y, with stabiliser stems
    gap: 1.2,                   // between caps; a 2u cap is one base and one gap longer
    stabilisers: 11.7,          // stabiliser stems' distance from the middle

    legend: 0.4,                // how deep a legend is cut under the dish
};

// The Choc v1 stem's options: two legs, from `src/cryptodancer/keycap.scad`.
export const CHOC = #{
    leg: [1.1, 2.8],            // across X and Y
    length: 3.2,
    gap: 4.6,                   // between the legs
};

/// The cap's options: `MX`, then the sculpt of `opts.row` from `ROWS`, then `opts` itself.
///
/// Example: `keycap::options(#{row: 4, dot: true})`, a homing key
fn options(opts) {
    let row = if "row" in opts { opts.row } else { global::MX.row };
    global::MX + global::ROWS[row - 1] + opts
}

// --- MX body ---

// The sculpted body before its bottom is cut: v4's side wall, eased from
// the base squircle up into the pad's, with the dish on top.
//
// v4 stacks slices on tilted planes: the slice at s, from 0 at the base
// to 1 at the rim, lies on the plane through (offset s, 0, rim s) turned
// about Y.  A field needs the slice through a point.  v4 turns its slices
// by angle s; turning them so that the tangent of the turn grows with s
// instead differs by under a hundredth of a millimetre, and makes the
// plane's equation a quadratic in s, solved here in closed form, without
// trigonometry.
//
// Within the slice, the outline is the base squircle's and pad's radii
// blended per ray, as v4 blends its points, scaled from the base down to
// the pad by an arc sine easing whose infinite slope at the rim rounds the
// shoulder into the top.
private fn outer(o) {
    let rim = o.height + o.dish_depth * 0.5;
    let tan_tilt = tan(o.angle * PI / 180.0);

    // z + x tan(a) = s (rim + offset tan(a)), with tan(a) = s tan_tilt.
    let k = o.offset * tan_tilt;
    let b = rim - x * tan_tilt;
    // The denominators are positive on the cap; max keeps their intervals
    // clear of 0, which would make them NaN.
    let s = 2.0 * z / max(b + sqrt(max(square(b) + 4.0 * k * z, 0.0)), 1e-6);
    // Below the base the wall carries on, so that the shell's inside
    // reaches through the bottom.
    let s = clamp(s, -0.25, 1.0);

    let ta = s * tan_tilt;
    let ca = 1.0 / sqrt(1.0 + square(ta));
    let sa = ta * ca;
    let qx = x - o.offset * s;
    let qz = z - rim * s;
    let u = qx * ca - qz * sa;
    let rho = hypot(u, y) + 1e-6;

    let size = lerp(o.pad, o.base, acos(s) * 2.0 / PI) * 0.5;
    let pad = squircle_ray(u, y, o.pad_squareness);
    let base = squircle_ray(u, y, o.base_squareness);
    let t = square(square(s));
    let r = lerp(base.r, pad.r, t);
    let slope = lerp(base.r * base.slope, pad.r * pad.slope, t) / r;
    let n = sqrt(1.0 + square(slope));

    // The field within the slice is a distance; where the wall leans, the
    // distance square to it is shorter by sqrt(1 + g^2), g the field's
    // rate of change across the slices.  g comes by the chain rule through
    // s, from values already at hand: the slice's outline grows (size, r),
    // and the point's place in the slice moves (u), as s changes from one
    // slice to the next.
    let ds = (sa * s * tan_tilt + ca) / max(2.0 * k * s + b, 1e-6);
    let dsize = -(o.base - o.pad) / (PI * sqrt(max(1.0 - square(s), 1e-4)));
    let dr = (pad.r - base.r) * 4.0 * s * s * s;
    let du = -o.offset * ca + rim * sa + tan_tilt * square(ca) * (-qx * sa - qz * ca);
    let g = ((u + slope * y) / rho * du - dsize * r - size * dr) * ds / n;

    let wall = (rho - size * r) / n / sqrt(1.0 + square(g));
    max(wall, dish(o))
}

// The dish, below the rim's plane: v4's slices from the flat middle out
// to the rim, each lifted straight up while the plane they lie in is
// tilted.  In the tilted frame that lift is a shear, undone on the
// coordinates; the rise follows a half cosine of the pad-squircle radius,
// flat in the middle and at the rim.  Divided by the rise's slope, so the
// field stays a distance across it.
private fn dish(o) {
    let tilt = o.angle * PI / 180.0;
    let qx = x - o.offset;
    let qz = z - (o.height - o.dish_depth * 0.5);
    let w = qx * sin(tilt) + qz * cos(tilt);
    let u = qx * cos(tilt) - qz * sin(tilt) + w * tan(tilt);

    let pad = squircle_ray(u, y, o.pad_squareness);
    let span = o.pad * 0.5 - o.dish_flat;
    let k = clamp((hypot(u, y) / pad.r - o.dish_flat) / span, 0.0, 1.0);
    let depth = o.dish_depth * cos(tilt);
    let rise = depth * (1.0 - cos(PI * k)) * 0.5;
    let slope = depth * PI * 0.5 / span * sin(PI * k) * sqrt(1.0 + square(pad.slope)) / pad.r;
    (w - rise) / sqrt(1.0 + square(slope))
}

// The 2u stretch, when the cap is double.
private fn stretched(shape, o) {
    if o.double { elongate(shape, [0.0, o.base + o.gap, 0.0]) } else { shape }
}

/// The cap's outer solid, without hollowing: v4's `display_hull_only`.
///
/// A distance to first order: exact on the surface and close near it, so `shell` and `offset` on it come out as thick as asked, to 0.01 mm on most of the cap and less than 0.1 mm thin at worst, under the base's tight corners and the shoulder.
///
/// - `o`: options from `options`
fn body(o) {
    max(stretched(outer(o), o), -z)
}

// --- Inside ---

/// The MX cross, the stem's hole: two slots crossing, `o.cross` wide and long, their inner corners filleted with `o.cross_rounding`.
///
/// Exact, fillets included; the fillets are what OpenSCAD's `offset(-r) offset(r)` makes of the cross.
///
/// Example: `keycap::mx_cross(#{cross: [1.35, 4.1], cross_rounding: 0.3})`
fn mx_cross(o) {
    let a = rect([o.cross[0], o.cross[1]]);
    let b = rect([o.cross[1], o.cross[0]]);
    if o.cross_rounding > 0.0 { union_round(a, b, o.cross_rounding) } else { union(a, b) }
}

// A height above the whole cap, for the parts that grow into its top.
private fn above(o) {
    o.height + o.pad
}

/// The MX stem, from `o.stem_lift` up, with the cross cut `o.cross_depth` into its foot.
///
/// Reaches past the top; intersect it with `body`.
fn mx_stem(o) {
    let post = if o.reinforced { rect(o.reinforced_size) } else { circle(o.stem_radius) };
    let foot = o.stem_lift;
    post.extrude([foot, above(o)])
        .difference(mx_cross(o).extrude([foot - 1.0, foot + o.cross_depth]))
}

// The places of the stems: the middle, and the stabilisers' on a double.
private fn stem_places(o) {
    if o.double { [0.0, o.stabilisers, -o.stabilisers] } else { [0.0] }
}

/// Ribs from the stems to the walls, above the stem's free length.
///
/// Reach past the walls; intersect them with `body`.
fn supports(o) {
    let length = o.base + if o.double { o.base + o.gap } else { 0.0 };
    let ribs = [rect([o.support, length])];
    for at in stem_places(o) {
        ribs.push(rect([o.base, o.support]).move([0.0, at]));
    }
    union(ribs).extrude([o.stem_lift + o.stem_height, above(o)])
}

/// Posts inside the -X wall, one per row number, to tell the rows apart from below.
///
/// Reach past the wall; intersect them with `body`.
fn markers(o) {
    let spread = o.base - o.wall * 6.0;
    let posts = [];
    for i in 0..o.row {
        posts.push(circle(0.75).move([-o.base * 0.5 + o.wall, -spread * 0.5 + spread / 6.0 * i]));
    }
    let posts = if posts.len() == 1 { posts[0] } else { union(posts) };
    posts.extrude([0.0, above(o)])
}

/// Moves a shape from the origin into the middle of the dish, tilted with it: for legends and the dot.
///
/// - `shape`: the shape, its top facing +Z
/// - `o`: options from `options`
fn on_dish(shape, o) {
    shape.rotate_y(o.angle).move([o.offset, 0.0, o.height - o.dish_depth * 0.5])
}

/// The homing bump: a flattened ellipsoid half sunk into the dish's middle.
fn dot(o) {
    on_dish(ellipsoid([0.75, 0.75, 1.0 / 3.0]), o)
}

/// The finished MX cap: `body` hollowed to `o.wall`, measured square to the surface, with stems, supports, row markers and the dot.
///
/// - `o`: options from `options`
///
/// Example: `draw(keycap::keycap(keycap::options(#{row: 3})))`
fn keycap(o) {
    let body = body(o);
    // The shell is cut below z = 0 rather than hollowed above it, which
    // leaves the bottom open.
    let shell = stretched(outer(o), o).shell(o.wall).intersection(-z);
    let stems = [];
    for at in stem_places(o) {
        stems.push(mx_stem(o).move([0.0, at]));
    }
    let inside = stems + [supports(o)];
    if o.markers {
        inside.push(markers(o));
    }
    let cap = union(shell, union(inside).intersection(body));
    if o.dot { union(cap, dot(o)) } else { cap }
}

// --- Choc stem ---

/// The Choc v1 stem: two legs hanging from z = 0 down, their gap centred on the origin along X.
///
/// Exact.
///
/// - `o`: a map like `CHOC`
fn choc_stem(o) {
    let leg = cuboid([o.leg[0], o.leg[1], o.length]).move([0.0, 0.0, -o.length * 0.5]);
    let at = (o.leg[0] + o.gap) * 0.5;
    leg.move([at, 0.0, 0.0]).symmetric_x()
}

// --- Legends ---

// The legends' font.  The cryptodancer's original names "Iosevka:style=Light
// Extended", which nerd-fonts' Iosevka lacks; OpenSCAD then quietly falls
// back to DejaVu Sans, while text() names the font it cannot find.
export const FONT = "Iosevka NF:style=Light";

/// The legend's text size for a label of `n` characters: 10 for one, 8, 6, then 4.
fn legend_size(n) {
    if n <= 1 { 10.0 } else if n == 2 { 8.0 } else if n == 3 { 6.0 } else { 4.0 }
}

/// A label as a 2D shape, centred on the origin, sized for its length by `legend_size`.
///
/// - `label`: the text
/// - `font`: a font as `text` takes it, an installed family such as `"Iosevka NF:style=Light"` or a file
fn legend(label, font) {
    text(label, #{size: legend_size(label.len()), font: font, halign: "center", valign: "center"})
}

/// A label as a cutter for `engrave`: `legend` on the dish, reading from +X, the typist's side, reaching through the dish.
///
/// - `label`: the text
/// - `font`: a font as `legend` takes it
/// - `o`: options from `options`
fn dish_legend(label, font, o) {
    on_dish(legend(label, font).rotate_z(90).extrude([-1.0, 1.0]), o)
}

/// Caps of the row `o` along +Y, `PITCH` apart from the origin on, one per label, each label engraved `o.legend` deep in its dish.
///
/// As many caps as labels cost one cap, and their legends.
///
/// - `labels`: the legends, the first on the origin; only one for a 2u cap
/// - `font`: a font as `legend` takes it
/// - `o`: options from `options`
///
/// Example: `draw(keycap::caps(["Q", "W", "E"], keycap::FONT, keycap::options(#{row: 3})))`
fn caps(labels, font, o) {
    let step = [0.0, global::PITCH];
    let counts = [1, labels.len()];
    let cutters = [];
    for i in 0..labels.len() {
        cutters.push(dish_legend(labels[i], font, o).move([0.0, global::PITCH * i]));
    }
    let cutters = if cutters.len() == 1 { cutters[0] } else { union(cutters) };
    engrave(keycap(o).repeat_grid(step, counts), cutters, -body(o).repeat_grid(step, counts), o.legend)
}
