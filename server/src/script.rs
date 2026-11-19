// SPDX-License-Identifier: MPL-2.0

//! The Rhai engines: fidget's bindings, the script API on top of them,
//! imports and the prelude, for each dialect.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use fidget::context::Tree;
use fidget::rhai::FromDynamic;
use fidget::shapes::types::Vec3;
use rhai::module_resolvers::ModuleResolver;
use rhai::{
    AST, ASTFlags, ASTNode, Dynamic, EvalAltResult, Expr, FnAccess, FuncRegistration,
    ImmutableString, Map, Module, NativeCallContext, OptimizationLevel, Position, Scope, Stmt,
};
use serde::Deserialize;
use serde_json::Value;

use crate::bounds::Box3;
use crate::diagnostic::{self, Diagnostic, Location, Severity};
use crate::math;
use crate::svg;
use crate::text::{self, Fonts};

/// fidget's own limit, [`FIDGET_OPERATIONS`], stops ordinary models with
/// loops; this still stops a runaway loop within a second or so.
const MAX_OPERATIONS: u64 = 20_000_000;

/// fidget's own engine stops a script past this many operations.
pub const FIDGET_OPERATIONS: u64 = 50_000;

/// The language a script is written in.
#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Hash, Default, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Dialect {
    /// What fidget's own viewer runs: fidget's bindings, `draw` and
    /// `draw_rgb`, and imports
    Fidget,
    /// fidget's, with the script API, the prelude, `text` and `svg`
    #[default]
    Keycap,
}

/// The functions of the script API that only the keycap dialect has,
/// besides the prelude's.
const EXTENSIONS: [&str; 4] = ["bounds", "resolution", "text", "svg"];

/// Lines of `print` and `debug` output kept from one run.
const MAX_OUTPUT: usize = 1000;

/// Values for a script's top-level constants, by name, that replace the
/// values it gives them.
pub type Overrides = serde_json::Map<String, Value>;

/// A `draw` call's shape.
pub struct Drawn {
    pub tree: Tree,
    pub color: Option<[f32; 3]>,
    pub role: Role,
    pub at: Location,
}

/// What a laser does along a drawn shape's outline, as 2D export writes it.
#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum Role {
    #[default]
    Cut,
    Score,
    Engrave,
}

impl Role {
    /// In the order a laser runs them: cutting last, so that the parts stay
    /// put for the rest.
    pub const ALL: [Role; 3] = [Role::Engrave, Role::Score, Role::Cut];

    pub fn name(self) -> &'static str {
        match self {
            Role::Cut => "cut",
            Role::Score => "score",
            Role::Engrave => "engrave",
        }
    }

    /// The colour laser cutters' software takes for the role by
    /// convention: red cuts, blue scores, black engraves.
    pub fn rgb(self) -> [u8; 3] {
        match self {
            Role::Cut => [255, 0, 0],
            Role::Score => [0, 0, 255],
            Role::Engrave => [0, 0, 0],
        }
    }
}

/// What a script left behind as it ran.
#[derive(Default)]
pub struct Run {
    pub drawn: Vec<Drawn>,
    /// The script's bounds
    pub bounds: Option<Box3>,
    pub resolution: Option<f64>,
    pub output: Vec<String>,
    /// How many operations the script ran, by Rhai's count
    pub operations: u64,
    /// Output lines dropped past [`MAX_OUTPUT`]
    pub dropped: usize,
    /// The files the script read besides itself: imports, SVGs, fonts
    pub files: Vec<PathBuf>,
    /// The functions the script defines, then those it imports under a
    /// name
    pub functions: Vec<ScriptFn>,
    /// The name the script's AST was given: its path, if it has one
    main: Option<String>,
    /// The modules the script itself imports, as (the path it gives, the
    /// module's public functions)
    imports: Vec<(String, Vec<ScriptFn>)>,
}

/// A function written in Rhai, as a script calls it.
pub struct ScriptFn {
    /// `ring`, or `keycap::body` for one imported as `keycap`
    pub name: String,
    pub params: Vec<String>,
    /// Its doc comments, as written
    pub comments: Vec<String>,
    /// The file it comes from, when imported
    pub file: Option<PathBuf>,
}

