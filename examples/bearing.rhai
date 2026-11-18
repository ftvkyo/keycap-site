// SPDX-License-Identifier: 0BSD
//
// A printed ball bearing: two shells round a ring of loose balls in a cage,
// the inner shell in two halves screwed together through joiners.
//
// Ported from `lib/parts.scad`, as a module:
// `import "bearing" as bearing;`.
// It differs in:
// - the options: the original's keyword arguments are one map, and the
//   parts come back as a map, where it picks one with PART; the cutters for
//   the joiners, its children, are the map's `cutters`;
// - the closings, offset(-r) offset(r), that round the inner corners of the
//   joiners and the cage's profile: a field cannot close a union, so
//   `union_round` fills the joiners' corners, the same where they meet
//   square, and the cage is a plain union, whose corners, all obtuse, the
//   original's closing fills by less than 0.1;
// - the shells and the cage are round, where the original's
//   `fn_rotate_extrude` facets them.

// --- Bearing ---

/// bearing(o: #{ shell_height, shell_outer_diameter, shell_inner_diameter, shell_inner_joiner_count, shell_inner_joiner_height, shell_inner_gap, ball_count, ball_diameter, ball_margin, cage_margin, cage_ball_margin?, solid?, cutters? }): #{ outer, inner_top, inner_bottom, cage, balls }
///
/// A printed bearing, centred on the origin, its axis along Z.
///
/// - `o`: the original `bearing` module's arguments, by the same names, and:
///   - `cage_ball_margin`: `ball_margin` by default
///   - `solid`: the inner shell's middle filled, rather than joiners round its rim; false by default
///   - `cutters`: `[top, bottom]`, cut from each inner half at every joiner, its z = 0 on the joiner's top, as the original's children are
///
/// The map's parts are the original's PART values: `outer` is "bearing-outer", `inner_top` and `inner_bottom` its inner halves, `cage` one cage, and `balls` the balls, both rows, for reference.
fn bearing(o) {
    let h = o.shell_height;
    let d_out = o.shell_outer_diameter;
    let d_in = o.shell_inner_diameter;
    let n = o.ball_count;

    // The balls' circle, and the room round each ball.
    let d = (d_out + d_in) / 2;
    let wall_w = (d_out - d_in) / 2;
    let g = o.ball_diameter / 2 + o.ball_margin;
    let gap_inner_w = g;
    let gap_outer_w = g / 2;

    // The shells' profile, in the plane through the axis: a wall with a
    // groove for each row of balls, parted by a gap that zigzags between
    // them.
    let base = rect([wall_w, h]).move([(d_in + wall_w) / 2, 0]);
    let groove = rect([g * 3, g * 2]).rotate_z(45).intersection(rect([g * 2, g * 3])).move([d / 2, h / 4]);
    let gaps = union([
        groove.symmetric_y(),
        rect([gap_inner_w, h / 2]).move([d / 2 - g + gap_inner_w / 2, 0]),
        rect([gap_outer_w, h / 2]).move([d / 2 + g - gap_outer_w / 2, h / 2]),
        rect([gap_outer_w, h / 2]).move([d / 2 + g - gap_outer_w / 2, -h / 2]),
    ]);
    let profile = base.difference(gaps);

    // The two shells part along the gap's middle.
    let a = d / 2 - g + gap_inner_w / 2;
    let b = d / 2 + g - gap_outer_w / 2;
    let inner = polygon([[0, 0], [a, 0], [a, h / 4], [b, h / 4], [b, h / 2], [0, h / 2]]);
    let outer = polygon([
        [a, 0], [a, -h / 4], [b, -h / 4], [b, -h / 2],
        [d_out / 2, -h / 2], [d_out / 2, h / 2],
        [b, h / 2], [b, h / 4], [a, h / 4],
    ]);

    // --- Inner shell ---

    let jn = o.shell_inner_joiner_count;
    let jh = o.shell_inner_joiner_height;
    let jr = d_in / 3;
    let solid = "solid" in o && o.solid;
    // A solid middle reaches halfway into the shell, so that the two do
    // not meet on a face, where their union's field would be 0 inside.
    let joiners = if solid {
        circle((d_in / 2 + d / 2 - g) / 2)
    } else {
        let lobes = circle(jr).move([d_in / 2, 0]).repeat_polar(jn);
        union_round(lobes, annulus([d_in / 2 + jr, d_in / 2]), jr / 4)
            .intersection(circle(d / 2 - g))
    };
    let half = union(revolve(profile.intersection(inner)), joiners.extrude([0, jh]))
        .intersection(o.shell_inner_gap / 2 - z);

    let cutters = if "cutters" in o { o.cutters } else { [] };
    let cut = |half, cutter| {
        half.difference(cutter.move([(d_in - jr) / 2, 0, jh]).polar_array(jn))
    };
    let inner_top = if cutters.len() > 0 { cut.call(half, cutters[0]) } else { half };
    let inner_bottom = if cutters.len() > 1 { cut.call(half, cutters[1]) } else { half };

    // --- Cage ---

    let cage_r = o.ball_diameter / 3;
    let margin = if "cage_ball_margin" in o { o.cage_ball_margin } else { o.ball_margin };
    let cage_ball_r = o.ball_diameter / 2 + margin;
    let cage_w = gap_inner_w - o.cage_margin * 2;

    // The torus that holds the balls, braced to the flat ring that
    // stiffens it.  `union_round` would bulge where the brace's and the
    // ring's faces run on from each other.
    let el = g - gap_inner_w / 2 + cage_w / 2;
    let er = cage_r;
    let brace = rect(cage_r * 2).rotate_z(45).move([-cage_r / SQRT_2, -cage_r / SQRT_2])
        .intersection(rect([el + er, h / 2]).move([(er - el) / 2, 0]));
    let ring_h = (h - o.shell_inner_gap) / 5;
    let ring = rect([cage_w, ring_h]).move([d / 2 - g + gap_inner_w / 2, o.shell_inner_gap / 2 + h * 3 / 20]);
    let cage_profile = union(union(circle(cage_r), brace).move([d / 2, h / 4]), ring);
    let cage = revolve(cage_profile)
        .difference(sphere(cage_ball_r).move([d / 2, 0, h / 4]).repeat_polar(n));

    let ball = sphere(o.ball_diameter / 2).move([d / 2, 0, h / 4]);
    let balls = ball.symmetric_z().repeat_polar(n);

    #{
        outer: revolve(profile.intersection(outer)),
        inner_top: inner_top,
        inner_bottom: inner_bottom.reflect_z(),
        cage: cage,
        balls: balls,
    }
}
