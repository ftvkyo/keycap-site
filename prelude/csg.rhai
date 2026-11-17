// SPDX-License-Identifier: MPL-2.0 AND MIT
//
// keycap prelude: offsets and combinations with fillets and chamfers.
//
// kind: csg
//
// fidget's own `union`, `intersection`, `difference`, `inverse` and `blend`
// are the sharp and smooth basics; these add what printed parts need.
//
// The rounded and chamfered combinations are hg_sdf's `fOpUnionRound`,
// `fOpIntersectionRound`, `fOpUnionChamfer` and `fOpIntersectionChamfer`,
// taken to any number of shapes.  hg_sdf (https://mercury.sexy/hg_sdf/)
// is under the MIT License:
//
// Copyright (c) 2011-2021 Mercury Demogroup
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// --- Offsets ---

/// offset(shape: Shape, d: Tree): Shape
///
/// Grows a shape by `d` in every direction, or shrinks it by a negative `d`.
///
/// - `shape`: the shape
/// - `d`: the distance, which may vary over space
///
/// Growing rounds the convex corners with radius `d`.
/// Shrinking rounds the concave ones.
///
/// Notes:
/// - Field: as `shape`'s; the surface moves exactly `d` where that is exact.
/// - On a bound, such as fidget's `box` or `rectangle`, the corners move further than `d` and stay sharp.
/// - A `d` that varies over space makes the field steeper or flatter than a distance, by up to how fast `d` changes.
///
/// See also: `shell`, `clearance`.
///
/// Example: a 20 mm square grown by 2 mm, its corners rounded.
/// ```
/// offset(rect(20), 2)
/// ```
fn offset(shape, d) {
    _tree(shape) - d
}

/// shell(shape: Shape, t: Tree): Shape
///
/// Hollows a shape, keeping a wall of thickness `t` inside its surface.
///
/// - `shape`: the shape
/// - `t`: the wall's thickness, which may vary over space
///
/// The outer surface stays where it is.
/// The inner one is that of `offset(shape, -t)`.
/// The shell is closed; cut it to open it.
///
/// Notes:
/// - Field: exact where `shape`'s is.
/// - On a bound, the wall can come out thicker than `t`.
/// - On a field steeper than a distance, such as `union_round`'s, the wall comes out thinner, down to `t` divided by the field's slope.
///
/// See also: `offset`.
///
/// Example: the lower half of an enclosure, a rounded box with 2 mm walls, open at the top.
/// ```
/// cuboid([40, 30, 20], #{round: 3})
///     .shell(2)
///     .intersection(z - 6)
/// ```
fn shell(shape, t) {
    let h = _field(t, "shell: t") * 0.5;
    abs(_tree(shape) + h) - h
}

/// clearance(shape: Shape, tool: Shape, gap: Tree): Shape
///
/// Cuts `tool` out of `shape` with a gap all around it, for parts that slide or press into each other.
///
/// - `shape`: the shape to cut
/// - `tool`: the part that goes into the cut
/// - `gap`: the gap on each side, which may vary over space; about 0.2 mm for a sliding fit and 0.1 mm for a press fit, on most printers
///
/// It is `difference(shape, offset(tool, gap))`.
/// Where `tool`'s field is exact, the gap is even all around, edges included.
///
/// Notes:
/// - Field: a bound at the edges the cut leaves, as `difference` leaves it; elsewhere exact where `shape`'s and `tool`'s are.
///
/// See also: `offset`, `difference_round`, `difference_chamfer`.
///
/// Example: a block with a hole for an 8 mm peg, 0.2 mm wider all round.
/// ```
/// let peg = cylinder(4, 20);
/// cuboid([20, 20, 10]).clearance(peg, 0.2)
/// ```
fn clearance(shape, tool, gap) {
    difference(shape, _tree(tool) - gap)
}

// --- Rounded and chamfered combinations ---

// Each takes any number of shapes: the round ones measure a point's
// distance to the corner from every shape it is within `r` of, the chamfers
// from the two nearest.  A radius that varies goes through `_vary` once,
// around the whole combination.