/// The functions `ast` defines, as from `file`, the private ones too
/// unless `public`.  Its closures are left out: Rhai names them `anon$`
/// and a hash that differs from one process to the next.
fn script_fns(ast: &AST, file: Option<&Path>, public: bool) -> Vec<ScriptFn> {
    ast.iter_functions()
        .filter(|f| !public || f.access != FnAccess::Private)
        .filter(|f| !f.name.starts_with("anon$"))
        .map(|f| ScriptFn {
            name: f.name.to_owned(),
            params: f.params.iter().map(|p| (*p).to_owned()).collect(),
            comments: f.comments.iter().map(|c| (*c).to_owned()).collect(),
            file: file.map(Path::to_path_buf),
        })
        .collect()
}

/// The modules `ast` imports under a name: (the path it gives, the name),
/// from its `import "path" as name;` statements, wherever they are.
fn import_names(ast: &AST) -> Vec<(String, String)> {
    let mut names = vec![];
    ast.walk(&mut |nodes| {
        if let Some(ASTNode::Stmt(Stmt::Import(import, _))) = nodes.last()
            && let (Expr::StringConstant(path, _), name) = &**import
            && !name.name.is_empty()
        {
            names.push((path.to_string(), name.name.to_string()));
        }
        true
    });
    names
}

/// The modules `text` names in `import "path" as name;` statements, its
/// comments included: (the path it gives, the name).  A module's header
/// comment shows how a script imports it.
fn imports_in_text(text: &str) -> Vec<(String, String)> {
    let word = |c: char| c.is_alphanumeric() || c == '_';
    let mut names = vec![];
    let mut rest = text;
    while let Some(at) = rest.find("import") {
        let before = rest[..at].chars().next_back();
        rest = &rest[at + "import".len()..];
        if before.is_some_and(word) {
            continue;
        }
        let statement = || {
            let quoted = rest.trim_start().strip_prefix('"')?;
            let (path, after) = quoted.split_once('"')?;
            let after = after.trim_start().strip_prefix("as")?;
            let name = after.trim_start();
            let end = name.find(|c: char| !word(c)).unwrap_or(name.len());
            (after.starts_with(char::is_whitespace) && end > 0)
                .then(|| (path.to_owned(), name[..end].to_owned()))
        };
        names.extend(statement());
    }
    names
}

pub struct Engine {
    rhai: rhai::Engine,
    run: Arc<Mutex<Run>>,
    /// The operations of the script running, outside `run`'s lock, which
    /// would slow every one of them
    operations: Arc<AtomicU64>,
    dialect: Dialect,
    prelude: Prelude,
    /// What the keycap dialect has and this one lacks, to name in errors
    extensions: HashSet<String>,
}

