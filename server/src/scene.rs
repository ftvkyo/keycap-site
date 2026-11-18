// SPDX-License-Identifier: MPL-2.0

//! The loaded scene: what the script drew, its bounds, and its shapes
//! compiled for evaluation, on demand and once.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use fidget::context::{Context, Tree};
use fidget::jit::JitShape;
use fidget::shape::BoundShape;

use crate::bounds::{self, Box3, Fitted};
use crate::camera::Tilt;
use crate::protocol::{Axis, BoundsChoice, Slice};
use crate::script::{Drawn, Role};

/// Shapes with no colour of their own are drawn in this one, so that a
/// scene without colours shades as plain fidget does.
pub const DEFAULT_COLOR: [f32; 3] = [1.0, 1.0, 1.0];

/// How the shapes are looked at.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Orientation {
    /// In 3D or as a mesh, cut to the region of these bounds, so that a
    /// view shows what an export holds and unbounded shapes end
    Solid(BoundsChoice),
    /// Sliced, turned so that the plane normal to the axis lies in xy
    Slice(Axis),
    /// Sliced as `Slice`, then turned so that the tilted plane lies in xy
    Tilted(Axis, Tilt),
}

impl Orientation {
    /// How `slice` of `region` looks at the shapes.
    pub fn of(slice: &Slice, region: &Box3) -> Orientation {
        match Tilt::of(slice, region) {
            Some(tilt) => Orientation::Tilted(slice.axis, tilt),
            None => Orientation::Slice(slice.axis),
        }
    }

    /// The slot of `Scene::compiled` that keeps it; tilted ones have none.
    fn index(self) -> Option<usize> {
        match self {
            Orientation::Solid(BoundsChoice::Script) => Some(0),
            Orientation::Solid(BoundsChoice::Fitted) => Some(1),
            Orientation::Slice(axis) => Some(2 + axis.index()),
            Orientation::Tilted(..) => None,
        }
    }
}

pub struct Scene {
    /// Tells scenes apart for caches that outlive them
    pub id: u64,
    pub drawn: Vec<Drawn>,
    pub bounds: Option<Box3>,
    pub resolution: Option<f64>,
    /// Fitted to the union of the drawn shapes, unpadded
    pub fitted: Option<Fitted>,
    /// The union of the drawn shapes
    pub union: Tree,
    compiled: [OnceLock<Arc<Compiled>>; 5],
    /// The last tilt compiled: a tilt changes with every step, so only the
    /// one shown is kept
    tilted: Mutex<Option<(Orientation, Arc<Compiled>)>>,
}

/// The shapes of one orientation, compiled
pub struct Compiled {
    pub union: JitShape,
    each: OnceLock<Result<Vec<JitShape>, String>>,
    trees: Vec<Tree>,
}

impl Compiled {
    /// Each drawn shape, for scenes with colours
    pub fn each(&self) -> Result<&[JitShape], String> {
        self.each
            .get_or_init(|| self.trees.iter().map(jit).collect())
            .as_deref()
            .map_err(Clone::clone)
    }
}

pub fn jit(tree: &Tree) -> Result<JitShape, String> {
    let mut context = Context::new();
    let node = context.import(tree);
    JitShape::new(&context, node).map_err(|error| error.to_string())
}

/// `shape` with no free variables to bind, as the renderers take it
pub fn bound<F: fidget::eval::Function>(
    shape: fidget::shape::Shape<F>,
) -> Result<BoundShape<'static, F, f32>, String> {
    BoundShape::try_from(shape).map_err(|error| error.to_string())
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

impl Scene {
    pub fn new(
        drawn: Vec<Drawn>,
        bounds: Option<Box3>,
        resolution: Option<f64>,
    ) -> Result<Self, String> {
        let union = union(drawn.iter().map(|d| d.tree.clone()).collect());
        let scene = Scene {
            id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
            drawn,
            bounds,
            resolution,
            fitted: None,
            union,
            compiled: Default::default(),
            tilted: Mutex::new(None),
        };
        let fitted = if scene.drawn.is_empty() {
            None
        } else {
            bounds::fit(
                &scene.union,
                &scene.compiled(Orientation::Slice(Axis::Z))?.union,
            )
        };
        Ok(Scene { fitted, ..scene })
    }

    pub fn has_colors(&self) -> bool {
        self.drawn.iter().any(|d| d.color.is_some())
    }

    /// Whether a shape is drawn to be scored or engraved rather than cut.
    pub fn has_roles(&self) -> bool {
        self.drawn.iter().any(|d| d.role != Role::Cut)
    }

    pub fn colors(&self) -> Vec<[f32; 3]> {
        self.drawn
            .iter()
            .map(|d| d.color.unwrap_or(DEFAULT_COLOR))
            .collect()
    }

    /// The region to show or export for `choice`, and the bounds it came
    /// from.
    pub fn region(&self, choice: BoundsChoice) -> (Box3, BoundsChoice) {
        bounds::region(choice, self.bounds, self.fitted)
    }

