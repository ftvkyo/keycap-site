// SPDX-License-Identifier: MPL-2.0

//! libfive's built-in font, for `text(s, #{font: "libfive"})`: each glyph
//! a small expression of rectangles, triangles and rings, cheap to evaluate
//! but one stylised font, ASCII only, and a bound rather than an exact
//! distance off its straight edges.
//!
//! Ported from libfive's `stdlib_impl.cpp`, Copyright (C) 2021 Matt
//! Keeter; like its origin this file is under the Mozilla Public License,
//! v. 2.0, see <http://mozilla.org/MPL/2.0/>.

use fidget::context::Tree;

use super::{Halign, Options, valign};

/// Space between glyphs, in the font's units: its capital height
const GAP: f32 = 0.1;

/// Distance between lines
const LINE: f32 = 1.1;

/// `string` in the font, `options.size` tall in capitals; `\n` starts a
/// line below.
pub fn text(string: &str, options: &Options) -> Tree {
    let spacing = options.spacing as f32;
    let lines: Vec<&str> = string.split('\n').collect();
    let mut placed = vec![];
    let (mut ascend, mut descend) = (0.0f32, 0.0f32);
    for (row, line) in lines.iter().enumerate() {
        let y = -(row as f32) * LINE;
        let mut pen = 0.0;
        let mut glyphs = vec![];
        for c in line.chars() {
            let (width, shape) = glyph(c);
            let (bottom, top) = extent(c);
            if row == 0 {
                ascend = ascend.max(top);
            }
            if row == lines.len() - 1 {
                descend = descend.max(-(y + bottom));
            }
            if let Some(shape) = shape {
                glyphs.push(shift(shape, pen, y));
            }
            pen += (width + GAP) * spacing;
        }
        let width = pen - GAP * spacing;
        let dx = match options.halign {
            Halign::Left => 0.0,
            Halign::Center => -width / 2.0,
            Halign::Right => -width,
        };
        placed.extend(glyphs.into_iter().map(|g| shift(g, dx, 0.0)));
    }
    let dy = valign(options.valign, f64::from(ascend), f64::from(descend)) as f32;
    let size = options.size as f32;
    let Some(shape) = placed.into_iter().reduce(|a, b| a.min(b)) else {
        return Tree::constant(1e9);
    };
    let shape = shift(shape, 0.0, dy);
    shape.remap_xyz(Tree::x() / size, Tree::y() / size, Tree::z()) * size
}

/// The lowest and highest points of a glyph, for alignment.
fn extent(c: char) -> (f32, f32) {
    let bottom = match c {
        'g' | 'j' | 'p' | 'q' | 'y' => -0.375,
        ',' | ';' => -0.15,
        _ => 0.0,
    };
    let top = match c {
        'a' | 'c' | 'e' | 'g' | 'm' | 'n' | 'o' | 'p' | 'q' | 'r' | 's' | 'u' | 'v' | 'w' | 'x'
        | 'y' | 'z' | ',' | '.' | ':' | ';' | '<' | '>' => 0.55,
        'i' | 'j' => 0.775,
        '\'' | '"' => 0.8,
        '-' => 0.5,
        '+' => 0.75,
        ' ' => 0.0,
        _ => 1.0,
    };
    (bottom, top)
}

// --- Primitives, as libfive's stdlib has them ---

type V2 = [f32; 2];

fn x() -> Tree {
    Tree::x()
}

fn y() -> Tree {
    Tree::y()
}

fn union<const N: usize>(shapes: [Tree; N]) -> Tree {
    shapes.into_iter().reduce(|a, b| a.min(b)).expect("a shape")
}

fn intersection(a: Tree, b: Tree) -> Tree {
    a.max(b)
}

fn difference(a: Tree, b: Tree) -> Tree {
    a.max(-b)
}

fn inverse(a: Tree) -> Tree {
    -a
}

fn shift(t: Tree, dx: f32, dy: f32) -> Tree {
    t.remap_xyz(x() - dx, y() - dy, Tree::z())
}