fn lock(run: &Mutex<Run>) -> MutexGuard<'_, Run> {
    run.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Engine {
    /// The keycap dialect's engine: fidget's with the script API, and the
    /// `.rhai` files in `prelude` loaded as one global module; those in its
    /// `modules` directory are imported by name.
    pub fn new(prelude: Option<&Path>) -> Self {
        let modules = prelude.map(|dir| dir.join("modules"));
        let (mut rhai, run, operations) = engine(Dialect::Keycap, modules);
        register_api(&mut rhai, &run);
        register_outlines(&mut rhai, &run);
        math::register(&mut rhai);
        let prelude = match prelude {
            Some(dir) => Prelude::load(&mut rhai, dir),
            None => Prelude::default(),
        };
        Engine {
            rhai,
            run,
            operations,
            dialect: Dialect::Keycap,
            prelude,
            extensions: HashSet::new(),
        }
    }

    /// The fidget dialect's engine, which names what `keycap` has beyond
    /// it when a script calls it.
    pub fn fidget(keycap: &Engine) -> Self {
        let (rhai, run, operations) = engine(Dialect::Fidget, None);
        let extensions = EXTENSIONS.iter().map(|&name| name.to_owned());
        Engine {
            rhai,
            run,
            operations,
            dialect: Dialect::Fidget,
            prelude: Prelude::default(),
            extensions: extensions
                .chain(keycap.prelude.functions.keys().cloned())
                .collect(),
        }
    }

    pub fn dialect(&self) -> Dialect {
        self.dialect
    }

    pub fn prelude(&self) -> &Prelude {
        &self.prelude
    }

    pub fn rhai(&self) -> &rhai::Engine {
        &self.rhai
    }

    /// Runs `source` as the script at `path`, its top-level constants named
    /// in `overrides` given their values there, returning what it left
    /// behind and its value or error.
    pub fn run(
        &mut self,
        source: &str,
        path: Option<&Path>,
        overrides: &Overrides,
    ) -> (Run, Result<Dynamic, Diagnostic>) {
        let main = path.map(|p| p.to_string_lossy().into_owned());
        *lock(&self.run) = Run {
            main: main.clone(),
            ..Run::default()
        };
        self.operations.store(0, Ordering::Relaxed);
        let mut imports = vec![];
        let result = self
            .compile(source, overrides)
            .and_then(|mut ast| {
                if let Some(main) = &main {
                    ast.set_source(main.as_str());
                }
                lock(&self.run).functions = script_fns(&ast, None, false);
                imports = import_names(&ast);
                self.rhai.eval_ast::<Dynamic>(&ast)
            })
            .map_err(|error| {
                let mut diagnostic = Diagnostic::from_error(&error, main.as_deref());
                self.prelude.relocate(&mut diagnostic);
                if let Some(name) = self.extension(&error) {
                    diagnostic.message =
                        format!("`{name}` is a keycap extension: rename the file to .keycap");
                }
                diagnostic
            });
        let mut run = std::mem::take(&mut *lock(&self.run));
        run.operations = self.operations.load(Ordering::Relaxed);
        for (path, name) in imports {
            let imported = run.imports.iter().find(|(p, _)| *p == path);
            for function in imported.into_iter().flat_map(|(_, fns)| fns) {
                run.functions.push(ScriptFn {
                    name: format!("{name}::{}", function.name),
                    params: function.params.clone(),
                    comments: function.comments.clone(),
                    file: function.file.clone(),
                });
            }
        }
        for drawn in &mut run.drawn {
            self.prelude.relocate_location(&mut drawn.at);
        }
        (run, result)
    }

    /// Compiles `source`, the values of the top-level constants named in
    /// `overrides` replaced.
    ///
    /// Rhai's optimiser folds a constant's value into the expressions that
    /// use it, so a script with overrides is compiled unoptimised, its
    /// constants replaced on the syntax tree, then optimised as any other.
    fn compile(&mut self, source: &str, overrides: &Overrides) -> Result<AST, Box<EvalAltResult>> {
        if overrides.is_empty() {
            return Ok(self.rhai.compile(source)?);
        }
        let level = self.rhai.optimization_level();
        self.rhai.set_optimization_level(OptimizationLevel::None);
        let ast = self.rhai.compile(source);
        self.rhai.set_optimization_level(level);
        let ast = ast?;

        let mut statements = ast.statements().to_vec();
        let mut replaced = HashSet::new();
        for statement in &mut statements {
            let Stmt::Var(var, flags, position) = statement else {
                continue;
            };
            let name = var.0.name.as_str();
            let Some(value) = overrides.get(name) else {
                continue;
            };
            if !flags.contains(ASTFlags::CONSTANT) {
                return Err(runtime_error(
                    format!("cannot override `{name}`: it is a let, not a const"),
                    *position,
                ));
            }
            replaced.insert(name.to_owned());
            var.1 = Expr::from_dynamic(dynamic(value), var.1.position());
        }
        if let Some(name) = overrides.keys().find(|name| !replaced.contains(*name)) {
            return Err(runtime_error(
                format!("cannot override `{name}`: the script has no top-level const of that name"),
                Position::NONE,
            ));
        }
        let ast = AST::new(statements, ast.shared_lib().clone());
        Ok(self.rhai.optimize_ast(&Scope::new(), ast, level))
    }

    /// The extension a script called, when `error` is that it is missing.
    fn extension<'a>(&self, error: &'a EvalAltResult) -> Option<&'a str> {
        let EvalAltResult::ErrorFunctionNotFound(signature, _) = diagnostic::innermost(error)
        else {
            return None;
        };
        // Rhai's signature is the name, a space, then the argument types.
        let name = signature.split([' ', '(']).next()?;
        self.extensions.contains(name).then_some(name)
    }
}