    /// `tree` as `orientation` looks at it.
    pub fn orient(&self, tree: &Tree, orientation: Orientation) -> Tree {
        let (x, y, z) = Tree::axes();
        match orientation {
            Orientation::Solid(choice) => cut(tree, &self.region(choice).0),
            Orientation::Slice(Axis::Z) => tree.clone(),
            // right, up = y, z
            Orientation::Slice(Axis::X) => tree.remap_xyz(z, x, y),
            // right, up = x, z
            Orientation::Slice(Axis::Y) => tree.remap_xyz(x, z, y),
            Orientation::Tilted(axis, t) => tilt(&self.orient(tree, Orientation::Slice(axis)), &t),
        }
    }

    /// The shapes compiled for `orientation`.
    pub fn compiled(&self, orientation: Orientation) -> Result<Arc<Compiled>, String> {
        let Some(index) = orientation.index() else {
            let mut tilted = self.tilted.lock().map_err(|e| e.to_string())?;
            if let Some((kept, compiled)) = tilted.as_ref()
                && *kept == orientation
            {
                return Ok(compiled.clone());
            }
            let compiled = Arc::new(self.compile(orientation)?);
            *tilted = Some((orientation, compiled.clone()));
            return Ok(compiled);
        };
        let cell = &self.compiled[index];
        if let Some(compiled) = cell.get() {
            return Ok(compiled.clone());
        }
        let compiled = Arc::new(self.compile(orientation)?);
        Ok(cell.get_or_init(|| compiled).clone())
    }

    fn compile(&self, orientation: Orientation) -> Result<Compiled, String> {
        let trees: Vec<Tree> = self
            .drawn
            .iter()
            .map(|d| self.orient(&d.tree, orientation))
            .collect();
        let union = jit(&self.orient(&self.union, orientation))?;
        Ok(Compiled {
            union,
            each: OnceLock::new(),
            trees,
        })
    }
}

/// `tree`, whose slices are level planes, turned so that its plane z =
/// offset is the plane `tilt` turns that one to.
fn tilt(tree: &Tree, tilt: &Tilt) -> Tree {
    let rotation = tilt.rotation();
    let pivot = tilt.pivot;
    let (x, y, z) = Tree::axes();
    let from = [x, y, z]
        .into_iter()
        .zip(pivot)
        .map(|(axis, p)| axis - Tree::constant(p as f32))
        .collect::<Vec<_>>();
    // Each coordinate of the turned point, skipping the rotation's zeros.
    let [a, b, c] = std::array::from_fn(|k| {
        (0..3)
            .filter(|&m| rotation[(k, m)] != 0.0)
            .fold(Tree::constant(pivot[k] as f32), |sum, m| {
                sum + from[m].clone() * Tree::constant(rotation[(k, m)] as f32)
            })
    });
    tree.remap_xyz(a, b, c)
}

/// The union of `trees`; none make an empty shape.
pub fn union(trees: Vec<Tree>) -> Tree {
    match trees.as_slice() {
        [] => Tree::constant(1.0),
        [one] => one.clone(),
        _ => fidget::shapes::Union { input: trees }.into(),
    }
}

/// `tree` cut to `region`, closed where it reaches past.
pub fn cut(tree: &Tree, region: &Box3) -> Tree {
    let (x, y, z) = Tree::axes();
    [x, y, z]
        .into_iter()
        .enumerate()
        .map(|(i, axis)| {
            (Tree::constant(region.lower[i] as f32) - axis.clone())
                .max(axis - Tree::constant(region.upper[i] as f32))
        })
        .fold(tree.clone(), |shape, slab| shape.max(slab))
}

#[cfg(test)]
mod test {
    use std::path::Path;

    use fidget::jit::JitShape;
    use fidget::types::Grad;

    use super::jit;
    use crate::script::{Engine, Overrides};