fn circle(r: f32, c: V2) -> Tree {
    shift((x().square() + y().square()).sqrt() - r, c[0], c[1])
}

fn ring(ro: f32, ri: f32, c: V2) -> Tree {
    difference(circle(ro, c), circle(ri, c))
}

fn rectangle(a: V2, b: V2) -> Tree {
    (a[0] - x())
        .max(x() - b[0])
        .max((a[1] - y()).max(y() - b[1]))
}

fn half_plane(a: V2, b: V2) -> Tree {
    (x() - a[0]) * (b[1] - a[1]) - (y() - a[1]) * (b[0] - a[0])
}

/// Either winding: the union of both
fn triangle(a: V2, b: V2, c: V2) -> Tree {
    union([
        half_plane(a, b).max(half_plane(b, c)).max(half_plane(c, a)),
        half_plane(a, c).max(half_plane(c, b)).max(half_plane(b, a)),
    ])
}

fn reflect_x(t: Tree, x0: f32) -> Tree {
    t.remap_xyz(2.0 * x0 - x(), y(), Tree::z())
}

fn reflect_y(t: Tree, y0: f32) -> Tree {
    t.remap_xyz(x(), 2.0 * y0 - y(), Tree::z())
}

fn scale_x(t: Tree, sx: f32, x0: f32) -> Tree {
    t.remap_xyz((x() - x0) / sx + x0, y(), Tree::z())
}

fn scale_y(t: Tree, sy: f32, y0: f32) -> Tree {
    t.remap_xyz(x(), (y() - y0) / sy + y0, Tree::z())
}

fn shear_x_y(t: Tree, base: V2, height: f32, offset: f32, base_offset: f32) -> Tree {
    let f = (y() - base[1]) / height;
    let sx = x() - (1.0 - f.clone()) * base_offset - f * offset;
    t.remap_xyz(sx, y(), Tree::z())
}

// --- Glyphs ---

