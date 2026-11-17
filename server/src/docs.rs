// SPDX-License-Identifier: MPL-2.0

//! The `docs` reply: fidget's shapes from their own reflection, and every
//! function a script calls by name, merged with the hand-written docs in
//! `docs/`; and the files of the reference, each a section of it.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use facet::Facet;
use fidget::context::Tree;
use fidget::shapes::types::{Type, Value as ShapeValue};
use fidget::shapes::{ShapeVisitor, visit_shapes};
use heck::ToSnakeCase;
use serde::Deserialize;
use serde_json::{Value, json};
use toml::Spanned;

use crate::script::{Dialect, Engine, ScriptFn};

/// The hand-written docs of fidget's built-ins and of keycap's script API,
/// a file per section of the reference: its `kind`, what its names make,
/// then a table per name, in the reference's order.  A table may have
/// `signatures`, which replace the generated ones; `doc`, written as the
/// prelude's `///` comments are, which replaces a shape's own; `aliases`,
/// other names the entry describes, each given a copy of it; `category`,
/// the group C-c C-d lists it under; and `prefer`, the keycap call a
/// `.keycap` script had better write instead of a fidget built-in, with
/// `why`, in a line.
const WRITTEN: [(&str, &str); 13] = [
    ("shapes-2d", include_str!("../docs/shapes-2d.toml")),
    ("shapes-3d", include_str!("../docs/shapes-3d.toml")),
    ("combinations", include_str!("../docs/combinations.toml")),
    ("transforms", include_str!("../docs/transforms.toml")),
    ("extrusion", include_str!("../docs/extrusion.toml")),
    ("constants", include_str!("../docs/constants.toml")),
    ("arithmetic", include_str!("../docs/arithmetic.toml")),
    ("comparison", include_str!("../docs/comparison.toml")),
    ("math", include_str!("../docs/math.toml")),
    ("random", include_str!("../docs/random.toml")),
    ("remap", include_str!("../docs/remap.toml")),
    ("vectors", include_str!("../docs/vectors.toml")),
    ("script", include_str!("../docs/script.toml")),
];

/// The functions of the script API registered in `script`, and the
/// categories they go under; in the fidget dialect, `draw` and `draw_rgb` are
/// fidget's, as its CLI and viewer register them
const OWN: [(&str, &str); 6] = [
    ("draw", "keycap"),
    ("draw_rgb", "keycap"),
    ("bounds", "keycap"),
    ("resolution", "keycap"),
    ("text", "keycap: text and SVG"),
    ("svg", "keycap: text and SVG"),
];

/// A file of `docs/`, a section of the reference
struct WrittenFile {
    /// Where it lies in keycap's repository, `server/docs/math.toml`
    file: String,
    /// What its names make, as its `kind` says
    kind: Option<String>,
    /// Its names and their docs, in its order
    names: Vec<(String, Written)>,
}

#[derive(Deserialize)]
struct Written {
    signatures: Option<Vec<String>>,
    /// Empty for a name that has only `prefer`
    #[serde(default)]
    doc: String,
    /// Other names it describes, as `PI`'s entry describes every constant
    #[serde(default)]
    aliases: Vec<String>,
    category: Option<String>,
    /// The keycap call a `.keycap` script had better write instead, and why
    prefer: Option<String>,
    why: Option<String>,
}

impl Written {
    /// `prefer` and `why` onto a shape's or function's JSON, in the keycap
    /// dialect, which has the prelude they name.
    fn prefer(&self, value: &mut Value, dialect: Dialect) {
        if let (Some(prefer), Dialect::Keycap) = (&self.prefer, dialect) {
            value["prefer"] = json!(prefer);
            value["why"] = json!(self.why);
        }
    }
}