/// union_round(a: Shape | Shape[], shapes: Shape | Shape[], r: Tree, opts: #{ normalize?: bool } = #{}): Shape
/// union_round(shapes: Shape[], r: Tree, opts: #{ normalize?: bool } = #{}): Shape
///
/// Union of shapes with a fillet of radius `r` wherever they meet.
///
/// - `a`: a shape, or an array of them
/// - `shapes`: the shapes to join to `a`: one, or an array of any number
/// - `r`: the fillet's radius, which may vary over space
/// - `opts`:
///   - `normalize`: `false` skips the correction of a varying radius: twice as fast, but offsets and shells of a varying rounding come out uneven
///
/// Every joint between two of the shapes gets a fillet.
/// Where three shapes meet, the corner is filled as a ball of radius `r` rolled along it would leave it.
/// Elsewhere the shapes stay as they are.
///
/// A radius that varies over space is corrected for, so the field stays as exact as with a fixed radius, to first order.
/// Where the radius fades to 0, the joint is sharp.
///
/// Notes:
/// - Field: exact where the surfaces meet at right angles; steeper than a distance where they meet at more than a right angle, with a slope of up to sqrt 2 (sqrt 3 where three meet); a bound where they meet at less.
/// - About 5 operations a shape; a varying radius evaluates the shapes twice.
/// - Two surfaces that run side by side within `r` of each other bulge out between them, as two boxes on one face do along their seam.
///   Join such parts with `union` first.
///
/// See also: `union_chamfer`, `smooth_union`, `intersection_round`, `difference_round`.
///
/// References:
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/): `fOpUnionRound`, here for any number of shapes
/// - [Fillet (mechanics), Wikipedia](https://en.wikipedia.org/wiki/Fillet_%28mechanics%29)
///
/// From OpenSCAD: in 2D, `offset(-r) offset(r)` of the union fillets its joints the same way, and the shapes' own concave corners too.
///
/// Example: a plate with a post and a rib, every joint filleted by 2 mm.
/// ```
/// let base = cuboid([40, 40, 4]);
/// let post = cylinder(5, [0, 20]);
/// let rib = cuboid([30, 3, 12], #{anchor: "bottom"});
/// union_round([base, post, rib], 2)
/// ```
fn union_round(a, shapes, r, opts) {
    _opts(opts, ["normalize"], "union_round");
    let parts = _shapes(a) + _shapes(shapes);
    let r = _field(r, "union_round: r");
    _vary(|r| _round_union(parts, r), r, opts)
}

// `a.union_round(shapes, r, opts)`, `union_round(shapes, r, opts)` and
// `union_round(a, shapes, r)`, which Rhai cannot tell apart by their number
// of arguments: only a method call binds `this`.
fn union_round(shapes, r, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("union_round", a, shapes, r, opts)
}

// `a.union_round(shapes, r)` and `union_round(shapes, r)`.
fn union_round(shapes, r) {
    let a = ();
    try { a = this; } catch { }
    _combination("union_round", a, shapes, r, #{})
}

/// intersection_round(a: Shape, shapes: Shape | Shape[], r: Tree, opts: #{ normalize?: bool } = #{}): Shape
/// intersection_round(shapes: Shape[], r: Tree, opts: #{ normalize?: bool } = #{}): Shape
///
/// Intersection of shapes, the edges where they meet rounded with radius `r`.
///
/// - `a`: a shape
/// - `shapes`: the shapes to intersect with `a`: one, or an array of any number
/// - `r`: the edges' radius, which may vary over space
/// - `opts`:
///   - `normalize`: `false` skips the correction of a varying radius: twice as fast, but offsets and shells of a varying rounding come out uneven
///
/// Every edge where the surfaces of two of the shapes meet is rounded.
/// A corner where three meet becomes part of a ball of radius `r`.
/// The shapes' own edges stay as they are.
///
/// A radius that varies over space is corrected for, as in `union_round`.
/// Where the radius fades to 0, the edge is sharp.
///
/// Notes:
/// - Field: exact where the surfaces meet at right angles; steeper than a distance where they meet at more than a right angle, with a slope of up to sqrt 2 (sqrt 3 where three meet); a bound where they meet at less.
/// - About 5 operations a shape; a varying radius evaluates the shapes twice.
/// - An array is the shapes to intersect, not their union, unlike in most functions that take shapes.
///
/// See also: `intersection_chamfer`, `smooth_intersection`, `union_round`.
///
/// References:
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/): `fOpIntersectionRound`, here for any number of shapes
///
/// Example: a knob's disc with a flat on one side, every edge rounded by 2 mm.
/// ```
/// let post = cylinder(15, 40);
/// intersection_round([post, x - 10, slab(8)], 2)
/// ```
fn intersection_round(a, shapes, r, opts) {
    _opts(opts, ["normalize"], "intersection_round");
    let parts = [_tree(a)] + _shapes(shapes);
    let r = _field(r, "intersection_round: r");
    _sharp_bound(_vary(|r| _round_intersection(parts, r), r, opts), parts)
}