/// A glyph's advance and shape, in units of the capital height; `None`
/// for a space.  Characters the font lacks are `?`.
fn glyph(c: char) -> (f32, Option<Tree>) {
    let (width, shape) = match c {
        ' ' => return (0.6, None),
        'A' => (
            0.8,
            union([
                triangle([0.0, 0.0], [0.35, 1.0], [0.1, 0.0]),
                triangle([0.1, 0.0], [0.35, 1.0], [0.45, 1.0]),
                triangle([0.35, 1.0], [0.45, 1.0], [0.8, 0.0]),
                triangle([0.7, 0.0], [0.35, 1.0], [0.8, 0.0]),
                rectangle([0.2, 0.3], [0.6, 0.4]),
            ]),
        ),
        'a' => (
            0.58,
            shift(
                union([
                    shear_x_y(
                        ring(0.275, 0.175, [0.25, 0.275]),
                        [0.0, 0.0],
                        0.35,
                        0.1,
                        0.0,
                    ),
                    rectangle([0.51, 0.0], [0.61, 0.35]),
                ]),
                -0.05,
                0.0,
            ),
        ),
        'B' => (
            0.575,
            union([
                intersection(
                    union([
                        ring(0.275, 0.175, [0.3, 0.725]),
                        ring(0.275, 0.175, [0.3, 0.275]),
                    ]),
                    rectangle([0.3, 0.0], [1.0, 1.0]),
                ),
                rectangle([0.1, 0.0], [0.3, 0.1]),
                rectangle([0.1, 0.45], [0.3, 0.55]),
                rectangle([0.1, 0.9], [0.3, 1.0]),
                rectangle([0.0, 0.0], [0.1, 1.0]),
            ]),
        ),
        'b' => (0.525, lower_b()),
        'C' => (
            0.57,
            union([
                difference(
                    union([
                        ring(0.275, 0.175, [0.3, 0.7]),
                        ring(0.275, 0.175, [0.3, 0.3]),
                    ]),
                    union([
                        rectangle([0.0, 0.3], [0.6, 0.7]),
                        triangle([0.3, 0.5], [1.0, 1.5], [1.0, -0.5]),
                    ]),
                ),
                rectangle([0.025, 0.3], [0.125, 0.7]),
            ]),
        ),
        'c' => (
            0.48,
            difference(
                ring(0.275, 0.175, [0.275, 0.275]),
                triangle([0.275, 0.275], [0.55, 0.555], [0.55, 0.0]),
            ),
        ),
        'D' => (
            0.6,
            union([
                rectangle([0.0, 0.0], [0.1, 1.0]),
                intersection(
                    rectangle([0.0, 0.0], [1.0, 1.0]),
                    ring(0.5, 0.4, [0.1, 0.5]),
                ),
            ]),
        ),
        'd' => (0.525, reflect_x(lower_b(), 0.525 / 2.0)),
        'E' => (
            0.6,
            union([
                rectangle([0.0, 0.0], [0.1, 1.0]),
                rectangle([0.0, 0.0], [0.6, 0.1]),
                rectangle([0.0, 0.9], [0.6, 1.0]),
                rectangle([0.0, 0.45], [0.6, 0.55]),
            ]),
        ),
        'e' => (
            0.55,
            intersection(
                union([
                    difference(
                        ring(0.275, 0.175, [0.275, 0.275]),
                        triangle([0.1, 0.275], [0.75, 0.275], [0.6, 0.0]),
                    ),
                    rectangle([0.05, 0.225], [0.55, 0.315]),
                ]),
                circle(0.275, [0.275, 0.275]),
            ),
        ),
        'F' => (
            0.6,
            union([
                rectangle([0.0, 0.0], [0.1, 1.0]),
                rectangle([0.0, 0.9], [0.6, 1.0]),
                rectangle([0.0, 0.45], [0.6, 0.55]),
            ]),
        ),
        'f' => (
            0.4,
            union([
                intersection(
                    ring(0.25, 0.15, [0.4, 0.75]),
                    rectangle([0.0, 0.75], [0.4, 1.0]),
                ),
                rectangle([0.0, 0.45], [0.4, 0.55]),
                rectangle([0.15, 0.0], [0.25, 0.75]),
            ]),
        ),
        'G' => (
            0.6,
            union([
                rectangle([0.0, 0.3], [0.1, 0.7]),
                rectangle([0.5, 0.3], [0.6, 0.4]),
                rectangle([0.3, 0.4], [0.6, 0.5]),
                difference(
                    union([ring(0.3, 0.2, [0.3, 0.7]), ring(0.3, 0.2, [0.3, 0.3])]),
                    rectangle([0.0, 0.3], [0.6, 0.7]),
                ),
            ]),
        ),
        'g' => (
            0.55,
            union([
                intersection(
                    ring(0.275, 0.175, [0.275, -0.1]),
                    rectangle([0.0, -0.375], [0.55, -0.1]),
                ),
                ring(0.275, 0.175, [0.275, 0.275]),
                rectangle([0.45, -0.1], [0.55, 0.55]),
            ]),
        ),
        'H' => (
            0.6,
            union([
                rectangle([0.0, 0.0], [0.1, 1.0]),
                rectangle([0.5, 0.0], [0.6, 1.0]),
                rectangle([0.0, 0.45], [0.6, 0.55]),
            ]),
        ),
        'h' => (
            0.6,
            union([
                intersection(
                    ring(0.275, 0.175, [0.275, 0.275]),
                    rectangle([0.0, 0.275], [0.55, 0.55]),
                ),
                rectangle([0.0, 0.0], [0.1, 1.0]),
                rectangle([0.45, 0.0], [0.55, 0.275]),
            ]),
        ),
        'I' => (
            0.5,
            union([
                rectangle([0.2, 0.0], [0.3, 1.0]),
                rectangle([0.0, 0.0], [0.5, 0.1]),
                rectangle([0.0, 0.9], [0.5, 1.0]),
            ]),
        ),
        'i' => (
            0.15,
            union([
                circle(0.075, [0.075, 0.7]),
                rectangle([0.025, 0.0], [0.125, 0.55]),
            ]),
        ),
        'J' => (
            0.55,
            union([
                rectangle([0.4, 0.275], [0.5, 1.0]),
                intersection(
                    ring(0.225, 0.125, [0.275, 0.275]),
                    rectangle([0.0, 0.0], [0.55, 0.275]),
                ),
            ]),
        ),
        'j' => (
            0.3,
            union([
                circle(0.075, [0.225, 0.7]),
                rectangle([0.175, -0.1], [0.275, 0.55]),
                intersection(
                    ring(0.275, 0.175, [0.0, -0.1]),
                    rectangle([0.0, -0.375], [0.55, -0.1]),
                ),
            ]),
        ),
        'K' => (
            0.6,
            difference(
                rectangle([0.0, 0.0], [0.6, 1.0]),
                union([
                    triangle([0.1, 1.0], [0.5, 1.0], [0.1, 0.6]),
                    triangle([0.5, 0.0], [0.1, 0.0], [0.1, 0.4]),
                    triangle([0.6, 0.95], [0.6, 0.05], [0.18, 0.5]),
                ]),
            ),
        ),
        'k' => (
            0.5,
            difference(
                rectangle([0.0, 0.0], [0.5, 1.0]),
                union([
                    triangle([0.1, 1.0], [0.5, 1.0], [0.1, 0.45]),
                    triangle([0.37, -0.1], [0.1, -0.1], [0.1, 0.25]),
                    triangle([0.6, 1.0], [0.5, 0.0], [0.18, 0.35]),
                    triangle([0.1, 1.0], [0.6, 1.0], [0.6, 0.5]),
                ]),
            ),
        ),
        'L' => (
            0.6,
            union([
                rectangle([0.0, 0.0], [0.1, 1.0]),
                rectangle([0.0, 0.0], [0.6, 0.1]),
            ]),
        ),
        'l' => (0.15, rectangle([0.025, 0.0], [0.125, 1.0])),
        'M' => (
            0.8,
            union([
                rectangle([0.0, 0.0], [0.1, 1.0]),
                rectangle([0.7, 0.0], [0.8, 1.0]),
                triangle([0.0, 1.0], [0.1, 1.0], [0.45, 0.0]),
                triangle([0.45, 0.0], [0.35, 0.0], [0.0, 1.0]),
                triangle([0.7, 1.0], [0.8, 1.0], [0.35, 0.0]),
                triangle([0.35, 0.0], [0.8, 1.0], [0.45, 0.0]),
            ]),
        ),
        'm' => (
            0.6,
            union([
                intersection(
                    union([
                        ring(0.175, 0.075, [0.175, 0.35]),
                        ring(0.175, 0.075, [0.425, 0.35]),
                    ]),
                    rectangle([0.0, 0.35], [0.65, 0.65]),
                ),
                rectangle([0.0, 0.0], [0.1, 0.525]),
                rectangle([0.25, 0.0], [0.35, 0.35]),
                rectangle([0.5, 0.0], [0.6, 0.35]),
            ]),
        ),
        'N' => (
            0.6,
            union([
                rectangle([0.0, 0.0], [0.1, 1.0]),
                rectangle([0.5, 0.0], [0.6, 1.0]),
                triangle([0.0, 1.0], [0.1, 1.0], [0.6, 0.0]),
                triangle([0.6, 0.0], [0.5, 0.0], [0.0, 1.0]),
            ]),
        ),
        'n' => (
            0.55,
            union([
                intersection(
                    ring(0.275, 0.175, [0.275, 0.275]),
                    rectangle([0.0, 0.325], [0.55, 0.55]),
                ),
                rectangle([0.0, 0.0], [0.1, 0.55]),
                rectangle([0.45, 0.0], [0.55, 0.325]),
            ]),
        ),
        'O' => (
            0.6,
            union([
                rectangle([0.0, 0.3], [0.1, 0.7]),
                rectangle([0.5, 0.3], [0.6, 0.7]),
                difference(
                    union([ring(0.3, 0.2, [0.3, 0.7]), ring(0.3, 0.2, [0.3, 0.3])]),
                    rectangle([0.0, 0.3], [0.6, 0.7]),
                ),
            ]),
        ),
        'o' => (0.55, ring(0.275, 0.175, [0.275, 0.275])),
        'P' => (0.575, upper_p()),
        'p' => (
            0.55,
            union([
                ring(0.275, 0.175, [0.275, 0.275]),
                rectangle([0.0, -0.375], [0.1, 0.55]),
            ]),
        ),
        'Q' => (
            0.6,
            union([
                rectangle([0.0, 0.3], [0.1, 0.7]),
                rectangle([0.5, 0.3], [0.6, 0.7]),
                difference(
                    union([ring(0.3, 0.2, [0.3, 0.7]), ring(0.3, 0.2, [0.3, 0.3])]),
                    rectangle([0.0, 0.3], [0.6, 0.7]),
                ),
                triangle([0.5, 0.1], [0.6, 0.1], [0.6, 0.0]),
                triangle([0.5, 0.1], [0.5, 0.3], [0.6, 0.1]),
            ]),
        ),
        'q' => (
            0.55,
            union([
                ring(0.275, 0.175, [0.275, 0.275]),
                rectangle([0.45, -0.375], [0.55, 0.55]),
            ]),
        ),
        'R' => (
            0.575,
            union([
                upper_p(),
                triangle([0.3, 0.5], [0.4, 0.5], [0.575, 0.0]),
                triangle([0.475, 0.0], [0.3, 0.5], [0.575, 0.0]),
            ]),
        ),
        'r' => (
            0.358,
            union([
                scale_x(
                    intersection(
                        difference(
                            circle(0.55, [0.55, 0.0]),
                            scale_x(circle(0.45, [0.55, 0.0]), 0.8, 0.55),
                        ),
                        rectangle([0.0, 0.0], [0.55, 0.55]),
                    ),
                    0.7,
                    0.0,
                ),
                rectangle([0.0, 0.0], [0.1, 0.55]),
            ]),
        ),
        'S' => {
            let half = difference(
                ring(0.275, 0.175, [0.275, 0.725]),
                rectangle([0.275, 0.45], [0.55, 0.725]),
            );
            (
                0.55,
                union([half.clone(), reflect_x(reflect_y(half, 0.5), 0.275)]),
            )
        }
        's' => {
            let half = difference(
                circle(0.1625, [0.1625, 0.1625]),
                union([
                    scale_x(circle(0.0625, [0.165, 0.165]), 1.5, 0.165),
                    rectangle([0.0, 0.1625], [0.1625, 0.325]),
                ]),
            );
            (
                0.4875,
                scale_x(
                    union([half.clone(), reflect_x(reflect_y(half, 0.275), 0.1625)]),
                    1.5,
                    0.0,
                ),
            )
        }
        'T' => (
            0.6,
            union([
                rectangle([0.0, 0.9], [0.6, 1.0]),
                rectangle([0.25, 0.0], [0.35, 1.0]),
            ]),
        ),
        't' => (
            0.4,
            union([
                intersection(
                    ring(0.25, 0.15, [0.4, 0.25]),
                    rectangle([0.0, 0.0], [0.4, 0.25]),
                ),
                rectangle([0.0, 0.55], [0.4, 0.65]),
                rectangle([0.15, 0.25], [0.25, 1.0]),
            ]),
        ),
        'U' => (
            0.6,
            union([
                rectangle([0.0, 0.3], [0.1, 1.0]),
                rectangle([0.5, 0.3], [0.6, 1.0]),
                difference(
                    ring(0.3, 0.2, [0.3, 0.3]),
                    rectangle([0.0, 0.3], [0.6, 0.7]),
                ),
            ]),
        ),
        'u' => (
            0.55,
            union([
                intersection(
                    ring(0.275, 0.175, [0.275, 0.275]),
                    rectangle([0.0, 0.0], [0.55, 0.275]),
                ),
                rectangle([0.0, 0.275], [0.1, 0.55]),
                rectangle([0.45, 0.0], [0.55, 0.55]),
            ]),
        ),
        'V' => (0.6, upper_v()),
        'v' => (0.6, lower_v()),
        'W' => (1.1, union([upper_v(), shift(upper_v(), 0.5, 0.0)])),
        'w' => (1.1, union([lower_v(), shift(lower_v(), 0.5, 0.0)])),
        'X' => {
            let half = union([
                triangle([0.0, 1.0], [0.125, 1.0], [0.8, 0.0]),
                triangle([0.8, 0.0], [0.675, 0.0], [0.0, 1.0]),
            ]);
            (0.8, union([half.clone(), reflect_x(half, 0.4)]))
        }
        'x' => {
            let half = union([
                triangle([0.0, 0.55], [0.125, 0.55], [0.55, 0.0]),
                triangle([0.55, 0.0], [0.425, 0.0], [0.0, 0.55]),
            ]);
            (0.55, union([half.clone(), reflect_x(half, 0.275)]))
        }
        'Y' => (
            0.8,
            union([
                difference(
                    triangle([0.0, 1.0], [0.4, 0.5], [0.8, 1.0]),
                    triangle([0.1, 1.01], [0.4, 0.65], [0.7, 1.01]),
                ),
                rectangle([0.35, 0.0], [0.45, 0.6]),
            ]),
        ),
        'y' => {
            let half = union([
                triangle([0.0, 0.55], [0.1, 0.55], [0.325, 0.0]),
                triangle([0.325, 0.0], [0.225, 0.0], [0.0, 0.55]),
            ]);
            (
                0.55,
                union([
                    half.clone(),
                    reflect_x(half.clone(), 0.275),
                    shift(reflect_x(half, 0.275), -0.225, -0.55),
                ]),
            )
        }
        'Z' => (
            0.6,
            difference(
                rectangle([0.0, 0.0], [0.6, 1.0]),
                union([
                    triangle([0.0, 0.1], [0.0, 0.9], [0.45, 0.9]),
                    triangle([0.6, 0.1], [0.15, 0.1], [0.6, 0.9]),
                ]),
            ),
        ),
        'z' => (
            0.6,
            difference(
                rectangle([0.0, 0.0], [0.6, 0.55]),
                union([
                    triangle([0.0, 0.1], [0.0, 0.45], [0.45, 0.45]),
                    triangle([0.6, 0.1], [0.15, 0.1], [0.6, 0.45]),
                ]),
            ),
        ),
        ',' => (0.175, comma()),
        '.' => (0.175, circle(0.075, [0.075, 0.075])),
        '\'' => (0.1, rectangle([0.0, 0.55], [0.1, 0.8])),
        '"' => (
            0.3,
            union([
                rectangle([0.0, 0.55], [0.1, 0.8]),
                rectangle([0.2, 0.55], [0.3, 0.8]),
            ]),
        ),
        ':' => (
            0.15,
            union([circle(0.075, [0.075, 0.15]), circle(0.075, [0.075, 0.45])]),
        ),
        ';' => (
            0.15,
            union([shift(comma(), 0.0, 0.075), circle(0.075, [0.075, 0.45])]),
        ),
        '!' => (
            0.1,
            union([
                rectangle([0.025, 0.3], [0.125, 1.0]),
                circle(0.075, [0.075, 0.075]),
            ]),
        ),
        '-' => (0.45, rectangle([0.05, 0.4], [0.35, 0.5])),
        ')' => (0.3, rparen()),
        '(' => (0.3, reflect_x(rparen(), 0.15)),
        '[' => (0.3, lsquare()),
        ']' => (0.3, reflect_x(lsquare(), 0.15)),
        '>' => (0.55, rtri()),
        '<' => (0.55, reflect_x(rtri(), 0.275)),
        '°' => (0.4, ring(0.175, 0.075, [0.2, 0.8])),
        '#' => (
            0.55,
            shift(
                shear_x_y(
                    union([
                        rectangle([0.1, 0.05], [0.2, 0.75]),
                        rectangle([0.3, 0.05], [0.4, 0.75]),
                        rectangle([0.0, 0.25], [0.5, 0.35]),
                        rectangle([0.0, 0.45], [0.5, 0.55]),
                    ]),
                    [0.0, 0.0],
                    0.35,
                    0.1,
                    0.0,
                ),
                -0.05,
                0.0,
            ),
        ),
        '1' => (
            0.3,
            difference(
                rectangle([0.0, 0.0], [0.3, 1.0]),
                union([rectangle([0.0, 0.0], [0.2, 0.75]), circle(0.2, [0.0, 1.0])]),
            ),
        ),
        '2' => (
            0.55,
            union([
                difference(
                    ring(0.275, 0.175, [0.275, 0.725]),
                    rectangle([0.0, 0.0], [0.55, 0.725]),
                ),
                rectangle([0.0, 0.0], [0.55, 0.1]),
                triangle([0.0, 0.1], [0.45, 0.775], [0.55, 0.725]),
                triangle([0.0, 0.1], [0.55, 0.725], [0.125, 0.1]),
            ]),
        ),
        '3' => (
            0.55,
            difference(
                union([
                    ring(0.275, 0.175, [0.3, 0.725]),
                    ring(0.275, 0.175, [0.3, 0.225]),
                ]),
                rectangle([0.0, 0.275], [0.275, 0.725]),
            ),
        ),
        '4' => (
            0.5,
            intersection(
                union([
                    triangle([-0.10, 0.45], [0.4, 1.0], [0.4, 0.45]),
                    rectangle([0.4, 0.0], [0.5, 1.0]),
                ]),
                intersection(
                    inverse(triangle([0.4, 0.85], [0.4, 0.55], [0.1, 0.55])),
                    rectangle([0.0, 0.0], [0.5, 1.0]),
                ),
            ),
        ),
        '5' => (
            0.65,
            union([
                difference(
                    ring(0.325, 0.225, [0.325, 0.325]),
                    rectangle([0.0, 0.325], [0.325, 0.65]),
                ),
                rectangle([0.0, 0.55], [0.325, 0.65]),
                rectangle([0.0, 0.55], [0.1, 1.0]),
                rectangle([0.1, 0.9], [0.65, 1.0]),
            ]),
        ),
        '6' => (0.55, six()),
        '7' => (
            0.6,
            union([
                rectangle([0.0, 0.9], [0.6, 1.0]),
                triangle([0.0, 0.0], [0.475, 0.9], [0.6, 0.9]),
                triangle([0.0, 0.0], [0.6, 0.9], [0.125, 0.0]),
            ]),
        ),
        '8' => (
            0.55,
            union([
                ring(0.275, 0.175, [0.3, 0.725]),
                ring(0.275, 0.175, [0.3, 0.225]),
            ]),
        ),
        '9' => (0.55, reflect_x(reflect_y(six(), 0.5), 0.275)),
        '0' => (
            0.7,
            scale_x(
                difference(
                    circle(0.5, [0.5, 0.5]),
                    scale_x(circle(0.4, [0.5, 0.5]), 0.7f32.sqrt(), 0.5),
                ),
                0.7,
                0.0,
            ),
        ),
        '+' => (
            0.55,
            union([
                rectangle([0.0, 0.45], [0.5, 0.55]),
                rectangle([0.2, 0.25], [0.3, 0.75]),
            ]),
        ),
        '/' => (
            0.55,
            union([
                triangle([0.0, 0.0], [0.425, 1.0], [0.55, 1.0]),
                triangle([0.0, 0.0], [0.55, 1.0], [0.125, 0.0]),
            ]),
        ),
        _ => (0.55, question()),
    };
    (width, Some(shape))
}