    /// Prelude shapes whose faces, edges, corners and axes lie on the
    /// lattice of `prelude_fields_have_a_gradient_wherever_they_have_a_value`.
    const SHAPES: &[&str] = &[
        "rect([10, 6])",
        "rect([10, 6], #{round: 1})",
        "rect([10, 6], #{chamfer: 1})",
        "rect([10, 6], #{round: lerp(0.5, 2.5, linstep(-5, 5, x))})",
        "annulus([6, 4])",
        "ellipse([6, 4])",
        "teardrop(3).extrude(8)",
        "regular_polygon(6, 8)",
        "hexagon_af(10)",
        "star(5, [10, 4])",
        "polygon([[0, 0], [8, 0], [8, 4], [0, 8]])",
        "polygon([[0, 0], [0, 8], [8, 4], [8, 0]])",
        "rounded_polygon([[-6, -6], [6, -6], [0, 6]], 1)",
        "rounded_polygon([[-6, -6], [6, -6, 0], [6, 6], [0, 0], [-6, 6]], 1, #{concave: 2})",
        "rounded_polygon([[-6, -4], [6, -4, #{arc: 5}], [6, 4], [-6, 4, #{arc: -5}]], 1)",
        "rounded_polygon([[6, 0, #{arc: 6}], [-6, 0, #{arc: 6}]], 0)",
        "polygon([[[-8, -8], [8, -8], [8, 8], [-8, 8]], [[-4, -4], [4, -4], [4, 4], [-4, 4]]])",
        r#"rounded_polygon(polygon_clip([[-8, -6], [8, -6], [8, 6], [-8, 6]], [[4, 6, #{arc: 4}], [-4, 6, #{arc: 4}]], "difference"), 1)"#,
        "rounded_polygon([[0, 0], [10, 0], [6, 5], [4, 5]], 2)",
        "regular_polygon(6, 8, #{round: 2})",
        "star(5, [10, 4], #{round: [2, 1]})",
        "star(6, [10, 6], #{round: lerp(0.5, 2, linstep(-10, 10, x))})",
        "wedge([30, 250])",
        "sector(8, [0, 250])",
        "stroke([[-4, 0], [4, 0]], 4)",
        "stroke([[-4, 0], [4, 0], [4, 6]], 4)",
        r#"stroke([[-4, 0], [4, 0], [4, 6]], |t| lerp(4.0, 2.0, t), #{caps: "butt"})"#,
        "stroke([[-4, -4], [4, -4], [4, 4]], 2, #{closed: true})",
        "arc_stroke(8, [-30, 200], 3)",
        r#"arc_stroke(8, [-30, 200], 3, #{caps: "butt"})"#,
        "polar_outline(|a| 8 + cosd(5 * a))",
        "morph(polygon_ray(4, 8), star_ray(5, [9, 4]), linstep(-6, 6, z)).intersection(abs(z) - 6)",
        "cuboid([10, 6, 4])",
        "cuboid([10, 6, 4], #{round: 1})",
        "cylinder(5, 8)",
        "cylinder(5, 8, #{round: 1})",
        "cylinder(5, [-4, 4], #{chamfer: [1, 0], round: [0, 1]})",
        "cylinder(6, 8, #{sides: 6})",
        "tube([6, 4], 8)",
        "cone([6, 2], 8)",
        "cone([6, 2], 8, #{sides: 4})",
        "cone([0, 6], 8)",
        "torus(6, 2)",
        "ellipsoid([6, 4, 3])",
        "capsule([-4, 0, 0], [4, 0, 0], 2)",
        "capsule([[-4, 0, 0], [4, 0, 0], [4, 4, 4]], 2)",
        "rect([10, 6]).extrude(4, #{round: 1})",
        "rect([10, 6]).extrude(4, #{round: |t| lerp(0.5, 1.5, t)})",
        "rect([10, 6]).extrude(4, #{chamfer: 1})",
        "rect([6, 4]).extrude(8).twist(10 * z)",
        "rect([6, 4]).extrude(8, #{twist: 30, scale: 0.5, ease: \"in_out_sine\"})",
        "rect([6, 4]).extrude([-4, 4], #{draft: 10, move: [2, 0], round: [0, 1]})",
        "rect([6, 4]).revolve()",
        "revolve([[0, -4], [6, -4], [6, 2, #{arc: 4}], [0, 6]])",
        "rect([2, 4]).move([4, 0]).revolve(90)",
        "rect([2, 4]).move([4, 0]).revolve([-45, 200], #{sides: 6})",
        "rect([2, 2]).extrude(4).bend(8)",
        "rect([2, 2]).bend(6, [0, 90])",
        "loft([-4, 4], |t| #{shape: rect(6), scale: 1.0 - t, angle: 30 * t})",
        "sweep(rect([2, 2]), [#{line: 4}, #{arc: 4, turn: 90}, #{helix: 4, turn: -90, rise: 2}, #{bezier: [[4, 0], [4, 4]]}])",
        "helix(rect(1), 6, 4).intersection(cuboid(16))",
        r#"loft([#{z: -4, shape: hexagon_af(10)}, #{z: 4, shape: rect(6), angle: 30, ease: "in_out_asine"}])"#,
        r#"normalize_z(star(6, [8, keyframes(z, [[-4, 4], [4, 7, "out_asine"]])])).intersection(abs(z) - 6)"#,
        "offset(rect(4), 2 * ease_in_pow(linstep(-4, 4, z), 3)).intersection(abs(z) - 6)",
        "cuboid(8).union_round(cylinder(2, 12), 1)",
        "cuboid(8).intersection_round(cylinder(5, 12), 1)",
        "cuboid(8).intersection_round(cylinder(5, 12), lerp(0.5, 1.5, linstep(-4, 4, z)))",
        "cuboid(8).union_chamfer(cylinder(2, 12), 1)",
        "cuboid(8).difference_chamfer(cylinder(2, 12), 1)",
        "shell(cuboid(8), 1)",
        r#"screw_hole("M3", 6, #{head: "countersunk"})"#,
        r#"nut_trap("M3", 3)"#,
        r#"insert_hole("M3")"#,
        "involute_gear(10, 2, #{fillet: 0.5}).extrude(4)",
        "cuboid([1, 1, 4]).move([6, 0]).repeat_polar(8)",
        "bezier_stroke([[-8, 0], [0, 8], [8, 0]], |t| lerp(2.0, 1.0, t))",
        "squircle(6, 0.9)",
        "squircle(6, 0.5).extrude(4)",
        "squircle_ray(x - 2, z, 0.9).r - 0.5",
        "squircle_ray(x, y + 1, 0.99).slope - 0.5",
        "polar_outline(6 + 0.5 * cos(5 * _atan2(y, x)), -2.5 * sin(5 * _atan2(y, x)))",
        "ellipsoid([3, 3, 3]).elongate([4, 0, 2])",
        "torus(4, 1).elongate([2, 4, 0])",
        "rect([4, 2]).elongate(3)",
        "ellipsoid([8, 8, 6]).engrave(rect([10, 2]).extrude([0, 12]), -ellipsoid([8, 8, 6]), 1)",
        "normalize_slope(_hypot(x, y) - (6 - 0.5 * z), 0.5).intersection(abs(z) - 4)",
        "loft_tilted(lerp(squircle(6, 0.9), circle(3), z), [-1, 0, 8], 12).intersection(-z)",
        "loft_tilted(rect(8), [2, 1, 6], -20).shell(1).intersection(-z)",
    ];