// The shorter forms, as for `union_round`.
fn intersection_round(shapes, r, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("intersection_round", a, shapes, r, opts)
}

fn intersection_round(shapes, r) {
    let a = ();
    try { a = this; } catch { }
    _combination("intersection_round", a, shapes, r, #{})
}

/// difference_round(body: Shape, cutters: Shape | Shape[], r: Tree, opts: #{ normalize?: bool } = #{}): Shape
///
/// Cuts `cutters` out of `body`, the edges the cuts leave rounded with radius `r`.
///
/// - `body`: the shape to cut
/// - `cutters`: one shape, or an array of any number
/// - `r`: the edges' radius, which may vary over space
/// - `opts`:
///   - `normalize`: `false` skips the correction of a varying radius: twice as fast, but offsets and shells of a varying rounding come out uneven
///
/// The rim of every cut is rounded.
/// So is an edge where two cutters meet inside the body, as where two grooves cross.
/// A screw hole through a plate gets a rounded rim, a groove rounded lips.
///
/// A radius that varies over space is corrected for, as in `union_round`.
///
/// Notes:
/// - Field: exact where the surfaces meet at right angles; steeper than a distance where they meet at more than a right angle, with a slope of up to sqrt 2 (sqrt 3 where three meet); a bound where they meet at less.
/// - A cut that only touches the body's surface leaves a cusp, with no edge to round.
///   `smooth_difference` rounds it.
///
/// See also: `difference_chamfer`, `smooth_difference`, `clearance`.
///
/// References:
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/): `fOpIntersectionRound`, with the cutters turned inside out
///
/// Example: a plate with two crossing grooves, the edges they leave rounded by 1 mm.
/// ```
/// let plate = cuboid([30, 30, 6]);
/// let slot_x = cuboid([40, 4, 6]).move([0, 0, 3]);
/// let slot_y = cuboid([4, 40, 6]).move([0, 0, 3]);
/// plate.difference_round([slot_x, slot_y], 1)
/// ```
fn difference_round(body, cutters, r, opts) {
    _opts(opts, ["normalize"], "difference_round");
    let parts = [_tree(body)] + _shapes(cutters).map(|v| -v);
    let r = _field(r, "difference_round: r");
    _sharp_bound(_vary(|r| _round_intersection(parts, r), r, opts), parts)
}

// `body.difference_round(cutters, r, opts)` and
// `difference_round(body, cutters, r)`.
fn difference_round(cutters, r, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("difference_round", a, cutters, r, opts)
}