/// A JSON value as a script's: a number written without a point or an
/// exponent as an integer, any other as a float, an object as a map, null
/// as `()`.
fn dynamic(value: &Value) -> Dynamic {
    match value {
        Value::Null => Dynamic::UNIT,
        Value::Bool(b) => Dynamic::from_bool(*b),
        Value::Number(n) => n.as_i64().map_or_else(
            || Dynamic::from_float(n.as_f64().unwrap_or(f64::NAN)),
            Dynamic::from_int,
        ),
        Value::String(s) => s.as_str().into(),
        Value::Array(items) => Dynamic::from_array(items.iter().map(dynamic).collect()),
        Value::Object(fields) => Dynamic::from_map(
            fields
                .iter()
                .map(|(name, value)| (name.as_str().into(), dynamic(value)))
                .collect(),
        ),
    }
}

/// fidget's engine with what both dialects add: `draw` and `draw_rgb`,
/// imports, a higher limit of operations, counted, and `print` and `debug`
/// kept.
fn engine(
    dialect: Dialect,
    modules: Option<PathBuf>,
) -> (rhai::Engine, Arc<Mutex<Run>>, Arc<AtomicU64>) {
    let mut rhai = fidget::rhai::engine();
    let run = Arc::new(Mutex::new(Run::default()));
    register_draw(&mut rhai, &run, dialect);
    let operations = Arc::new(AtomicU64::new(0));
    let counted = operations.clone();
    rhai.on_progress(move |count| {
        counted.store(count, Ordering::Relaxed);
        (count > MAX_OPERATIONS).then(|| {
            Dynamic::from(format!(
                "the script ran more than {MAX_OPERATIONS} operations; is a loop endless?"
            ))
        })
    });
    let output = run.clone();
    rhai.on_print(move |text| lock(&output).print(text));
    let output = run.clone();
    rhai.on_debug(move |text, _, _| lock(&output).print(text));
    rhai.set_module_resolver(Resolver {
        dialect,
        modules,
        importing: Mutex::default(),
        run: run.clone(),
    });
    (rhai, run, operations)
}

impl Run {
    fn print(&mut self, text: &str) {
        for line in text.lines() {
            if self.output.len() < MAX_OUTPUT {
                self.output.push(line.to_owned());
            } else {
                self.dropped += 1;
            }
        }
    }

    fn here(&self, ctx: &NativeCallContext) -> Location {
        Location::new(ctx.call_position(), ctx.call_source(), self.main.as_deref())
            .unwrap_or_else(Location::start)
    }

    fn read(&mut self, file: PathBuf) {
        if !self.files.contains(&file) {
            self.files.push(file);
        }
    }
}

// --- Script API ---

fn runtime_error(message: String, position: Position) -> Box<EvalAltResult> {
    EvalAltResult::ErrorRuntime(message.into(), position).into()
}

/// Registers `draw` and `draw_rgb`, any number of times as fidget's viewer
/// takes them; in the fidget dialect `draw` takes no options.  The script
/// API's docs are in `docs/script.toml`.
fn register_draw(engine: &mut rhai::Engine, run: &Arc<Mutex<Run>>, dialect: Dialect) {
    let state = run.clone();
    let draw = Arc::new(
        move |ctx: &NativeCallContext, shape: Dynamic, color: Option<[f32; 3]>, role: Role| {
            let tree = Tree::from_dynamic(ctx, shape, None)?;
            let mut run = lock(&state);
            let at = run.here(ctx);
            run.drawn.push(Drawn {
                tree,
                color,
                role,
                at,
            });
            Ok::<_, Box<EvalAltResult>>(())
        },
    );

    let plain = draw.clone();
    FuncRegistration::new("draw")
        .with_params_info(["shape: Tree"])
        .register_into_engine(engine, move |ctx: NativeCallContext, shape: Dynamic| {
            plain(&ctx, shape, None, Role::Cut)
        });

    if dialect == Dialect::Keycap {
        let with_role = draw.clone();
        FuncRegistration::new("draw")
            .with_params_info(["shape: Tree", "options: map"])
            .register_into_engine(
                engine,
                move |ctx: NativeCallContext, shape: Dynamic, options: Map| {
                    let role = role(options).map_err(|e| runtime_error(e, ctx.call_position()))?;
                    with_role(&ctx, shape, None, role)
                },
            );
    }

    FuncRegistration::new("draw_rgb")
        .with_params_info(["shape: Tree", "r: float", "g: float", "b: float"])
        .register_into_engine(
            engine,
            move |ctx: NativeCallContext, shape: Dynamic, r: Dynamic, g: Dynamic, b: Dynamic| {
                let mut color = [0.0; 3];
                for (c, v) in color.iter_mut().zip([r, g, b]) {
                    *c = f32::from_dynamic(&ctx, v, None)?.clamp(0.0, 1.0);
                }
                draw(&ctx, shape, Some(color), Role::Cut)
            },
        );
}

