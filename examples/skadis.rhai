// SPDX-License-Identifier: 0BSD
//
// IKEA SKÅDIS pegboard: its dimensions, its holes and a peg that locks into
// one; a module for `import "skadis" as skadis;`.
//
// The board stands in the XZ plane, its front face at y = 0 and its back at
// y = THICKNESS; a hole's centre is the origin.
//
// A module's functions see its constants through `global::`, as a script's
// do; importers read them as `skadis::THICKNESS`.
//
// Unverified: the board's dimensions, and the peg's fit in a hole.

export const SLOT_W = 5.0;
export const SLOT_H = 15.0;
export const THICKNESS = 5.0;

// Between holes along a row, and down a column; alternate columns sit half
// a column's pitch lower.
export const PITCH = [20.0, 40.0];

/// One hole: a vertical slot through the board, a little longer than the board is thick.
fn hole() {
    let half = (global::SLOT_H - global::SLOT_W) / 2;
    stroke([[0, -half], [0, half]], global::SLOT_W)
        .extrude([-global::THICKNESS - 1, 1])
        .rotate_x(90)
}

/// A piece of board, `cols` holes wide and `rows` holes tall, its top left hole at the origin.
fn board(cols, rows) {
    let p = global::PITCH;
    let holes = [];
    for c in 0..cols {
        for r in 0..rows {
            holes.push(hole().move([c * p[0], 0, -r * p[1] - (c % 2) * p[1] / 2]));
        }
    }
    let size = [cols * p[0], global::THICKNESS, (rows + 0.5) * p[1]];
    cuboid(size)
        .move([(cols - 1) * p[0] / 2, global::THICKNESS / 2, (p[1] - size[2]) / 2 - p[1] / 4])
        .difference(holes)
}

/// A peg for one hole, seated: its neck rests at the bottom of the slot and its lip hangs down behind the board.
///
/// The peg goes in tilted, lip first, and drops into place; everything in front of y = 0 is the part's to add.
///
/// - `clearance`: taken off the neck's width and height, and the gap behind the board
fn peg(clearance) {
    let w = global::SLOT_W - clearance;
    let back = global::THICKNESS + clearance / 2;
    let lip_t = 2.5;
    let drop = 6.0;
    let bottom = -global::SLOT_H / 2 + clearance / 2;
    let neck = stroke([[0, bottom + w / 2], [0, -w / 2]], w)
        .extrude([-back - lip_t, 1])
        .rotate_x(90);
    let lip = stroke([[0, bottom - drop + w / 2], [0, -w / 2]], w)
        .extrude([-back - lip_t, -back])
        .rotate_x(90);
    union(neck, lip)
}