/// union_chamfer(a: Shape | Shape[], shapes: Shape | Shape[], c: Tree, opts: #{ normalize?: bool } = #{}): Shape
/// union_chamfer(shapes: Shape[], c: Tree, opts: #{ normalize?: bool } = #{}): Shape
///
/// Union of shapes with a 45-degree chamfer wherever they meet.
///
/// - `a`: a shape, or an array of them
/// - `shapes`: the shapes to join to `a`: one, or an array of any number
/// - `c`: the chamfer's size, which may vary over space
/// - `opts`:
///   - `normalize`: `false` skips the correction of a varying size: twice as fast, but offsets and shells of a varying chamfer come out uneven
///
/// Where two surfaces meet at right angles, the chamfer's legs are `c` long on each.
/// Where three shapes meet, each point takes the chamfer between the two nearest.
/// A size that varies over space is corrected for, as in `union_round`.
///
/// Notes:
/// - Field: exact where the surfaces meet at right angles; steeper than a distance where they meet at more than a right angle, with a slope of up to sqrt 2; a bound where they meet at less.
/// - About 6 operations a shape; a varying size evaluates the shapes twice.
///
/// See also: `union_round`, `intersection_chamfer`, `difference_chamfer`.
///
/// References:
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/): `fOpUnionChamfer`, here for any number of shapes
/// - [Chamfer, Wikipedia](https://en.wikipedia.org/wiki/Chamfer)
///
/// Example: a plate with a post, chamfered into it by 2 mm.
/// ```
/// cuboid([40, 40, 4])
///     .union_chamfer(cylinder(5, [0, 20]), 2)
/// ```
fn union_chamfer(a, shapes, c, opts) {
    _opts(opts, ["normalize"], "union_chamfer");
    let parts = _shapes(a) + _shapes(shapes);
    let c = _field(c, "union_chamfer: c");
    _vary(|c| _chamfer_union(parts, c), c, opts)
}

// The shorter forms, as for `union_round`.
fn union_chamfer(shapes, c, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("union_chamfer", a, shapes, c, opts)
}

fn union_chamfer(shapes, c) {
    let a = ();
    try { a = this; } catch { }
    _combination("union_chamfer", a, shapes, c, #{})
}

/// intersection_chamfer(a: Shape, shapes: Shape | Shape[], c: Tree, opts: #{ normalize?: bool } = #{}): Shape
/// intersection_chamfer(shapes: Shape[], c: Tree, opts: #{ normalize?: bool } = #{}): Shape
///
/// Intersection of shapes, the edges where they meet chamfered.
///
/// - `a`: a shape
/// - `shapes`: the shapes to intersect with `a`: one, or an array of any number
/// - `c`: the chamfer's size, which may vary over space
/// - `opts`:
///   - `normalize`: `false` skips the correction of a varying size: twice as fast, but offsets and shells of a varying chamfer come out uneven
///
/// Where two surfaces meet at right angles, the chamfer's legs are `c` long on each.
/// Where three shapes meet, each point takes the chamfer between the two nearest.
/// A size that varies over space is corrected for, as in `union_round`.
///
/// Notes:
/// - Field: exact where the surfaces meet at right angles; steeper than a distance where they meet at more than a right angle, with a slope of up to sqrt 2; a bound where they meet at less.
/// - An array is the shapes to intersect, not their union, unlike in most functions that take shapes.
///
/// See also: `intersection_round`, `union_chamfer`, `difference_chamfer`.
///
/// References:
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/): `fOpIntersectionChamfer`, here for any number of shapes
///
/// Example: a hexagonal prism cut to 8 mm, the rims of the cut chamfered by 1 mm.
/// ```
/// cylinder(10, 30, #{sides: 6})
///     .intersection_chamfer(slab(8), 1)
/// ```
fn intersection_chamfer(a, shapes, c, opts) {
    _opts(opts, ["normalize"], "intersection_chamfer");
    let parts = [_tree(a)] + _shapes(shapes);
    let c = _field(c, "intersection_chamfer: c");
    _vary(|c| _chamfer_intersection(parts, c), c, opts)
}

// The shorter forms, as for `union_round`.
fn intersection_chamfer(shapes, c, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("intersection_chamfer", a, shapes, c, opts)
}