fn lower_b() -> Tree {
    union([
        intersection(
            ring(0.275, 0.175, [0.275, 0.275]),
            rectangle([0.275, 0.0], [1.0, 1.0]),
        ),
        rectangle([0.1, 0.0], [0.275, 0.1]),
        rectangle([0.1, 0.45], [0.275, 0.55]),
        rectangle([0.0, 0.0], [0.1, 1.0]),
    ])
}

fn upper_p() -> Tree {
    union([
        difference(
            ring(0.275, 0.175, [0.3, 0.725]),
            rectangle([0.0, 0.0], [0.3, 1.0]),
        ),
        rectangle([0.0, 0.0], [0.1, 1.0]),
        rectangle([0.1, 0.45], [0.3, 0.55]),
        rectangle([0.1, 0.9], [0.3, 1.0]),
    ])
}

fn upper_v() -> Tree {
    let half = union([
        triangle([0.0, 1.0], [0.1, 1.0], [0.35, 0.0]),
        triangle([0.35, 0.0], [0.25, 0.0], [0.0, 1.0]),
    ]);
    union([half.clone(), reflect_x(half, 0.3)])
}

fn lower_v() -> Tree {
    let half = union([
        triangle([0.0, 0.55], [0.1, 0.55], [0.35, 0.0]),
        triangle([0.35, 0.0], [0.25, 0.0], [0.0, 0.55]),
    ]);
    union([half.clone(), reflect_x(half, 0.3)])
}