    /// Evaluates the shape `source` draws, and its gradient, at `points`.
    fn grad_at(source: &str, points: &[[f32; 3]]) -> Vec<Grad> {
        let prelude = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
        let mut engine = Engine::new(Some(&prelude));
        let (run, result) = engine.run(&format!("draw({source});"), None, &Overrides::new());
        if let Err(error) = result {
            panic!("{source}: {}", error.message);
        }
        let shape = jit(&run.drawn[0].tree).expect("compiles");
        let tape = shape.grad_slice_tape(Default::default());
        let mut eval = JitShape::new_grad_slice_eval();
        let [x, y, z] = [0, 1, 2].map(|axis| {
            points
                .iter()
                .map(|p| {
                    let mut d = [0.0; 3];
                    d[axis] = 1.0;
                    Grad::new(p[axis], d[0], d[1], d[2])
                })
                .collect::<Vec<_>>()
        });
        eval.eval(&tape, &x, &y, &z).expect("evaluates").to_vec()
    }

    /// A tilted loft's wall is where its slices put it, its field is a
    /// distance square to the wall there, to first order, and its top lies
    /// on the plane that `rotate_y` turns the level one to.
    #[test]
    fn tilted_lofts_are_distances_at_their_walls() {
        let (top, tilt) = ([-1.0f32, 0.5, 8.0], 12f32.to_radians());
        let source = "loft_tilted(_hypot(x, y) - lerp(6.0, 3.0, z), [-1, 0.5, 8], 12)";
        let mut walls = vec![];
        for t in [0.2f32, 0.5, 0.8] {
            let a = (t * tilt.tan()).atan();
            let r = 6.0 - 3.0 * t;
            for i in 0..8 {
                let turn = i as f32 * std::f32::consts::TAU / 8.0;
                let (u, v) = (r * turn.cos(), r * turn.sin());
                walls.push([
                    t * top[0] + u * a.cos(),
                    t * top[1] + v,
                    t * top[2] - u * a.sin(),
                ]);
            }
        }
        for (p, g) in walls.iter().zip(grad_at(source, &walls)) {
            let length = (g.dx * g.dx + g.dy * g.dy + g.dz * g.dz).sqrt();
            assert!(g.v.abs() < 1e-3, "{p:?}: {g:?}");
            assert!((length - 1.0).abs() < 0.01, "{p:?}: {length}");
        }
        // On the top, 2 along it towards +X, then 0.5 above it
        let (along, up) = (
            [tilt.cos(), 0.0, -tilt.sin()],
            [tilt.sin(), 0.0, tilt.cos()],
        );
        let points: Vec<[f32; 3]> = [0.0, 0.5]
            .iter()
            .map(|h| [0, 1, 2].map(|i| top[i] + 2.0 * along[i] + h * up[i]))
            .collect();
        let lid = grad_at(source, &points);
        assert!(lid[0].v.abs() < 1e-4, "{lid:?}");
        assert!((lid[1].v - 0.5).abs() < 1e-4, "{lid:?}");
        let turned = "move(rotate_y(z, 12), [-1, 0.5, 8])";
        let plane = grad_at(turned, &points);
        assert!(
            plane[0].v.abs() < 1e-4 && (plane[1].v - 0.5).abs() < 1e-4,
            "{plane:?}"
        );
    }