fn intersection_chamfer(shapes, c) {
    let a = ();
    try { a = this; } catch { }
    _combination("intersection_chamfer", a, shapes, c, #{})
}

/// difference_chamfer(body: Shape, cutters: Shape | Shape[], c: Tree, opts: #{ normalize?: bool } = #{}): Shape
///
/// Cuts `cutters` out of `body`, the edges the cuts leave chamfered.
///
/// - `body`: the shape to cut
/// - `cutters`: one shape, or an array of any number
/// - `c`: the chamfer's size, which may vary over space
/// - `opts`:
///   - `normalize`: `false` skips the correction of a varying size: twice as fast, but offsets and shells of a varying chamfer come out uneven
///
/// Where two surfaces meet at right angles, the chamfer's legs are `c` long on each.
/// A cylinder cut this way through a plate leaves a 90-degree countersink on both faces.
/// A size that varies over space is corrected for, as in `union_round`.
///
/// Notes:
/// - Field: exact where the surfaces meet at right angles; steeper than a distance where they meet at more than a right angle, with a slope of up to sqrt 2; a bound where they meet at less.
///
/// See also: `difference_round`, `clearance`.
///
/// References:
/// - Mercury, [hg_sdf](https://mercury.sexy/hg_sdf/): `fOpIntersectionChamfer`, with the cutters turned inside out
/// - [Countersink, Wikipedia](https://en.wikipedia.org/wiki/Countersink)
///
/// Example: a plate with a hole, countersunk by 1 mm on both faces.
/// ```
/// cuboid([30, 30, 5])
///     .difference_chamfer(cylinder(3, 10), 1)
/// ```
fn difference_chamfer(body, cutters, c, opts) {
    _opts(opts, ["normalize"], "difference_chamfer");
    let parts = [_tree(body)] + _shapes(cutters).map(|v| -v);
    let c = _field(c, "difference_chamfer: c");
    _vary(|c| _chamfer_intersection(parts, c), c, opts)
}

// `body.difference_chamfer(cutters, c, opts)` and
// `difference_chamfer(body, cutters, c)`.
fn difference_chamfer(cutters, c, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("difference_chamfer", a, cutters, c, opts)
}

// The full call of the combination `name`, from one of its shorter forms:
// `a.name(shapes, r, opts)`, with `a` the receiver, `name(shapes, r, opts)`
// on an array, its first shape the `a`, or `name(a, shapes, r)`, whose
// last argument is no map of options.  A form of two arguments comes with
// `#{}` for `opts`.
fn _combination(name, a, shapes, r, opts) {
    let full = Fn(name);
    if type_of(a) != "()" {
        full.call(a, shapes, r, opts)
    } else if type_of(opts) == "map" {
        let s = _shapes(shapes);
        full.call(s[0], s.extract(1), r, opts)
    } else {
        full.call(shapes, r, opts, #{})
    }
}

// A shape or an array of them as an array of trees, for the combinations
// of any number of shapes.
fn _shapes(v) {
    if type_of(v) == "array" { v.map(|s| _tree(s)) } else { [v] }
}

// A rounded intersection `f` of `parts`, bounded by their sharp
// intersection, which it never goes below: `max` with it changes no value
// but lets interval arithmetic see where the shape ends, which the
// rounding's square root hides.
fn _sharp_bound(f, parts) {
    max(f, if parts.len() == 1 { parts[0] } else { intersection(parts) })
}

// hg_sdf's fillet for any number of shapes: the distance to the corner
// region, inside every shape's offset by `r`, as the length of the vector
// of how far each shape is within `r`.  A shape further than `r` adds 0.
fn _round_union(parts, r) {
    let m = parts[0];
    let ss = square(max(r - parts[0], 0.0));
    for p in parts.extract(1) {
        m = min(m, p);
        ss += square(max(r - p, 0.0));
    }
    max(r, m) - _sqrt(ss)
}

// The same, the other way round: the edges of an intersection.
fn _round_intersection(parts, r) {
    let m = parts[0];
    let ss = square(max(r + parts[0], 0.0));
    for p in parts.extract(1) {
        m = max(m, p);
        ss += square(max(r + p, 0.0));
    }
    min(-r, m) + _sqrt(ss)
}

// hg_sdf's chamfer between the two smallest fields, kept as the shapes
// come: the second smallest is the smaller of what it was and the larger
// of the smallest and the new shape.
fn _chamfer_union(parts, c) {
    if parts.len() == 1 {
        return parts[0];
    }
    let low = min(parts[0], parts[1]);
    let next = max(parts[0], parts[1]);
    for p in parts.extract(2) {
        next = min(next, max(low, p));
        low = min(low, p);
    }
    min(low, (low + next - c) / SQRT_2)
}

// The same with the two largest: the edges of an intersection.
fn _chamfer_intersection(parts, c) {
    if parts.len() == 1 {
        return parts[0];
    }
    let high = max(parts[0], parts[1]);
    let next = min(parts[0], parts[1]);
    for p in parts.extract(2) {
        next = max(next, min(high, p));
        high = max(high, p);
    }
    max(high, (high + next + c) / SQRT_2)
}

// --- Smooth combinations ---

/// smooth_union(a: Shape | Shape[], shapes: Shape | Shape[], k: Tree, opts: #{ kind?: Smooth, normalize?: bool } = #{}): Shape
/// smooth_union(shapes: Shape[], k: Tree, opts: #{ kind?: Smooth, normalize?: bool } = #{}): Shape
/// type Smooth = "quadratic" | "cubic" | "circular" | "exponential"
///
/// Union of shapes blended into each other where they come within `k`.
///
/// - `a`: a shape, or an array of them
/// - `shapes`: the shapes to blend into `a`: one, or an array of any number
/// - `k`: the blend's width, which may vary over space; 0 is a sharp union
/// - `opts`:
///   - `kind`: the blend's profile, by how far it lowers the field where the two fields are equal:
///     - `"quadratic"`: by `k / 4`; fidget's `blend`, and the default
///     - `"cubic"`: by `k / 6`, keeping the curvature continuous too
///     - `"circular"`: by 0.29 `k`; between surfaces that meet at right angles, an arc of radius `k`, as `union_round` makes
///     - `"exponential"`: by `k / 4`, and a little everywhere else, so no surface stays quite where it was
///   - `normalize`: `false` skips the correction of a varying width: twice as fast, but offsets and shells of a varying blend come out uneven
///
/// Where two surfaces meet at right angles, the blend reaches `k` along each.
/// It fills most where the two fields are equal.
/// The shapes blend in order, each into the blend of those before it.
/// A width that varies over space is corrected for, as in `union_round`.
///
/// Notes:
/// - Field: a bound where the shapes' fields are exact or bounds, whether `k` varies or not.
/// - About 10 operations a shape; a varying width evaluates the shapes twice.
///
/// See also: `union_round`, `smooth_intersection`, `smooth_difference`.
///
/// References:
/// - Inigo Quilez, [Smooth minimum](https://iquilezles.org/articles/smin/)
///
/// Example: a plate with a post, blended over 6 mm.
/// ```
/// cuboid([40, 40, 4])
///     .smooth_union(cylinder(5, [0, 20]), 6)
/// ```
fn smooth_union(a, shapes, k, opts) {
    _opts(opts, ["kind", "normalize"], "smooth_union");
    let parts = _shapes(a) + _shapes(shapes);
    let kind = _smooth_kind(opts, "smooth_union");
    let k = _field(k, "smooth_union: k");
    _vary(|k| _smin(parts, k, kind), k, opts)
}

// The shorter forms, as for `union_round`.
fn smooth_union(shapes, k, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("smooth_union", a, shapes, k, opts)
}

fn smooth_union(shapes, k) {
    let a = ();
    try { a = this; } catch { }
    _combination("smooth_union", a, shapes, k, #{})
}

/// smooth_intersection(a: Shape, shapes: Shape | Shape[], k: Tree, opts: #{ kind?: Smooth, normalize?: bool } = #{}): Shape
/// smooth_intersection(shapes: Shape[], k: Tree, opts: #{ kind?: Smooth, normalize?: bool } = #{}): Shape
/// type Smooth = "quadratic" | "cubic" | "circular" | "exponential"
///
/// Intersection of shapes, the edges where they meet blended over `k`.
///
/// - `a`: a shape
/// - `shapes`: the shapes to intersect with `a`: one, or an array of any number
/// - `k`: the blend's width, which may vary over space; 0 is a sharp intersection
/// - `opts`:
///   - `kind`: the blend's profile, as for `smooth_union`
///   - `normalize`: `false` skips the correction of a varying width: twice as fast, but offsets and shells of a varying blend come out uneven
///
/// The edges are rounded off as `smooth_union` fills joints.
/// Where two surfaces meet at right angles, the blend reaches `k` along each.
///
/// Notes:
/// - Field: a bound where the shapes' fields are exact or bounds.
/// - An array is the shapes to intersect, not their union, unlike in most functions that take shapes.
///
/// See also: `intersection_round`, `smooth_union`, `smooth_difference`.
///
/// References:
/// - Inigo Quilez, [Smooth minimum](https://iquilezles.org/articles/smin/)
///
/// Example: a cylinder and a box, the edges where they meet blended over 3 mm.
/// ```
/// smooth_intersection(
///     cylinder(10, 20),
///     cuboid([15, 15, 30]),
///     3
/// )
/// ```
fn smooth_intersection(a, shapes, k, opts) {
    _opts(opts, ["kind", "normalize"], "smooth_intersection");
    let parts = ([_tree(a)] + _shapes(shapes)).map(|v| -v);
    let kind = _smooth_kind(opts, "smooth_intersection");
    let k = _field(k, "smooth_intersection: k");
    _sharp_bound(_vary(|k| -_smin(parts, k, kind), k, opts), parts.map(|v| -v))
}

// The shorter forms, as for `union_round`.
fn smooth_intersection(shapes, k, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("smooth_intersection", a, shapes, k, opts)
}

fn smooth_intersection(shapes, k) {
    let a = ();
    try { a = this; } catch { }
    _combination("smooth_intersection", a, shapes, k, #{})
}

/// smooth_difference(body: Shape, cutters: Shape | Shape[], k: Tree, opts: #{ kind?: Smooth, normalize?: bool } = #{}): Shape
/// type Smooth = "quadratic" | "cubic" | "circular" | "exponential"
///
/// Cuts `cutters` out of `body`, the edges the cuts leave blended over `k`.
///
/// - `body`: the shape to cut
/// - `cutters`: one shape, or an array of any number
/// - `k`: the blend's width, which may vary over space; 0 is a sharp cut
/// - `opts`:
///   - `kind`: the blend's profile, as for `smooth_union`
///   - `normalize`: `false` skips the correction of a varying width: twice as fast, but offsets and shells of a varying blend come out uneven
///
/// The cutters are blended into each other first, so an edge between two of them is rounded off too.
/// A cusp, where a cut only touches the body's surface, is rounded as well.
/// Slivers thinner than about `k` between surfaces that run close together are eaten away.
///
/// With `k` twice a radius `r`, the result comes within about `r / 3` of the difference's morphological opening by a ball of radius `r`, cusps included.
///
/// Notes:
/// - Field: a bound where the shapes' fields are exact or bounds.
///
/// See also: `difference_round`, `smooth_union`, `smooth_intersection`.
///
/// References:
/// - Inigo Quilez, [Smooth minimum](https://iquilezles.org/articles/smin/)
/// - [Opening (morphology), Wikipedia](https://en.wikipedia.org/wiki/Opening_%28morphology%29)
///
/// From OpenSCAD: `offset(r) offset(-r)` of a 2D difference is close to `smooth_difference` with `k = 2 * r`.
///
/// Example: a block with a groove, its lips blended over 4 mm.
/// ```
/// let plate = cuboid([30, 30, 10]);
/// let bore = cylinder(4, 40).rotate_x(90).move([0, 0, 5]);
/// plate.smooth_difference(bore, 4)
/// ```
fn smooth_difference(body, cutters, k, opts) {
    _opts(opts, ["kind", "normalize"], "smooth_difference");
    let parts = _shapes(cutters);
    let body = _tree(body);
    let kind = _smooth_kind(opts, "smooth_difference");
    let k = _field(k, "smooth_difference: k");
    let sharp = [body] + parts.map(|v| -v);
    _sharp_bound(_vary(|k| -_smin([-body, _smin(parts, k, kind)], k, kind), k, opts), sharp)
}

// `body.smooth_difference(cutters, k, opts)` and
// `smooth_difference(body, cutters, k)`.
fn smooth_difference(cutters, k, opts) {
    let a = ();
    try { a = this; } catch { }
    _combination("smooth_difference", a, cutters, k, opts)
}

// The `kind` option, checked.
fn _smooth_kind(opts, what) {
    let kind = _opt(opts, "kind", "quadratic");
    if !["quadratic", "cubic", "circular", "exponential"].contains(kind) {
        throw `${what}: unknown kind ${kind}; known: quadratic, cubic, circular, exponential`;
    }
    kind
}

// Quilez's smooth minimum of `parts` over a width `k`, each part blended
// into the blend of those before it.  A width of 0 is the plain minimum;
// one that varies over space is kept off 0 below the divisions.
fn _smin(parts, k, kind) {
    let sharp = _is_number(k) && k <= 0.0;
    let w = if _is_number(k) { k } else { max(k, 1e-6) };
    let out = parts[0];
    for p in parts.extract(1) {
        let m = min(out, p);
        if sharp {
            out = m;
            continue;
        }
        // How far the two fields are within `w` of each other, from 0 to 1;
        // `min` keeps it so as an interval too, where `w` varies.
        let h = min(max(w - abs(out - p), 0.0) / w, 1.0);
        out = switch kind {
            "quadratic" => m - square(h) * w * 0.25,
            "cubic" => m - h * h * h * w / 6.0,
            "circular" => m - w * 0.5 * (1.0 + h - sqrt(1.0 + h * (2.0 - h))),
            // -s ln(e^(-a/s) + e^(-b/s)), which lowers the field by s ln 2
            // where a = b; written from the minimum, so that no power
            // overflows.
            _ => {
                let s = w * 0.25 / LN_2;
                m - s * ln(exp((m - out) / s) + exp((m - p) / s))
            }
        };
    }
    out
}

// --- Engraving ---

/// engrave(part: Shape, cutter: Shape, outside: Shape, depth: Tree): Shape
///
/// Cuts `cutter` into `part` to `depth` below a surface: a legend or a groove that follows a curved face.
///
/// - `part`: the solid to engrave
/// - `cutter`: what to cut, such as text or an outline extruded through the surface
/// - `outside`: the space beyond the surface the engraving follows
/// - `depth`: how deep, which may vary over space
///
/// Only the part of `cutter` within `depth` of `outside` is cut.
/// So the engraving's floor runs parallel to the surface however it curves, and `cutter` only has to reach through it.
///
/// For the part's own surface, `outside` is `-part`.
/// For a face a cut made, such as a dish, it is the cutter that made it.
///
/// Notes:
/// - Field: exact where those of `part` and `cutter` are, and a bound at the engraving's edges, as `difference` leaves it.
/// - The floor is `depth` deep where `outside`'s field is exact, and shallower where it is a bound.
///
/// See also: `difference`, `clearance`.
///
/// Example: a groove in a keycap's dish, its floor 0.5 mm below the dish.
/// ```
/// let dish = sphere(40).move([0, 0, 43]);
/// let cap = cuboid([18, 18, 8]).difference(dish);
/// cap.engrave(rect([10, 1.5]).extrude([0, 10]), dish, 0.5)
/// ```
fn engrave(part, cutter, outside, depth) {
    let d = _field(depth, "engrave: depth");
    max(_tree(part), -max(_tree(cutter), _tree(outside) - d))
}

// --- Method forms ---

// Rhai calls a script function as a method only through `this`, so each
// function above whose first argument is a shape gets a twin for
// `shape.f(...)`; the combinations above that also take an array serve
// both forms in one function.

fn offset(d) { offset(this, d) }
fn shell(t) { shell(this, t) }
fn clearance(tool, gap) { clearance(this, tool, gap) }
fn difference_round(cutters, r) { difference_round(this, cutters, r, #{}) }
fn difference_chamfer(cutters, c) { difference_chamfer(this, cutters, c, #{}) }
fn smooth_difference(cutters, k) { smooth_difference(this, cutters, k, #{}) }
fn engrave(cutter, outside, depth) { engrave(this, cutter, outside, depth) }