/// The files of `docs/`; one that does not parse is left empty, a table
/// that does not, out.
fn written_files() -> Vec<WrittenFile> {
    WRITTEN
        .iter()
        .map(|(stem, text)| {
            let file = format!("server/docs/{stem}.toml");
            let table: BTreeMap<String, Spanned<toml::Value>> = toml::from_str(text)
                .unwrap_or_else(|error| {
                    eprintln!("keycap-server: {file}: {error}");
                    BTreeMap::new()
                });
            let mut kind = None;
            let mut names = vec![];
            for (name, value) in table {
                let start = value.span().start;
                match (name.as_str(), value.into_inner()) {
                    ("kind", toml::Value::String(k)) => kind = Some(k),
                    (_, value) => match value.try_into::<Written>() {
                        Ok(written) => names.push((start, name, written)),
                        Err(error) => eprintln!("keycap-server: {file}: [{name}]: {error}"),
                    },
                }
            }
            names.sort_by_key(|(start, ..)| *start);
            let names = names.into_iter().map(|(_, n, w)| (n, w)).collect();
            WrittenFile { file, kind, names }
        })
        .collect()
}

/// The hand-written docs by name, with the file that has them.
fn written(files: &[WrittenFile]) -> BTreeMap<&str, (&Written, &WrittenFile)> {
    files
        .iter()
        .flat_map(|file| file.names.iter().map(move |(n, w)| (n.as_str(), (w, file))))
        .collect()
}

/// The fidget built-ins with a better keycap call: name, call and why.
pub fn preferred() -> Vec<(String, String, String)> {
    written_files()
        .into_iter()
        .flat_map(|file| file.names)
        .filter_map(|(name, w)| Some((name, w.prefer?, w.why?)))
        .collect()
}

pub fn docs(engine: &Engine) -> Value {
    let files = written_files();
    let written = written(&files);
    let mut shapes = Shapes(vec![]);
    visit_shapes(&mut shapes);
    for shape in &mut shapes.0 {
        let name = shape["name"].as_str().unwrap_or_default().to_owned();
        if let Some((w, file)) = written.get(name.as_str()) {
            if !w.doc.trim().is_empty() {
                shape["doc"] = json!(w.doc.trim());
            }
            place(shape, &file.file, file.kind.as_deref());
            w.prefer(shape, engine.dialect());
        }
    }
    let names: HashSet<String> = shapes
        .0
        .iter()
        .filter_map(|s| s["name"].as_str().map(str::to_owned))
        .collect();
    let functions = functions(engine, &names, &written);

    // The sections of the reference, with the names each has in this
    // dialect, in their order
    let described: HashSet<&str> = shapes
        .0
        .iter()
        .chain(&functions)
        .filter_map(|e| e["name"].as_str())
        .collect();
    let mut sections: Vec<Value> = files
        .iter()
        .map(|file| {
            let names = file.names.iter().map(|(n, _)| n.as_str());
            let names: Vec<&str> = names.filter(|n| described.contains(n)).collect();
            json!({"file": file.file, "kind": file.kind, "names": names})
        })
        .collect();
    let mut modules = vec![];
    for section in &engine.prelude().sections {
        let mut value = json!({"file": section.file, "kind": section.kind, "names": section.names});
        if let Some(module) = &section.module {
            value["module"] = json!(module);
            for mut function in script_functions(&section.functions) {
                function["source"] = json!("module");
                function["category"] = json!(format!("Module: {module}"));
                place(&mut function, &section.file, section.kind.as_deref());
                modules.push(function);
            }
        }
        sections.push(value);
    }
    json!({
        "shapes": shapes.0,
        "functions": functions,
        "modules": modules,
        "sections": sections,
    })
}

/// The `file` of the reference that describes an entry, and the `kind` of
/// what it makes, onto its JSON.
fn place(value: &mut Value, file: &str, kind: Option<&str>) {
    value["file"] = json!(file);
    value["kind"] = json!(kind);
}

// --- Shapes ---

struct Shapes(Vec<Value>);