/// The role `draw`'s map of options gives.
fn role(options: Map) -> Result<Role, String> {
    let mut role = Role::Cut;
    for (key, value) in options {
        if key != "role" {
            return Err(format!("draw: no option {key:?}; the only option is role"));
        }
        let name = value.into_string().unwrap_or_default();
        role = Role::ALL
            .into_iter()
            .find(|r| r.name() == name)
            .ok_or_else(|| format!("draw: role is cut, score or engrave, not {name:?}"))?;
    }
    Ok(role)
}

/// Registers `bounds` and `resolution`, which only the keycap dialect has.
fn register_api(engine: &mut rhai::Engine, run: &Arc<Mutex<Run>>) {
    let state = run.clone();
    FuncRegistration::new("bounds")
        .with_params_info(["lower: Array", "upper: Array"])
        .register_into_engine(
            engine,
            move |ctx: NativeCallContext, lower: Dynamic, upper: Dynamic| {
                let position = ctx.call_position();
                let lower = corner(&ctx, lower, "lower")?;
                let upper = corner(&ctx, upper, "upper")?;
                if let Some(axis) = (0..3).find(|&i| lower[i] >= upper[i]) {
                    let name = ["x", "y", "z"][axis];
                    return Err(runtime_error(
                        format!("bounds are empty on {name}: lower must be below upper"),
                        position,
                    ));
                }
                let mut run = lock(&state);
                if run.bounds.is_some() {
                    return Err(runtime_error("bounds are already set".into(), position));
                }
                run.bounds = Some(Box3 { lower, upper });
                Ok(())
            },
        );

    let state = run.clone();
    FuncRegistration::new("resolution")
        .with_params_info(["cells: float"])
        .register_into_engine(engine, move |ctx: NativeCallContext, cells: Dynamic| {
            let cells = f32::from_dynamic(&ctx, cells, None)?;
            if !(cells.is_finite() && cells > 0.0) {
                return Err(runtime_error(
                    format!("resolution must be positive, not {cells}"),
                    ctx.call_position(),
                ));
            }
            lock(&state).resolution = Some(f64::from(cells));
            Ok(())
        });
}

// --- Text and SVG ---

/// Registers `text` and `svg`, each with and without its map of options.
fn register_outlines(engine: &mut rhai::Engine, run: &Arc<Mutex<Run>>) {
    let fonts = Arc::new(Fonts::default());

    let (state, installed) = (run.clone(), fonts.clone());
    let text = Arc::new(
        move |ctx: &NativeCallContext, string: &str, options: Option<Map>| {
            let failed = |error| runtime_error(error, ctx.call_position());
            let options = text::Options::new(options).map_err(failed)?;
            let (tree, file) =
                text::text(&installed, string, &options, &base(ctx)).map_err(failed)?;
            if let Some(file) = file {
                lock(&state).read(file);
            }
            Ok::<_, Box<EvalAltResult>>(tree)
        },
    );
    let plain = text.clone();
    FuncRegistration::new("text")
        .with_params_info(["string: string", "Tree"])
        .register_into_engine(engine, move |ctx: NativeCallContext, s: ImmutableString| {
            plain(&ctx, &s, None)
        });
    FuncRegistration::new("text")
        .with_params_info(["string: string", "options: map", "Tree"])
        .register_into_engine(
            engine,
            move |ctx: NativeCallContext, s: ImmutableString, options: Map| {
                text(&ctx, &s, Some(options))
            },
        );

    let state = run.clone();
    let svg = Arc::new(
        move |ctx: &NativeCallContext, path: &str, options: Option<Map>| {
            let failed = |error| runtime_error(error, ctx.call_position());
            let options = svg::Options::new(options).map_err(failed)?;
            let file = base(ctx).join(path);
            let file = file.canonicalize().unwrap_or(file);
            // Listed before it is read, so that its arrival reloads too
            lock(&state).read(file.clone());
            svg::svg(&fonts, &file, &options).map_err(failed)
        },
    );
    let plain = svg.clone();
    FuncRegistration::new("svg")
        .with_params_info(["path: string", "Tree"])
        .register_into_engine(engine, move |ctx: NativeCallContext, p: ImmutableString| {
            plain(&ctx, &p, None)
        });
    FuncRegistration::new("svg")
        .with_params_info(["path: string", "options: map", "Tree"])
        .register_into_engine(
            engine,
            move |ctx: NativeCallContext, p: ImmutableString, options: Map| {
                svg(&ctx, &p, Some(options))
            },
        );
}