    /// Rounded outlines are distances, at points worked out by hand or from
    /// a dense sampling of the outline, and positive everywhere outside
    /// them, also where a sharp corner meets an arc with no edge between.
    #[test]
    fn rounded_outlines_are_distances() {
        let notch = "rounded_polygon([[0, 0], [20, 0], [20, 20], [10, 12, 8], [0, 20]], 0)";
        let cases: &[(&str, [f32; 2], f32)] = &[
            (notch, [30.0, 30.0], 14.1421),
            (notch, [10.0, 40.0], 22.3607),
            (notch, [10.0, 14.0], -0.245),
            (notch, [10.0, 5.0], -5.0),
            (
                "rounded_polygon([[0, 0], [30, 0], [30, 8], [8, 8], [8, 20], [0, 20]], 3, #{concave: 1})",
                [9.0, 9.0],
                1.0,
            ),
            (
                "star(6, [40, 40 / sqrt(3.0)], #{round: 10})",
                [0.0, 30.0],
                5.359,
            ),
            (
                "star(6, [40, 40 / sqrt(3.0)], #{round: 10})",
                [0.0, 0.0],
                -24.641,
            ),
            ("regular_polygon(4, 10, #{round: 100})", [10.0, 0.0], 2.9289),
            ("sector(10, [0, 60])", [5.0, 1.0], -1.0),
            (
                r#"arc_stroke(15, [0, 90], 6, #{caps: "butt"})"#,
                [19.0, -4.0],
                4.1231,
            ),
            (
                r#"stroke([[-5, 0], [5, 0]], 2, #{caps: "butt"})"#,
                [7.0, 3.0],
                2.8284,
            ),
            // The two arcs at the narrow top do not fit on it: one arc of
            // radius 3, tangent to both sides, centred 3 / sin(atan(9 / 8))
            // below where they meet, at (10, 80 / 9).
            (
                "rounded_polygon([[0, 0], [20, 0], [11, 8], [9, 8]], 3)",
                [10.0, 12.0],
                4.1250,
            ),
            // A point in a lambda's arm where a sharp concave corner, the
            // edge into it and the edge out of it are all nearest: each
            // of the three must take the corner's side there.
            (
                "rounded_polygon([[-12, 5.196152422706631], [2.6943439751349043, 5.196152422706631], \
                 [0.9622931675660262, 8.196152422706632], [-3, 8.196152422706632], \
                 [-5.767949192431122, 12.99038105676658], [-7.5, 12.99038105676658], \
                 [-8.36602540378444, 11.49038105676658], [-6.4641016151377535, 8.196152422706632], \
                 [-10.267949192431123, 8.196152422706632]], 0.375, #{concave: 0})",
                [-5.2667456, 8.887506],
                -1.3826,
            ),
            // A slot's end bulging round an arc of radius 12, rounded by 2
            // where it meets the sides
            (
                "rounded_polygon([[0, 0], [30, 0, #{arc: 12}], [30, 16], [0, 16]], 2)",
                [50.0, 8.0],
                50.0 - 30.0 - (12.0 - (144.0f32 - 64.0).sqrt()),
            ),
        ];
        for (source, p, d) in cases {
            let g = &grad_at(source, &[[p[0], p[1], 0.0]])[0];
            assert!((g.v - d).abs() < 1e-3, "{source} at {p:?}: {} for {d}", g.v);
        }
        // Sharp corners with an arc on each side, as closing a set of
        // points gives them
        let arcs = "rounded_polygon([[0, 0, 0], [10, 3.535534, 30], [20, 0, 0], \
                    [12.637361, 5.924908, 30], [10, 15, 0], [7.362639, 5.924908, 30]], 0)";
        let outside: Vec<[f32; 3]> = (0..120)
            .flat_map(|i| {
                (0..120).map(move |j| [-20.0 + i as f32 * 0.5, -20.0 + j as f32 * 0.5, 0.0])
            })
            .filter(|p| p[0] < -0.5 || p[0] > 20.5 || p[1] < -0.5 || p[1] > 20.5)
            .collect();
        for source in [notch, arcs] {
            for (p, g) in outside.iter().zip(grad_at(source, &outside)) {
                assert!(g.v > 0.0, "{source} at {p:?}: {}", g.v);
            }
        }
    }

    /// Outlines of lines and arcs, and of several loops, are the distances
    /// their shapes have in closed form, at every point of a grid.
    #[test]
    fn outlines_of_arcs_and_holes_are_distances() {
        let points: Vec<[f32; 3]> = (0..=60)
            .flat_map(|i| {
                (0..=60).map(move |j| [-15.0 + i as f32 * 0.5, -15.0 + j as f32 * 0.5, 0.0])
            })
            .collect();
        fn rect(p: [f32; 3], w: f32, h: f32) -> f32 {
            let (dx, dy) = (p[0].abs() - w, p[1].abs() - h);
            dx.max(dy).min(0.0) + dx.max(0.0).hypot(dy.max(0.0))
        }
        // The distance in closed form at a point
        type Exact = fn([f32; 3]) -> f32;
        let cases: [(&str, Exact); 3] = [
            // A stadium: two lines and two half circles
            (
                "rounded_polygon([[-6, -4], [6, -4, #{arc: 4}], [6, 4], [-6, 4, #{arc: 4}]], 0)",
                |p| (p[0] - p[0].clamp(-6.0, 6.0)).hypot(p[1]) - 4.0,
            ),
            // A square with a round hole, the hole a loop of two half circles
            (
                "polygon([[[-10, -10], [10, -10], [10, 10], [-10, 10]], [[4, 0, #{arc: 4}], [-4, 0, #{arc: 4}]]])",
                |p| rect(p, 10.0, 10.0).max(4.0 - p[0].hypot(p[1])),
            ),
            // A square frame, both loops given the same way round
            (
                "polygon([[[-10, -10], [10, -10], [10, 10], [-10, 10]], [[-4, -4], [4, -4], [4, 4], [-4, 4]]])",
                |p| rect(p, 10.0, 10.0).max(-rect(p, 4.0, 4.0)),
            ),
        ];
        for (source, exact) in cases {
            for (p, g) in points.iter().zip(grad_at(source, &points)) {
                let d = exact(*p);
                assert!((g.v - d).abs() < 1e-4, "{source} at {p:?}: {} for {d}", g.v);
            }
        }
    }