impl ShapeVisitor for Shapes {
    fn visit<T: Facet<'static> + Clone + Send + Sync + Into<Tree> + 'static>(&mut self) {
        let facet::Type::User(facet::UserType::Struct(s)) = T::SHAPE.ty else {
            return;
        };
        let fields: Vec<Field> = s
            .fields
            .iter()
            .map(|f| {
                let tag = Type::try_from(f.shape().id).ok();
                let default = match (tag, f.default) {
                    // SAFETY: the tag was read off this field's own type, as
                    // fidget's bindings do when they build the shape.
                    (Some(tag), Some(default)) => {
                        Some(literal(&unsafe { tag.build_from_default_fn(default) }))
                    }
                    _ => None,
                };
                Field {
                    name: f.name,
                    tag,
                    ty: tag.map_or_else(|| f.shape().to_string(), type_name),
                    default,
                    doc: paragraphs(f.doc),
                }
            })
            .collect();
        let name = T::SHAPE.to_string().to_snake_case();
        self.0.push(json!({
            "signatures": shape_signatures(&name, &fields),
            "name": name,
            "doc": paragraphs(T::SHAPE.doc),
            "fields": fields.iter().map(|f| json!({
                "name": f.name,
                "type": f.ty,
                "default": f.default,
                "doc": f.doc,
            })).collect::<Vec<_>>(),
        }));
    }
}

/// A shape's field
struct Field {
    name: &'static str,
    tag: Option<Type>,
    /// Its type in the reference's notation
    ty: String,
    /// Its default as a script would write it
    default: Option<String>,
    doc: String,
}

impl Field {
    /// The field as a parameter: `name: type`, `= default` if it has one
    /// and it may be left `optional`.
    fn param(&self, optional: bool) -> String {
        match &self.default {
            Some(default) if optional => format!("{}: {} = {default}", self.name, self.ty),
            _ => format!("{}: {}", self.name, self.ty),
        }
    }
}

/// A shape field's type in the reference's notation.
fn type_name(tag: Type) -> String {
    match tag {
        Type::Float => "number".into(),
        Type::Tree => "Shape".into(),
        Type::VecTree => "Shape[]".into(),
        other => other.to_string(),
    }
}