/// The directory a call's relative paths start from: its file's, or the
/// working directory's for a script without one.
fn base(ctx: &NativeCallContext) -> PathBuf {
    ctx.call_source()
        .and_then(|s| Path::new(s).parent())
        .map(Path::to_path_buf)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default()
}

/// A corner of `bounds`: `[x, y, z]`, or `[x, y]` with z = 0.
fn corner(
    ctx: &NativeCallContext,
    value: Dynamic,
    name: &str,
) -> Result<[f64; 3], Box<EvalAltResult>> {
    let position = ctx.call_position();
    let wrong = || {
        runtime_error(
            format!("bounds' {name} corner must be [x, y] or [x, y, z]"),
            position,
        )
    };
    let v = Vec3::from_dynamic(ctx, value, None).map_err(|_| wrong())?;
    let out = [v.x, v.y, v.z].map(f64::from);
    if !out.iter().all(|c| c.is_finite()) {
        return Err(wrong());
    }
    Ok(out)
}

// --- Imports ---

/// The prefix of the prelude's modules' names.
const MODULES: &str = "keycap/";

/// Resolves `import "name"` relative to the importing file, or to the
/// working directory for a script without one: a name with an extension as
/// it is, one without it with `.keycap` (in the keycap dialect), then
/// `.fidget`, then `.rhai`.  Modules are evaluated afresh on every run, so
/// that edits to them show.
///
/// In the keycap dialect, `keycap/<name>` is the prelude's module
/// `modules/<name>.rhai`, wherever the importing file is; the prefix is
/// reserved, so that a file of the same name beside it cannot shadow one.
struct Resolver {
    dialect: Dialect,
    /// The prelude's modules, for `keycap/<name>`
    modules: Option<PathBuf>,
    /// The files being imported, outermost first, to catch cycles
    importing: Mutex<Vec<PathBuf>>,
    /// The run, to note the files it imports
    run: Arc<Mutex<Run>>,
}

impl Resolver {
    fn find(&self, source: Option<&str>, path: &str) -> Option<PathBuf> {
        if self.dialect == Dialect::Keycap
            && let Some(name) = path.strip_prefix(MODULES)
        {
            let file = self.modules.as_ref()?.join(name).with_extension("rhai");
            return file.is_file().then(|| file.canonicalize().unwrap_or(file));
        }
        let base = source
            .and_then(|s| Path::new(s).parent())
            .map(Path::to_path_buf)
            .or_else(|| std::env::current_dir().ok())?;
        let named = base.join(path);
        let found = if named.extension().is_some() {
            Some(named).filter(|p| p.is_file())
        } else {
            let extensions: &[&str] = match self.dialect {
                Dialect::Fidget => &["fidget", "rhai"],
                Dialect::Keycap => &["keycap", "fidget", "rhai"],
            };
            extensions
                .iter()
                .map(|extension| named.with_extension(extension))
                .find(|p| p.is_file())
        }?;
        Some(found.canonicalize().unwrap_or(found))
    }
}

