// SPDX-License-Identifier: MPL-2.0

//! keycap's math, on numbers and trees alike: the number forms that
//! fidget's bindings lack.  Their docs are in `docs/math.toml` and
//! `docs/remap.toml`.

use fidget::context::Tree;
use fidget::rhai::FromDynamic;
use rhai::{Dynamic, EvalAltResult, NativeCallContext};

type OfNumber = fn(f64) -> f64;

/// fidget's functions of a tree that Rhai has for floats, or not at all,
/// as functions of a number.
const NUMBER: [(&str, OfNumber); 13] = [
    ("sqrt", f64::sqrt),
    ("square", |a| a * a),
    ("sin", f64::sin),
    ("cos", f64::cos),
    ("tan", f64::tan),
    ("asin", f64::asin),
    ("acos", f64::acos),
    ("atan", f64::atan),
    ("exp", f64::exp),
    ("ln", f64::ln),
    ("floor", f64::floor),
    ("ceil", f64::ceil),
    ("round", f64::round),
];

/// Registers the functions in the keycap dialect: of an integer, each
/// gives a float.
pub fn register(engine: &mut rhai::Engine) {
    for (name, f) in NUMBER {
        engine.register_fn(name, move |a: i64| f(a as f64));
    }
    // Rhai has `ceiling`, and no `square`.
    engine.register_fn("ceil", f64::ceil);
    engine.register_fn("square", |a: f64| a * a);

    // Rhai's `atan` of two numbers is `atan2`, of floats only.
    for name in ["atan2", "atan"] {
        engine.register_fn(name, |y: f64, x: f64| y.atan2(x));
        engine.register_fn(name, |y: i64, x: i64| (y as f64).atan2(x as f64));
        engine.register_fn(name, |y: f64, x: i64| y.atan2(x as f64));
        engine.register_fn(name, |y: i64, x: f64| (y as f64).atan2(x));
    }

    // fidget's takes only trees for coordinates.
    engine.register_fn(
        "remap",
        |ctx: NativeCallContext, shape: Dynamic, x: Dynamic, y: Dynamic, z: Dynamic| {
            let tree = |v| Tree::from_dynamic(&ctx, v, None);
            Ok::<_, Box<EvalAltResult>>(tree(shape)?.remap_xyz(tree(x)?, tree(y)?, tree(z)?))
        },
    );
    engine.register_fn(
        "remap",
        |ctx: NativeCallContext, shape: Dynamic, x: Dynamic, y: Dynamic| {
            let tree = |v| Tree::from_dynamic(&ctx, v, None);
            Ok::<_, Box<EvalAltResult>>(tree(shape)?.remap_xyz(tree(x)?, tree(y)?, Tree::z()))
        },
    );
}

#[cfg(test)]
mod test {
    use std::path::Path;

    use fidget::context::Tree;
    use fidget::jit::JitShape;
    use fidget::types::Grad;
    use rhai::Dynamic;

    use crate::scene::jit;
    use crate::script::{Engine, Overrides};

    /// Calls of every function, `{}` standing for the argument, and
    /// arguments for them, that give the same value as a number and as a
    /// tree, X, read at that number.
    const ALIKE: &[(&str, &[f64])] = &[
        ("sqrt({})", &[0.25, 2.0, 9.0]),
        ("square({})", &[-3.0, 0.5, 2.0]),
        ("ceil({})", &[-1.5, 0.0, 2.25]),
        ("floor({})", &[-1.5, 2.25]),
        ("round({})", &[-1.5, 2.25]),
        ("exp({})", &[-1.0, 2.0]),
        ("ln({})", &[0.5, 3.0]),
        ("atan2({}, -2)", &[-1.0, 0.0, 3.0]),
        ("atan2(1, {})", &[-1.0, 0.0, 3.0]),
    ];

    fn engine() -> Engine {
        let prelude = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
        Engine::new(Some(&prelude))
    }

    fn eval(engine: &mut Engine, source: &str) -> Dynamic {
        let (_, result) = engine.run(source, None, &Overrides::new());
        result.unwrap_or_else(|error| panic!("{source}: {}", error.message))
    }

    /// A number as a float, an integer too.
    fn number(source: &str, v: &Dynamic) -> f64 {
        let float = v.as_float().ok();
        let number = float.or_else(|| v.as_int().ok().map(|i| i as f64));
        number.unwrap_or_else(|| panic!("{source}: {v} is no number"))
    }

    fn tree(source: &str, v: Dynamic) -> Tree {
        v.try_cast::<Tree>()
            .unwrap_or_else(|| panic!("{source}: no tree"))
    }

    /// A tree's value and gradient at X = `at`, Y and Z 0.
    fn at(tree: &Tree, at: f32) -> Grad {
        let shape = jit(tree).expect("compiles");
        let tape = shape.grad_slice_tape(Default::default());
        let mut eval = JitShape::new_grad_slice_eval();
        let (x, y, z) = (
            Grad::new(at, 1.0, 0.0, 0.0),
            Grad::from(0.0),
            Grad::from(0.0),
        );
        eval.eval(&tape, &[x], &[y], &[z]).expect("evaluates")[0]
    }

    fn close(a: f64, b: f64) -> bool {
        a == b || (a - b).abs() <= 1e-5 * (1.0 + a.abs().max(b.abs()))
    }

    /// Every function gives a number of numbers, integers too, and a tree
    /// of a tree, which has the same value, and a gradient, at that number.
    #[test]
    fn numbers_and_trees_alike() {
        let mut engine = engine();
        for (call, args) in ALIKE {
            let source = call.replace("{}", "x");
            let t = tree(&source, eval(&mut engine, &source));
            for &arg in *args {
                let source = call.replace("{}", &format!("{arg:?}"));
                let want = number(&source, &eval(&mut engine, &source));
                let got = at(&t, arg as f32);
                assert!(close(got.v.into(), want), "{source}: {} for {want}", got.v);
                assert!(got.d(0).is_finite(), "{source}: no gradient");
                if arg.fract() == 0.0 {
                    let source = call.replace("{}", &format!("{}", arg as i64));
                    let int = number(&source, &eval(&mut engine, &source));
                    assert!(close(int, want), "{source}: {int} for {want}");
                }
            }
        }
    }

    /// `remap` takes numbers for coordinates, as constants.
    #[test]
    fn remap_takes_numbers() {
        let mut engine = engine();
        for source in ["sphere(5).remap(x, 0, 0)", "remap(sphere(5), x, 0.0)"] {
            let t = tree(source, eval(&mut engine, source));
            assert_eq!(at(&t, 3.0).v, -2.0, "{source}");
        }
    }
}