/// How scripts call a shape, as fidget's bindings register it: by
/// position, as a method of its first field when that is a shape, and with
/// a map of its fields.  By position, the fields with a default may be left
/// out only when no two fields have the same type; else every one comes,
/// in order, and only the map leaves them out.  A shape of one array of
/// shapes also takes them as arguments; a transform, one shape and other
/// fields, takes the others as a map, every one of them.
fn shape_signatures(name: &str, fields: &[Field]) -> Vec<String> {
    let distinct = fields
        .iter()
        .all(|f| fields.iter().filter(|g| g.tag == f.tag).count() == 1);
    let params = |fields: &[Field]| {
        fields
            .iter()
            .map(|f| f.param(distinct))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let map = |fields: &[Field], optional: bool| {
        let keys: Vec<String> = fields
            .iter()
            .map(|f| {
                let mark = if optional && f.default.is_some() {
                    "?"
                } else {
                    ""
                };
                format!("{}{mark}: {}", f.name, f.ty)
            })
            .collect();
        format!("#{{ {} }}", keys.join(", "))
    };
    if let [field] = fields
        && field.tag == Some(Type::VecTree)
    {
        return vec![
            format!("{name}(...{}: Shape[]): Shape", field.name),
            format!("{name}({}: Shape[]): Shape", field.name),
        ];
    }
    let mut signatures = vec![format!("{name}({}): Shape", params(fields))];
    let shapes = fields.iter().filter(|f| f.tag == Some(Type::Tree)).count();
    if let [first, rest @ ..] = fields
        && first.tag == Some(Type::Tree)
    {
        signatures.push(format!("{}.{name}({}): Shape", first.name, params(rest)));
        if shapes == 1 && !rest.is_empty() {
            signatures.push(format!(
                "{}.{name}({}): Shape",
                first.name,
                map(rest, false)
            ));
        }
    }
    let defaults = fields.iter().any(|f| f.default.is_some());
    if shapes == 0 || (defaults && !distinct) {
        signatures.push(format!("{name}({}): Shape", map(fields, true)));
    }
    signatures
}

/// A default value as a script would write it.
fn literal(value: &ShapeValue) -> String {
    let list = |v: &[f32]| {
        format!(
            "[{}]",
            v.iter().map(f32::to_string).collect::<Vec<_>>().join(", ")
        )
    };
    match value {
        ShapeValue::Float(f) => f.to_string(),
        ShapeValue::Vec2(v) => list(&[v.x, v.y]),
        ShapeValue::Vec3(v) => list(&[v.x, v.y, v.z]),
        ShapeValue::Vec4(v) => list(&[v.x, v.y, v.z, v.w]),
        ShapeValue::Axis(a) => list(&[a.vec().x, a.vec().y, a.vec().z]),
        ShapeValue::Plane(p) => {
            let a = p.axis.vec();
            format!(
                "#{{axis: {}, offset: {}}}",
                list(&[a.x, a.y, a.z]),
                p.offset
            )
        }
        ShapeValue::Tree(_) => "a tree".into(),
        ShapeValue::VecTree(v) if v.is_empty() => "[]".into(),
        ShapeValue::VecTree(_) => "an array of trees".into(),
    }
}

/// Doc comment lines as paragraphs: lines joined, blank lines kept.
fn paragraphs(lines: &[&str]) -> String {
    lines
        .iter()
        .map(|l| l.trim())
        .collect::<Vec<_>>()
        .split(|l| l.is_empty())
        .filter(|p| !p.is_empty())
        .map(|p| p.join(" "))
        .collect::<Vec<_>>()
        .join("\n\n")
}

// --- Functions ---

/// What is known of one function name
#[derive(Default)]
struct Entry {
    /// Native signatures, as scripts see their types
    signatures: BTreeSet<String>,
    /// The parameters of each script definition
    definitions: Vec<Vec<String>>,
    comments: Vec<String>,
    /// The signatures and types the doc comments give
    typed: Vec<String>,
    types: Vec<String>,
    /// Whether a native definition is not Rhai's own
    fidget: bool,
}

impl Entry {
    /// Keeps a doc comment of `name`, its signatures apart.
    fn comment(&mut self, name: &str, comment: &str) {
        let (typed, types, comment) = split_signatures(name, &uncomment(comment));
        for (kept, new) in [(&mut self.typed, typed), (&mut self.types, types)] {
            for line in new {
                if !kept.contains(&line) {
                    kept.push(line);
                }
            }
        }
        if !comment.is_empty() && !self.comments.contains(&comment) {
            self.comments.push(comment);
        }
    }

    /// How a script calls `name`: the doc comments' signatures with their
    /// method forms, or else its definitions, then its native signatures.
    fn signatures(&self, name: &str) -> Vec<String> {
        if self.typed.is_empty() {
            definitions(name, &self.definitions)
                .chain(self.signatures.iter().cloned())
                .collect()
        } else {
            let methods = self
                .typed
                .iter()
                .filter_map(|signature| method(name, signature, &self.definitions));
            self.typed.iter().cloned().chain(methods).collect()
        }
    }

    /// The JSON of a function: `name`, `signatures`, `types` if it has
    /// any, and `doc`.
    fn describe(&self, name: &str, signatures: Vec<String>, doc: String) -> Value {
        let mut value = json!({"name": name, "signatures": signatures});
        if !self.types.is_empty() {
            value["types"] = json!(self.types);
        }
        value["doc"] = json!(doc);
        value
    }
}

/// Every function a script calls by name, grouped by name, and the
/// variables `docs/` describes: shape constructors (described with the
/// shapes), private and `_` functions, operators and Rhai's internal names
/// left out unless `docs/` describes them.
fn functions(
    engine: &Engine,
    shapes: &HashSet<String>,
    written: &BTreeMap<&str, (&Written, &WrittenFile)>,
) -> Vec<Value> {
    // Signatures a bare Rhai engine has are Rhai's own.
    let standard: HashSet<String> = metadata(&rhai::Engine::new())
        .into_iter()
        .filter_map(|f| Some(f.get("signature")?.as_str()?.to_owned()))
        .collect();
    let prelude = &engine.prelude().functions;
    let sections = &engine.prelude().sections;

    let mut entries: BTreeMap<String, Entry> = BTreeMap::new();
    for function in metadata(engine.rhai()) {
        let text = |key: &str| {
            function
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
        };
        let name = text("name");
        let callable = name.starts_with(char::is_alphabetic)
            && name.chars().all(|c| c.is_alphanumeric() || c == '_');
        let hidden = !callable || text("access") == "private";
        let undescribed = written.get(name).is_none_or(|(w, _)| w.doc.is_empty());
        if shapes.contains(name) || (hidden && undescribed) {
            continue;
        }
        let entry = entries.entry(name.to_owned()).or_default();
        let params = function
            .get("params")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if text("type") == "script" {
            let names = params
                .iter()
                .map(|p| p["name"].as_str().unwrap_or("_").to_owned());
            entry.definitions.push(names.collect());
        } else {
            entry.fidget |= !standard.contains(text("signature"));
            entry
                .signatures
                .insert(signature(name, &params, text("returnType")));
        }
        let comments = function.get("docComments").and_then(Value::as_array);
        for comment in comments.into_iter().flatten().filter_map(Value::as_str) {
            entry.comment(name, comment);
        }
    }
    // fidget's variables, which Rhai's metadata does not list
    for (name, (w, _)) in written {
        let variable = |s: &String| {
            s.split_once(": ")
                .is_some_and(|(n, _)| n == *name || w.aliases.iter().any(|a| a == n))
        };
        if let Some(signatures) = &w.signatures
            && signatures.iter().all(variable)
        {
            entries.entry((*name).to_owned()).or_default().fidget = true;
        }
    }

    entries
        .into_iter()
        .flat_map(|(name, entry)| {
            let file = prelude.get(&name);
            let keycap = engine.dialect() == Dialect::Keycap;
            let own = OWN.iter().find(|(n, _)| keycap && *n == name);
            let (source, category) = if let Some((_, category)) = own {
                ("keycap", (*category).to_owned())
            } else if let Some(file) = file {
                ("prelude", format!("Prelude: {file}"))
            } else if entry.fidget {
                ("fidget", "fidget".to_owned())
            } else {
                ("rhai", "Rhai".to_owned())
            };
            let written = written.get(name.as_str());
            let signatures = written
                .and_then(|(w, _)| w.signatures.clone())
                .unwrap_or_else(|| entry.signatures(&name));
            // A prelude function's own doc comment wins over the docs of
            // what it shadows.
            let doc = match written {
                Some((written, _)) if file.is_none() || entry.comments.is_empty() => {
                    written.doc.trim().to_owned()
                }
                _ => entry.comments.join("\n\n"),
            };
            let category = written
                .and_then(|(w, _)| w.category.clone())
                .unwrap_or(category);
            let mut value = entry.describe(&name, signatures, doc);
            value["source"] = json!(source);
            value["category"] = json!(category);
            let section = sections.iter().find(|s| s.names.contains(&name));
            match (section, written) {
                (Some(section), _) => place(&mut value, &section.file, section.kind.as_deref()),
                (None, Some((_, file))) => place(&mut value, &file.file, file.kind.as_deref()),
                (None, None) => {}
            }
            let mut aliases = vec![];
            if let Some((w, _)) = written {
                w.prefer(&mut value, engine.dialect());
                // An alias has a copy of the entry, under its own name.
                for alias in &w.aliases {
                    let mut copy = value.clone();
                    copy["name"] = json!(alias);
                    aliases.push(copy);
                }
                if !w.aliases.is_empty() {
                    value["aliases"] = json!(w.aliases);
                }
            }
            std::iter::once(value).chain(aliases)
        })
        .collect()
}

/// The functions a script defines and imports, as `docs` lists the
/// others, under the names the script calls them by.  An imported one,
/// `parts::peg`, has no method form: Rhai calls none by its module.
pub fn script_functions(functions: &[ScriptFn]) -> Vec<Value> {
    let bare = |name: &str| name.rsplit("::").next().unwrap_or(name).to_owned();
    let mut entries: BTreeMap<&str, (Entry, Option<String>)> = BTreeMap::new();
    for function in functions {
        let (entry, file) = entries.entry(&function.name).or_default();
        entry.definitions.push(function.params.clone());
        for comment in &function.comments {
            entry.comment(&bare(&function.name), comment);
        }
        *file = function.file.as_ref().map(|f| {
            let name = f.file_name().unwrap_or(f.as_os_str());
            name.to_string_lossy().into_owned()
        });
    }
    entries
        .into_iter()
        .map(|(name, (mut entry, file))| {
            // Rhai keeps them in no order; fewer parameters first
            entry.definitions.sort_by_key(Vec::len);
            let bare = bare(name);
            let module = &name[..name.len() - bare.len()];
            let signatures = entry
                .signatures(&bare)
                .into_iter()
                .filter(|s| module.is_empty() || s.starts_with(&format!("{bare}(")))
                .map(|s| format!("{module}{s}"))
                .collect();
            let mut value = entry.describe(name, signatures, entry.comments.join("\n\n"));
            value["source"] = json!(if file.is_some() { "import" } else { "script" });
            value["file"] = json!(file);
            value
        })
        .collect()
}

/// An engine's functions as Rhai's metadata lists them.
fn metadata(engine: &rhai::Engine) -> Vec<Value> {
    engine
        .gen_fn_metadata_to_json(true)
        .ok()
        .and_then(|json| serde_json::from_str::<Value>(&json).ok())
        .and_then(|mut v| v.get_mut("functions").map(Value::take))
        .and_then(|v| match v {
            Value::Array(functions) => Some(functions),
            _ => None,
        })
        .unwrap_or_default()
}

/// A native function's signature, in the types scripts see.
fn signature(name: &str, params: &[Value], returns: &str) -> String {
    let params: Vec<String> = params
        .iter()
        .map(|p| {
            let name = p["name"].as_str().map(|n| n.trim_start_matches("mut "));
            match (
                name.filter(|&n| n != "_"),
                p["type"].as_str().map(script_type),
            ) {
                (Some(name), Some(ty)) => format!("{name}: {ty}"),
                (Some(name), None) => name.to_owned(),
                (None, Some(ty)) => ty,
                (None, None) => "?".to_owned(),
            }
        })
        .collect();
    let returns = script_type(returns);
    let arrow = match returns.as_str() {
        "" | "()" => String::new(),
        returns => format!(" -> {returns}"),
    };
    format!("{name}({}){arrow}", params.join(", "))
}

/// The type a script sees for a Rust one: Rhai's names, fallible results
/// as what they return, one `int` and one `float` for every width.
fn script_type(rust: &str) -> String {
    let rust = rust
        .trim()
        .trim_start_matches("&mut ")
        .trim_start_matches('&');
    let (head, arguments) = match rust.split_once('<') {
        Some((head, rest)) => (head, rest.strip_suffix('>').unwrap_or(rest)),
        None => (rust, ""),
    };
    let head = head.rsplit("::").next().unwrap_or(head);
    // The first type argument, ending at its top level comma
    let first = || {
        let mut depth = 0;
        let end = arguments
            .char_indices()
            .find(|&(_, c)| {
                depth += match c {
                    '<' => 1,
                    '>' => -1,
                    _ => 0,
                };
                c == ',' && depth == 0
            })
            .map_or(arguments.len(), |(i, _)| i);
        script_type(&arguments[..end])
    };
    match head {
        "Result" | "Box" => first(),
        "Vec" => format!("[{}]", first()),
        "i8" | "i16" | "i32" | "i64" | "i128" | "isize" | "u8" | "u16" | "u32" | "u64" | "u128"
        | "usize" | "INT" => "int".into(),
        "f32" | "f64" | "FLOAT" => "float".into(),
        "String" | "ImmutableString" | "str" => "string".into(),
        "Array" => "array".into(),
        "Map" => "map".into(),
        "Blob" => "blob".into(),
        "Dynamic" => "?".into(),
        other => other.to_owned(),
    }
}

/// A script function's definitions; one that takes the parameters of
/// another but its first is that one called as a method.
fn definitions<'a>(
    name: &'a str,
    definitions: &'a [Vec<String>],
) -> impl Iterator<Item = String> + 'a {
    definitions.iter().map(move |params| {
        let receiver = definitions
            .iter()
            .find(|other| other.len() == params.len() + 1 && other[1..] == params[..]);
        match receiver {
            Some(other) => format!("{}.{name}({})", other[0], params.join(", ")),
            None => format!("{name}({})", params.join(", ")),
        }
    })
}