fn comma() -> Tree {
    union([
        circle(0.075, [0.1, 0.075]),
        intersection(
            scale_y(circle(0.075, [0.075, 0.075]), 3.0, 0.075),
            intersection(
                rectangle([0.0, -0.15], [0.15, 0.075]),
                inverse(triangle([0.1, 0.2], [0.0, -0.15], [-0.5, 0.075])),
            ),
        ),
    ])
}

fn rparen() -> Tree {
    scale_x(
        intersection(
            circle(0.6, [0.0, 0.5]),
            intersection(
                inverse(scale_x(circle(0.5, [0.0, 0.5]), 0.7, 0.0)),
                rectangle([0.0, 0.0], [0.6, 1.0]),
            ),
        ),
        0.5,
        0.0,
    )
}

fn lsquare() -> Tree {
    union([
        rectangle([0.0, 0.0], [0.1, 1.0]),
        rectangle([0.0, 0.0], [0.3, 0.07]),
        rectangle([0.0, 0.93], [0.3, 1.0]),
    ])
}

fn rtri() -> Tree {
    difference(
        rectangle([0.0, 0.0], [0.55, 0.55]),
        union([
            intersection(
                half_plane([0.4, 0.275], [0.0, 0.45]),
                half_plane([0.0, 0.1], [0.4, 0.275]),
            ),
            half_plane([0.0, 0.55], [0.55, 0.325]),
            half_plane([0.55, 0.225], [0.0, 0.0]),
        ]),
    )
}

fn six() -> Tree {
    let hook = intersection(
        intersection(
            circle(0.275, [0.275, 0.725]),
            inverse(scale_y(circle(0.175, [0.275, 0.725]), 1.2, 0.725)),
        ),
        intersection(
            rectangle([0.0, 0.725], [0.55, 1.0]),
            inverse(triangle([0.275, 0.925], [0.55, 0.9], [0.55, 0.525])),
        ),
    );
    union([
        ring(0.275, 0.175, [0.275, 0.275]),
        rectangle([0.0, 0.275], [0.1, 0.45]),
        difference(
            scale_x(scale_y(hook, 2.0, 1.0), 1.1, 0.0),
            rectangle([0.275, 0.65], [0.0, 0.7]),
        ),
    ])
}

fn question() -> Tree {
    union([
        difference(
            ring(0.275, 0.175, [0.275, 0.725]),
            rectangle([0.0, 0.45], [0.275, 0.725]),
        ),
        rectangle([0.225, 0.3], [0.325, 0.55]),
        circle(0.075, [0.275, 0.075]),
    ])
}