impl ModuleResolver for Resolver {
    fn resolve(
        &self,
        engine: &rhai::Engine,
        source: Option<&str>,
        path: &str,
        position: Position,
    ) -> Result<rhai::Shared<Module>, Box<EvalAltResult>> {
        let Some(file) = self.find(source, path) else {
            if self.dialect == Dialect::Fidget && path.starts_with(MODULES) {
                return Err(runtime_error(
                    format!("`{path}` is a keycap module: rename the file to .keycap"),
                    position,
                ));
            }
            return Err(EvalAltResult::ErrorModuleNotFound(path.into(), position).into());
        };
        lock(&self.run).read(file.clone());
        {
            let mut importing = self
                .importing
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if importing.contains(&file) {
                let chain: Vec<_> = importing
                    .iter()
                    .chain([&file])
                    .map(|p| p.file_name().unwrap_or_default().to_string_lossy())
                    .collect();
                return Err(runtime_error(
                    format!("import cycle: {}", chain.join(" -> ")),
                    position,
                ));
            }
            importing.push(file.clone());
        }
        let main = source.map(str::to_owned) == lock(&self.run).main;
        let result = module(engine, &file, |ast| {
            if main {
                let functions = script_fns(ast, Some(&file), true);
                lock(&self.run).imports.push((path.to_owned(), functions));
            }
        });
        let result = result.map(Into::into).map_err(|error| {
            let name = file.to_string_lossy().into_owned();
            EvalAltResult::ErrorInModule(name, error, position).into()
        });
        self.importing
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop();
        result
    }
}

/// The module the script `file` makes, named by its path so that its
/// errors and imports know where they are; `compiled` sees its AST.
fn module(
    engine: &rhai::Engine,
    file: &Path,
    compiled: impl FnOnce(&AST),
) -> Result<Module, Box<EvalAltResult>> {
    let name = file.to_string_lossy();
    let text = std::fs::read_to_string(file)
        .map_err(|error| runtime_error(format!("cannot read {name}: {error}"), Position::NONE))?;
    let mut ast = engine.compile(text)?;
    ast.set_source(name.as_ref());
    compiled(&ast);
    Module::eval_ast_as_new(Scope::new(), &ast, engine)
}

// --- Prelude ---

/// The prelude: its files joined into one module, so that they share their
/// private functions, and the way back from the joined text to them.
#[derive(Default)]
pub struct Prelude {
    /// The name the joined module goes by: the prelude's directory
    name: String,
    /// Each file and the line of the joined text it starts on
    files: Vec<(usize, PathBuf)>,
    /// The file, by stem, that defines each function
    pub functions: HashMap<String, String>,
    /// Its files, then its modules, as the reference sets them out
    pub sections: Vec<Section>,
    /// Problems loading it, as warnings naming their files
    pub problems: Vec<Diagnostic>,
}

/// A file of the prelude or of its modules, as a section of the reference.
pub struct Section {
    /// Where it lies in keycap's repository, `prelude/csg.rhai`
    pub file: String,
    /// What its functions make, as the `// kind:` line of its header says
    pub kind: Option<String>,
    /// A module's name, which a script imports it as in its examples, as
    /// the `//     import "keycap/screws" as screws;` line of its header
    /// says, or else its file's
    pub module: Option<String>,
    /// Its public functions, in the order it defines them; a module's
    /// under its name, `screws::hole`
    pub names: Vec<String>,
    /// A module's public functions, with their doc comments
    pub functions: Vec<ScriptFn>,
}

impl Section {
    /// The section of `file`, whose text is `text`; `ast` is a module's
    /// compiled text.
    fn new(file: &Path, text: &str, ast: Option<&AST>) -> Self {
        let stem = file.file_stem().unwrap_or_default();
        let imported = imports_in_text(text)
            .into_iter()
            .find(|(path, _)| Path::new(path).file_stem() == Some(stem))
            .map(|(_, name)| name);
        let module = ast.map(|_| imported.unwrap_or_else(|| stem.to_string_lossy().into()));
        let qualified = |name: &str| match &module {
            Some(module) => format!("{module}::{name}"),
            None => name.to_owned(),
        };
        let mut names: Vec<String> = vec![];
        for line in text.lines() {
            let name = line
                .strip_prefix("fn ")
                .and_then(|l| l.split_once('('))
                .map(|(name, _)| name.trim());
            if let Some(name) = name.filter(|n| !n.starts_with('_')).map(qualified)
                && !names.contains(&name)
            {
                names.push(name);
            }
        }
        let mut functions = ast.map_or_else(Vec::new, |ast| script_fns(ast, Some(file), true));
        for function in &mut functions {
            function.name = qualified(&function.name);
        }
        let name = file.file_name().unwrap_or_default().to_string_lossy();
        Section {
            file: match module {
                Some(_) => format!("prelude/modules/{name}"),
                None => format!("prelude/{name}"),
            },
            kind: text
                .lines()
                .find_map(|l| l.strip_prefix("// kind: "))
                .map(|kind| kind.trim().to_owned()),
            module,
            names,
            functions,
        }
    }
}