/// A doc comment's signatures of `name`, its types and the rest of it.
/// The signatures are its first lines, up to a blank one, when the first
/// starts with `name(`: there a line that starts `name(` or `type ` begins
/// a signature or a type, any other continues the one before.
fn split_signatures(name: &str, comment: &str) -> (Vec<String>, Vec<String>, String) {
    let call = format!("{name}(");
    if !comment.starts_with(&call) {
        return (vec![], vec![], comment.to_owned());
    }
    let (head, rest) = comment.split_once("\n\n").unwrap_or((comment, ""));
    let (mut signatures, mut types): (Vec<String>, Vec<String>) = (vec![], vec![]);
    let mut types_began = false;
    for line in head.lines() {
        if line.starts_with(&call) {
            signatures.push(line.to_owned());
            types_began = false;
        } else if line.starts_with("type ") {
            types.push(line.to_owned());
            types_began = true;
        } else {
            let last = if types_began {
                types.last_mut()
            } else {
                signatures.last_mut()
            };
            if let Some(last) = last {
                last.push('\n');
                last.push_str(line);
            }
        }
    }
    (signatures, types, rest.trim().to_owned())
}

/// The method form of a typed signature of `name`, `first.name(rest)`,
/// when its first parameter is a shape and one of its `definitions` takes
/// the parameters after it.  A definition that takes them but not a shape
/// is no method: `ease_in_pow(n)` is the easing as a function.
fn method(name: &str, signature: &str, definitions: &[Vec<String>]) -> Option<String> {
    let (params, after) = parameters(name, signature)?;
    let (first, rest) = params.split_first()?;
    let (_, first_type) = first.split_once(':')?;
    if !first_type.contains("Shape") {
        return None;
    }
    let names: Vec<&str> = rest.iter().map(|p| parameter_name(p)).collect();
    definitions
        .iter()
        .any(|d| d.iter().map(String::as_str).eq(names.iter().copied()))
        .then(|| {
            format!(
                "{}.{name}({}){after}",
                parameter_name(first),
                rest.join(", ")
            )
        })
}

