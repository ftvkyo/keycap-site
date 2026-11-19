// SPDX-License-Identifier: MPL-2.0

//! keycap's math, on numbers and trees alike: the number forms that
//! fidget's bindings lack, and powers.  Their docs are in `docs/math.toml`,
//! `docs/arithmetic.toml` and `docs/remap.toml`.

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

/// The least base `exp_ln` takes: above 0, so that its logarithm and the
/// logarithm's interval stay finite.
const TINY: f32 = 1e-30;

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

    engine.register_fn("pow", pow);
    engine.register_fn("**", |ctx: NativeCallContext, a: Tree, n: Dynamic| {
        power(&ctx, Dynamic::from(a), n)
    });
    engine.register_fn("**", |ctx: NativeCallContext, a: Dynamic, n: Tree| {
        power(&ctx, a, Dynamic::from(n))
    });
}

/// `a ** n`: Rhai's for two numbers, else a tree.
fn pow(ctx: NativeCallContext, a: Dynamic, n: Dynamic) -> Result<Dynamic, Box<EvalAltResult>> {
    if a.is::<Tree>() || n.is::<Tree>() {
        power(&ctx, a, n).map(Dynamic::from)
    } else {
        ctx.call_native_fn("**", (a, n))
    }
}

/// `a` to the power `n`, one of them a tree.  A whole `n` multiplies `a`
/// by squaring, which takes any `a`; any other, `exp(n ln a)`, which takes
/// an `a` above 0, and gives 0 at 0 and below.
fn power(ctx: &NativeCallContext, a: Dynamic, n: Dynamic) -> Result<Tree, Box<EvalAltResult>> {
    if let Some(n) = number(&n) {
        let a = Tree::from_dynamic(ctx, a, None)?;
        return Ok(match whole(n) {
            Some(n) => a.pow(n),
            None => real_power(a, n as f32),
        });
    }
    let n = Tree::from_dynamic(ctx, n, None)?;
    match number(&a) {
        Some(a) if a > 0.0 => Ok((n * a.ln() as f32).exp()),
        _ => Ok(real_power(Tree::from_dynamic(ctx, a, None)?, n)),
    }
}

/// `exp_ln(a, n)` where `a` is above 0, and 0 elsewhere, chosen by `and`:
/// at 0 too, where `TINY` to a small `n` is far from it.
fn real_power(a: Tree, n: impl Into<Tree>) -> Tree {
    let above_0 = a.compare(0.0).max(0.0);
    above_0.and(exp_ln(a, n))
}

/// `a` to the power `n` as `exp(n ln a)`, `a` taken as [`TINY`] below it,
/// so that neither its value nor its interval is NaN where `a` is 0 or
/// less.
fn exp_ln(a: Tree, n: impl Into<Tree>) -> Tree {
    (n.into() * a.max(TINY).ln()).exp()
}

/// A number, an integer as a float.
fn number(v: &Dynamic) -> Option<f64> {
    v.as_float()
        .ok()
        .or_else(|| v.as_int().ok().map(|i| i as f64))
}

/// `n` as an integer, when it is one that fits.
fn whole(n: f64) -> Option<i64> {
    (n.fract() == 0.0 && n.abs() < 2f64.powi(53)).then_some(n as i64)
}

#[cfg(test)]
mod test {
    use std::path::Path;

    use fidget::context::Tree;
    use fidget::jit::JitShape;
    use fidget::types::{Grad, Interval};
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
        ("pow({}, 3)", &[-2.0, 0.0, 1.5]),
        ("pow({}, -2.0)", &[-2.0, 0.5, 4.0]),
        ("pow({}, 0)", &[-2.0, 0.0, 4.0]),
        ("pow({}, 2.0)", &[-2.0, 0.0, 4.0]),
        ("pow({}, 0.5)", &[0.0, 2.0, 9.0]),
        ("pow({}, -1.5)", &[0.25, 4.0]),
        ("pow(2.0, {})", &[-2.0, 0.0, 0.5, 3.0]),
        ("pow({}, 0.01)", &[0.0, 2.0]),
        ("pow(0.0, {})", &[0.5, 3.0]),
        ("{} ** 3", &[-2.0, 1.5]),
        ("2.5 ** {}", &[-1.0, 2.0]),
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