impl Prelude {
    /// Joins every `.rhai` file in `dir`, in name order, into one global
    /// module of `engine`.  A file that does not parse alone is left out,
    /// so that one typo leaves the rest working.
    fn load(engine: &mut rhai::Engine, dir: &Path) -> Self {
        let mut prelude = Prelude {
            name: dir.to_string_lossy().into_owned(),
            ..Prelude::default()
        };
        let mut files: Vec<PathBuf> = match std::fs::read_dir(dir) {
            Ok(entries) => entries
                .filter_map(|entry| Some(entry.ok()?.path()))
                .filter(|p| p.extension().is_some_and(|e| e == "rhai"))
                .collect(),
            Err(error) => {
                let error = runtime_error(format!("cannot read it: {error}"), Position::NONE);
                prelude.warn(&error, dir);
                return prelude;
            }
        };
        files.sort();
        let mut joined = String::new();
        for file in files {
            let parsed = std::fs::read_to_string(&file)
                .map_err(|error| runtime_error(format!("cannot read it: {error}"), Position::NONE))
                .and_then(|text| Ok((engine.compile(&text)?, text)));
            let (ast, mut text) = match parsed {
                Ok(parsed) => parsed,
                Err(error) => {
                    prelude.warn(&error, &file);
                    continue;
                }
            };
            let stem = file.file_stem().unwrap_or_default().to_string_lossy();
            for function in ast.iter_functions() {
                prelude
                    .functions
                    .insert(function.name.to_owned(), stem.to_string());
            }
            prelude.sections.push(Section::new(&file, &text, None));
            if !text.ends_with('\n') {
                text.push('\n');
            }
            prelude.files.push((joined.lines().count() + 1, file));
            joined.push_str(&text);
        }
        let module = engine
            .compile(&joined)
            .map_err(Into::into)
            .and_then(|mut ast| {
                ast.set_source(prelude.name.as_str());
                Module::eval_ast_as_new(Scope::new(), &ast, engine)
            });
        match module {
            Ok(module) => {
                engine.register_global_module(module.into());
            }
            Err(error) => {
                let name = PathBuf::from(&prelude.name);
                prelude.warn(&error, &name);
            }
        }
        let modules = module_sections(engine, &dir.join("modules"));
        prelude.sections.extend(modules);
        prelude
    }

    /// Records `error`, which happened in `file` unless it says otherwise.
    fn warn(&mut self, error: &EvalAltResult, file: &Path) {
        let mut diagnostic = Diagnostic::from_error(error, None);
        diagnostic
            .at
            .file
            .get_or_insert_with(|| file.to_string_lossy().into_owned());
        self.relocate(&mut diagnostic);
        diagnostic.severity = Severity::Warning;
        diagnostic.message = format!("prelude: {}", diagnostic.message);
        eprintln!(
            "keycap-server: {}:{}: {}",
            diagnostic.at.file.as_deref().unwrap_or_default(),
            diagnostic.at.line,
            diagnostic.message
        );
        self.problems.push(diagnostic);
    }

    /// Moves the places in `diagnostic` that are in the joined module to
    /// the files they came from.
    fn relocate(&self, diagnostic: &mut Diagnostic) {
        self.relocate_location(&mut diagnostic.at);
        for frame in &mut diagnostic.trace {
            self.relocate_location(&mut frame.at);
        }
    }

    fn relocate_location(&self, at: &mut Location) {
        if at.file.as_deref() != Some(self.name.as_str()) {
            return;
        }
        if let Some((start, file)) = self.files.iter().rev().find(|(start, _)| *start <= at.line) {
            at.line = at.line - start + 1;
            at.file = Some(file.to_string_lossy().into_owned());
        }
    }
}

/// The sections of the modules in `dir`, in name order.  A module that
/// does not parse is left out; importing it reports the error.
fn module_sections(engine: &rhai::Engine, dir: &Path) -> Vec<Section> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(|entry| Some(entry.ok()?.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "rhai"))
        .collect();
    files.sort();
    files
        .iter()
        .filter_map(|file| {
            let text = std::fs::read_to_string(file).ok()?;
            let ast = engine.compile(&text).ok()?;
            Some(Section::new(file, &text, Some(&ast)))
        })
        .collect()
}