    /// polygon_clip's loops, point by point: crossing squares, squares
    /// that share an edge or only a corner, a hole, edges that overlap in
    /// part, a notch of two half circles, and nothing in common.
    #[test]
    fn polygon_clips_give_their_points() {
        let prelude = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
        let mut engine = Engine::new(Some(&prelude));
        let square = "[[0, 0], [10, 0], [10, 10], [0, 10]]";
        let cases = [
            (
                format!(r#"polygon_clip({square}, [[5, 5], [15, 5], [15, 15], [5, 15]], "intersection")"#),
                "[[[10.0, 5.0], [10.0, 10.0], [5.0, 10.0], [5.0, 5.0]]]",
            ),
            (
                format!(r#"polygon_clip({square}, [[5, 5], [15, 5], [15, 15], [5, 15]], "difference")"#),
                "[[[0.0, 0.0], [10.0, 0.0], [10.0, 5.0], [5.0, 5.0], [5.0, 10.0], [0.0, 10.0]]]",
            ),
            (
                format!(r#"polygon_clip({square}, [[10, 0], [20, 0], [20, 10], [10, 10]], "union")"#),
                "[[[0.0, 0.0], [20.0, 0.0], [20.0, 10.0], [0.0, 10.0]]]",
            ),
            (
                format!(r#"polygon_clip({square}, [[10, 10], [20, 10], [20, 20], [10, 20]], "union")"#),
                "[[[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]], \
                 [[10.0, 10.0], [20.0, 10.0], [20.0, 20.0], [10.0, 20.0]]]",
            ),
            (
                format!(r#"polygon_clip({square}, [[2, 2], [8, 2], [8, 8], [2, 8]], "difference")"#),
                "[[[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]], \
                 [[8.0, 2.0], [2.0, 2.0], [2.0, 8.0], [8.0, 8.0]]]",
            ),
            (
                r#"polygon_clip([[0, 0], [40, 0], [40, 10], [0, 10]], [[0, 0], [10, 0], [10, 30], [0, 30]], "union")"#
                    .into(),
                "[[[0.0, 0.0], [40.0, 0.0], [40.0, 10.0], [10.0, 10.0], [10.0, 30.0], [0.0, 30.0]]]",
            ),
            (
                r#"polygon_clip([[-20, -10], [20, -10], [20, 10], [-20, 10]], [[8, 10, #{arc: 8}], [-8, 10, #{arc: 8}]], "difference")"#
                    .into(),
                "[[[-20.0, -10.0], [20.0, -10.0], [20.0, 10.0], [8.0, 10.0, #{\"arc\": -8.0}], [-8.0, 10.0], [-20.0, 10.0]]]",
            ),
            (
                format!(r#"polygon_clip({square}, [[20, 0], [30, 0], [30, 10]], "intersection")"#),
                "[]",
            ),
        ];
        for (source, expected) in cases {
            let (_, result) = engine.run(&source, None, &Overrides::new());
            let value = result.unwrap_or_else(|error| panic!("{source}: {}", error.message));
            assert_eq!(value.to_string(), expected, "{source}");
        }
    }

    /// A profile given as points revolves into a solid whose field is the
    /// distance to its surface, by brute force: the nearest point of the
    /// circle that a point of the profile's outline sweeps lies at the same
    /// angle round the axis, so the distance is the nearest of those in the
    /// half-plane, along an outline sampled every 0.01.  The profile ends on
    /// the axis at a cone's tip and crosses it at the bottom.
    #[test]
    fn revolved_points_are_distances() {
        let source = "revolve([[-3, 0], [8, 0], [8, 4, #{arc: 6}], [5, 9], [0, 12]])";
        // The outline at X >= 0, off the axis: the bottom from the axis,
        // the side, the arc bulging out, round the centre where the two
        // circles of radius 6 through its ends meet, then the cone.
        let (a, b) = ([8.0f64, 4.0], [5.0f64, 9.0]);
        let chord = ((b[0] - a[0]).powi(2) + (b[1] - a[1]).powi(2)).sqrt();
        let h = (36.0 - chord * chord / 4.0).sqrt();
        let centre = [
            (a[0] + b[0]) / 2.0 - h * (b[1] - a[1]) / chord,
            (a[1] + b[1]) / 2.0 + h * (b[0] - a[0]) / chord,
        ];
        let mut outline: Vec<[f64; 2]> = vec![];
        let line = |from: [f64; 2], to: [f64; 2], outline: &mut Vec<[f64; 2]>| {
            let n = 1000;
            outline.extend((0..=n).map(|i| {
                let t = i as f64 / n as f64;
                [
                    from[0] + (to[0] - from[0]) * t,
                    from[1] + (to[1] - from[1]) * t,
                ]
            }));
        };
        line([0.0, 0.0], [8.0, 0.0], &mut outline);
        line([8.0, 0.0], a, &mut outline);
        let (a0, a1) = (
            (a[1] - centre[1]).atan2(a[0] - centre[0]),
            (b[1] - centre[1]).atan2(b[0] - centre[0]),
        );
        outline.extend((0..=1000).map(|i| {
            let t = a0 + (a1 - a0) * i as f64 / 1000.0;
            [centre[0] + 6.0 * t.cos(), centre[1] + 6.0 * t.sin()]
        }));
        line(b, [0.0, 12.0], &mut outline);
        // Inside by the parity of the outline's crossings, the axis closing
        // it; a point on the axis counts as just off it.
        let inside = |r: f64, z: f64| {
            let r = r + 1e-9;
            let mut odd = false;
            for (p, q) in outline.iter().zip(outline.iter().cycle().skip(1)) {
                if (p[1] > z) != (q[1] > z) && p[0] + (z - p[1]) * (q[0] - p[0]) / (q[1] - p[1]) > r
                {
                    odd = !odd;
                }
            }
            odd
        };
        let points: Vec<[f32; 3]> = (0..400)
            .map(|i| {
                // A spiral of points, some on the axis
                let t = i as f32 * 0.37;
                let r = if i % 10 == 0 {
                    0.0
                } else {
                    (i % 23) as f32 * 0.6
                };
                [r * t.cos(), r * t.sin(), -3.0 + (i % 37) as f32 * 0.5]
            })
            .collect();
        for (p, g) in points.iter().zip(grad_at(source, &points)) {
            let (r, z) = ((p[0] as f64).hypot(p[1] as f64), p[2] as f64);
            let d = outline
                .iter()
                .map(|q| (r - q[0]).hypot(z - q[1]))
                .fold(f64::INFINITY, f64::min);
            let d = if inside(r, z) { -d } else { d };
            assert!((g.v as f64 - d).abs() < 0.01, "{p:?}: {} for {d}", g.v);
        }
    }

    /// A profile only ever sees slices from 0 to 1: the second sample of the
    /// slope would otherwise step past an end, where `acos` is NaN, and
    /// leave the loft with no fitted bounds.
    #[test]
    fn tilted_lofts_fit_bounds_for_profiles_defined_only_on_their_slices() {
        let prelude = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
        let mut engine = Engine::new(Some(&prelude));
        let source = "loft_tilted(_hypot(x, y) - (1 + acos(z)), [-1, 0, 8], 12).intersection(-z)";
        let (run, result) = engine.run(&format!("draw({source});"), None, &Overrides::new());
        if let Err(error) = result {
            panic!("{source}: {}", error.message);
        }
        let shape = jit(&run.drawn[0].tree).expect("compiles");
        let fitted = crate::bounds::fit(&run.drawn[0].tree, &shape).expect("not empty");
        assert!(
            fitted
                .lower
                .iter()
                .chain(&fitted.upper)
                .all(Option::is_some),
            "{fitted:?}"
        );
    }

    /// A rounding whose radius varies over space is a distance near its
    /// surface, to first order, as one with a fixed radius is.
    #[test]
    fn varying_roundings_are_distances_near_their_surface() {
        // Every multiple of 0.25 from -10 to 10.
        let steps: Vec<f32> = (-40..=40).map(|i| i as f32 * 0.25).collect();
        let mut points = vec![];
        for &x in &steps {
            for &y in &steps {
                for &z in &steps {
                    points.push([x, y, z]);
                }
            }
        }
        // Without the correction, the first is off by 2.5% and the last by
        // 4.3%.
        for source in [
            "rect([16, 10], #{round: lerp(1, 4, smoothstep(-8, 8, x))}).extrude(4)",
            "cuboid([16, 10, 8], #{round: lerp(1, 3, smoothstep(-8, 8, x))})",
            "rect([16, 10], #{round: 3}).extrude([0, 8], #{round: [0, lerp(1, 3, smoothstep(-8, 8, x))]})",
            "cylinder(5, 20).intersection_round(z - 3, lerp(0.5, 2.5, smoothstep(-5, 5, x)))",
        ] {
            let mut worst = (0.0f32, [0.0f32; 3]);
            for (p, g) in points.iter().zip(grad_at(source, &points)) {
                if g.v.abs() < 0.1 {
                    let length = (g.dx * g.dx + g.dy * g.dy + g.dz * g.dz).sqrt();
                    if (length - 1.0).abs() > worst.0 {
                        worst = ((length - 1.0).abs(), *p);
                    }
                }
            }
            assert!(
                worst.0 < 0.015,
                "{source}: |grad| off by {} at {:?}",
                worst.0,
                worst.1
            );
        }
    }

    /// `smooth_difference` and `smooth_intersection` are fidget's `blend`
    /// turned inside out, with the cutters blended into one first.
    #[test]
    fn smooth_cuts_are_inverted_blends() {
        // Every multiple of 0.5 from -12 to 12.
        let steps: Vec<f32> = (-24..=24).map(|i| i as f32 * 0.5).collect();
        let mut points = vec![];
        for &x in &steps {
            for &y in &steps {
                for &z in &steps {
                    points.push([x, y, z]);
                }
            }
        }
        let shapes = "let a = cuboid([16, 16, 10]); \
                      let b = sphere(8).move([0, 0, 8]); \
                      let c = cylinder(3, 20).rotate_x(90).move([0, 0, 5]);";
        for (source, blended) in [
            (
                "a.smooth_difference([b, c], 4)",
                "inverse(blend(inverse(a), blend(b, c, 4), 4))",
            ),
            (
                "a.smooth_intersection([b, c], 4)",
                "inverse(blend(blend(inverse(a), inverse(b), 4), inverse(c), 4))",
            ),
        ] {
            let ours = grad_at(&format!("{{ {shapes} {source} }}"), &points);
            let theirs = grad_at(&format!("{{ {shapes} {blended} }}"), &points);
            for ((p, g), h) in points.iter().zip(ours).zip(theirs) {
                assert!((g.v - h.v).abs() < 1e-5, "{source} at {p:?}: {g:?}, {h:?}");
            }
        }
    }

    /// A 2D vector where a 3D one is expected has z = 0: a point of a
    /// prelude function, an anchor in its options, a native built-in's
    /// argument and a center in its map, and a vector beside a 3D one.  A
    /// vector of another length is an error that shows it.
    #[test]
    fn two_d_vectors_stand_for_3d_ones_with_z_0() {
        let steps: Vec<f32> = (-6..=6).map(|i| i as f32).collect();
        let mut points = vec![];
        for &x in &steps {
            for &y in &steps {
                for &z in &steps {
                    points.push([x, y, z]);
                }
            }
        }
        for (two, three) in [
            (
                "capsule([-4, 0], [4, 2], 2)",
                "capsule([-4, 0, 0], [4, 2, 0], 2)",
            ),
            (
                "cuboid([10, 6, 4], #{anchor: [1, -1]})",
                "cuboid([10, 6, 4], #{anchor: [1, -1, 0]})",
            ),
            ("sphere(3).move([1, 2])", "sphere(3).move([1, 2, 0])"),
            (
                "sphere(#{radius: 3, center: [1, 2]})",
                "sphere(#{radius: 3, center: [1, 2, 0]})",
            ),
        ] {
            let ours = grad_at(two, &points);
            let theirs = grad_at(three, &points);
            for ((p, g), h) in points.iter().zip(ours).zip(theirs) {
                assert!((g.v - h.v).abs() < 1e-6, "{two} at {p:?}: {g:?}, {h:?}");
            }
        }

        let prelude = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
        let mut engine = Engine::new(Some(&prelude));
        for (source, expected) in [
            ("cross([1, 0, 0], [0, 1])", "[0.0, 0.0, 1.0]"),
            ("bezier_point([[0, 0], [2, 2, 2]], 0.5)", "[1.0, 1.0, 1.0]"),
        ] {
            let (_, result) = engine.run(source, None, &Overrides::new());
            let value = result.unwrap_or_else(|error| panic!("{source}: {}", error.message));
            assert_eq!(value.to_string(), expected, "{source}");
        }
        for (source, message) in [
            (
                "cuboid([1, 2, 3, 4])",
                "cuboid: size must be a number, [x, y] or [x, y, z], got [1, 2, 3, 4]",
            ),
            (
                "capsule([1], [0, 0], 1)",
                "capsule: a must be a number, [x, y] or [x, y, z], got [1]",
            ),
        ] {
            let (_, result) = engine.run(source, None, &Overrides::new());
            let error = result.expect_err(source);
            assert_eq!(error.message, message, "{source}");
        }
    }

    /// fidget meshes and shades with gradients: a NaN one makes the mesher
    /// guess a vertex and the renderer a normal, and a zero one on the
    /// surface breaks the mesher.
    #[test]
    fn prelude_fields_have_a_gradient_wherever_they_have_a_value() {
        let prelude = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
        let mut engine = Engine::new(Some(&prelude));
        // Every multiple of 0.5 from -12 to 12.
        let steps: Vec<f32> = (-24..=24).map(|i| i as f32 * 0.5).collect();
        let mut points = vec![];
        for &x in &steps {
            for &y in &steps {
                for &z in &steps {
                    points.push([x, y, z]);
                }
            }
        }
        for source in SHAPES {
            let (run, result) = engine.run(&format!("draw({source});"), None, &Overrides::new());
            if let Err(error) = result {
                panic!("{source}: {}", error.message);
            }
            let shape = jit(&run.drawn[0].tree).expect("compiles");
            let tape = shape.grad_slice_tape(Default::default());
            let mut eval = JitShape::new_grad_slice_eval();
            for chunk in points.chunks(4096) {
                let [x, y, z] = [0, 1, 2].map(|axis| {
                    chunk
                        .iter()
                        .map(|p| {
                            let mut d = [0.0; 3];
                            d[axis] = 1.0;
                            Grad::new(p[axis], d[0], d[1], d[2])
                        })
                        .collect::<Vec<_>>()
                });
                let out = eval.eval(&tape, &x, &y, &z).expect("evaluates");
                for (p, g) in chunk.iter().zip(out) {
                    let d = [g.dx, g.dy, g.dz];
                    assert!(
                        !g.v.is_finite() || d.iter().all(|v| v.is_finite()),
                        "{source}: no gradient at {p:?}: {g:?}"
                    );
                    assert!(
                        g.v != 0.0 || d != [0.0; 3],
                        "{source}: a zero gradient on the surface at {p:?}"
                    );
                }
            }
        }
    }
}