    /// A tree's interval over X from `lo` to `hi`, Y and Z 0.
    fn over(tree: &Tree, lo: f32, hi: f32) -> Interval {
        let shape = jit(tree).expect("compiles");
        let tape = shape.interval_tape(Default::default());
        let mut eval = JitShape::new_interval_eval();
        let zero = Interval::from(0.0);
        let (interval, _) = eval
            .eval(&tape, Interval::new(lo, hi), zero, zero)
            .expect("evaluates");
        interval
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

    /// Powers of a number are Rhai's: of integers an integer, and a
    /// negative base with an exponent that is not whole NaN.
    #[test]
    fn powers_of_numbers_are_rhais() {
        let mut engine = engine();
        assert_eq!(eval(&mut engine, "pow(2, 10)").as_int(), Ok(1024));
        assert_eq!(eval(&mut engine, "pow(2.0, -1)").as_float(), Ok(0.5));
        assert!(
            eval(&mut engine, "pow(-8.0, 1.0 / 3)")
                .as_float()
                .is_ok_and(f64::is_nan)
        );
        let (_, result) = engine.run("pow(2, -1)", None, &Overrides::new());
        assert!(result.is_err());
    }

    /// A power of a tree by an exponent that is not whole is 0 where the
    /// base is negative, with a gradient, and its interval stays finite
    /// across 0; a whole one takes any base, its interval exact for an even
    /// exponent, as `square`'s is.
    #[test]
    fn powers_of_trees_keep_their_intervals() {
        let mut engine = engine();
        // The interval over X from `lo` to `hi` holds the values from
        // `want[0]` to `want[1]`, and no more where `exact`.
        for (source, lo, hi, want, exact) in [
            ("x ** 2", -1.0, 2.0, [0.0, 4.0], true),
            ("x ** 4", -2.0, 1.0, [0.0, 16.0], true),
            ("x ** -2", 1.0, 2.0, [0.25, 1.0], false),
            ("x ** 3", -1.0, 2.0, [-1.0, 8.0], false),
            ("x ** 0.5", -1.0, 4.0, [0.0, 2.0], false),
            ("x ** 1.5", -4.0, 4.0, [0.0, 8.0], false),
            ("x ** x", -1.0, 2.0, [0.0, 4.0], false),
            ("2 ** x", -1.0, 3.0, [0.5, 8.0], false),
        ] {
            let t = tree(source, eval(&mut engine, source));
            let interval = over(&t, lo, hi);
            let (l, u) = (f64::from(interval.lower()), f64::from(interval.upper()));
            let holds = l <= want[0] + 1e-5 && u >= want[1] - 1e-5;
            let fits = !exact || (close(l, want[0]) && close(u, want[1]));
            assert!(
                l.is_finite() && u.is_finite() && holds && fits,
                "{source} over [{lo}, {hi}]: {interval:?}"
            );
        }
        for (source, arg, want) in [
            ("x ** 0.5", -4.0, 0.0),
            ("x ** x", -2.0, 0.0),
            ("(-2) ** x", 1.0, 0.0),
            ("x ** -2", -2.0, 0.25),
            ("x ** 3", -2.0, -8.0),
        ] {
            let got = at(&tree(source, eval(&mut engine, source)), arg);
            assert_eq!(got.v, want, "{source} at {arg}");
            assert!(got.d(0).is_finite(), "{source} at {arg}: no gradient");
        }
        // A negative power's interval across 0 is NaN, as `1 / x`'s is.
        let t = tree("x ** -1", eval(&mut engine, "x ** -1"));
        assert!(over(&t, -1.0, 1.0).has_nan());
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