/// The parameters of a typed signature of `name`, and what follows them.
fn parameters<'a>(name: &str, signature: &'a str) -> Option<(Vec<&'a str>, &'a str)> {
    let inner = signature.strip_prefix(name)?.strip_prefix('(')?;
    let mut params = vec![];
    let (mut depth, mut start) = (0, 0);
    for (i, c) in inner.char_indices() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' if depth == 0 => {
                let last = inner[start..i].trim();
                if !last.is_empty() {
                    params.push(last);
                }
                return Some((params, &inner[i + 1..]));
            }
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                params.push(inner[start..i].trim());
                start = i + 1;
            }
            _ => {}
        }
    }
    None
}

/// A typed parameter's name: `d` of `d: Tree`, `rest` of `...rest: T[]`.
fn parameter_name(param: &str) -> &str {
    let param = param.trim_start_matches("...");
    param.split([':', '?', '=']).next().unwrap_or(param).trim()
}

/// A doc comment's text without its `///` or `/** */` markers.
fn uncomment(comment: &str) -> String {
    let comment = comment.trim();
    if let Some(block) = comment.strip_prefix("/**") {
        return block.trim_end_matches("*/").trim().to_owned();
    }
    comment
        .lines()
        .map(|l| {
            let l = l.trim_start().trim_start_matches("///");
            l.strip_prefix(' ').unwrap_or(l)
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

#[cfg(test)]
mod test {
    use super::*;

    /// Every file of `docs/` parses, declares its kind and describes each
    /// of its names, once in all of them.
    #[test]
    fn written_docs_parse() {
        let mut seen = HashSet::new();
        for (stem, text) in WRITTEN {
            let table: toml::Table = toml::from_str(text).expect("valid TOML");
            let file = written_files().into_iter().find(|f| f.file.contains(stem));
            let file = file.expect("read");
            assert!(file.kind.is_some(), "{stem} declares no kind");
            assert_eq!(file.names.len() + 1, table.len(), "{stem} has a bad table");
            for (name, w) in &file.names {
                assert!(seen.insert(name.clone()), "{name} is described twice");
                assert!(
                    !w.doc.trim().is_empty() || (w.prefer.is_some() && w.why.is_some()),
                    "{name}"
                );
            }
        }
    }

    #[test]
    fn signatures_split_from_the_doc() {
        let comment = "f(a: Shape, d: Tree): Shape\ntype T = #{\n  k: number,\n}\n\nGrows `a`.";
        let (signatures, types, doc) = split_signatures("f", comment);
        assert_eq!(signatures, ["f(a: Shape, d: Tree): Shape"]);
        assert_eq!(types, ["type T = #{\n  k: number,\n}"]);
        assert_eq!(doc, "Grows `a`.");
        let (signatures, _, doc) = split_signatures("f", "Grows `a`.");
        assert!(signatures.is_empty());
        assert_eq!(doc, "Grows `a`.");

        let definitions = [vec!["a".to_owned(), "w".to_owned()], vec!["w".to_owned()]];
        let signature = "f(a: Shape | Shape[], w: number | ((t: Tree) => Tree)): Shape";
        assert_eq!(
            method("f", signature, &definitions).as_deref(),
            Some("a.f(w: number | ((t: Tree) => Tree)): Shape")
        );
        assert_eq!(method("f", "f(w: number): Shape", &definitions), None);
        // A function that takes the rest is no method twin unless the first
        // is a shape.
        let curried = [vec!["t".to_owned(), "n".to_owned()], vec!["n".to_owned()]];
        assert_eq!(method("f", "f(t: Tree, n: number): Tree", &curried), None);
    }

    /// Every signature in a prelude doc comment names the parameters of
    /// one of the function's definitions, the modules' too.
    #[test]
    fn prelude_signatures_name_their_parameters() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
        let mut definitions: BTreeMap<String, Vec<Vec<String>>> = BTreeMap::new();
        let mut typed: Vec<(String, String)> = vec![];
        let files = [dir.clone(), dir.join("modules")]
            .into_iter()
            .flat_map(|d| std::fs::read_dir(d).expect("the prelude"))
            .map(|file| file.expect("a file").path())
            .filter(|path| path.extension().is_some_and(|e| e == "rhai"));
        for path in files {
            let text = std::fs::read_to_string(&path).expect("readable");
            // A module's functions are its own.
            let module = path
                .parent()
                .is_some_and(|p| p.ends_with("modules"))
                .then(|| path.file_stem().unwrap_or_default().to_string_lossy());
            let key = |name: &str| match &module {
                Some(module) => format!("{module}::{name}"),
                None => name.to_owned(),
            };
            let mut comment = String::new();
            for line in text.lines() {
                if let Some(doc) = line.strip_prefix("///") {
                    comment.push_str(doc.strip_prefix(' ').unwrap_or(doc));
                    comment.push('\n');
                    continue;
                }
                if let Some((name, params)) = line
                    .strip_prefix("fn ")
                    .and_then(|l| l.split_once('('))
                    .and_then(|(name, l)| Some((name, l.split_once(')')?.0)))
                {
                    let params = params.split(',').map(|p| p.trim().to_owned());
                    let params: Vec<String> = params.filter(|p| !p.is_empty()).collect();
                    definitions.entry(key(name)).or_default().push(params);
                    for signature in split_signatures(name, comment.trim()).0 {
                        typed.push((key(name), signature));
                    }
                }
                comment.clear();
            }
        }
        assert!(!typed.is_empty());
        for (name, signature) in typed {
            let bare = name.rsplit("::").next().unwrap_or(&name);
            let (params, _) = parameters(bare, &signature).expect("a call");
            let names: Vec<&str> = params.iter().map(|p| parameter_name(p)).collect();
            assert!(
                definitions[&name]
                    .iter()
                    .any(|d| d.iter().map(String::as_str).eq(names.iter().copied())),
                "{signature}: no definition of {name} takes {names:?}"
            );
        }
    }
}
