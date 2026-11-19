// SPDX-License-Identifier: MPL-2.0

//! Drives the server through its protocol, as keycap does.
//!
//! Frames are rendered on the CPU, so that the tests run without a GPU;
//! `KEYCAP_SERVER_TEST_GPU=1` adds the GPU's frames to the comparison.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};

struct Server {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next: i64,
    /// The progress lines read so far
    progress: Vec<Value>,
}

impl Server {
    fn start(args: &[&str]) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_keycap-server"))
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("the server starts");
        let input = child.stdin.take().expect("stdin is piped");
        let output = BufReader::new(child.stdout.take().expect("stdout is piped"));
        Server {
            child,
            input,
            output,
            next: 1,
            progress: vec![],
        }
    }

    fn send_line(&mut self, line: &str) {
        writeln!(self.input, "{line}").expect("the server reads");
        self.input.flush().expect("the server reads");
    }

    /// Sends `request` with the next id, without waiting for its reply.
    fn send(&mut self, mut request: Value) -> i64 {
        let id = self.next;
        self.next += 1;
        request["id"] = id.into();
        self.send_line(&request.to_string());
        id
    }

    /// The next reply, past the progress of exports, which is kept.
    fn reply(&mut self) -> Value {
        loop {
            let mut line = String::new();
            self.output
                .read_line(&mut line)
                .expect("the server answers");
            let reply: Value =
                serde_json::from_str(&line).unwrap_or_else(|e| panic!("bad reply {line:?}: {e}"));
            if reply.get("progress").is_none() {
                return reply;
            }
            self.progress.push(reply);
        }
    }

    fn request(&mut self, request: Value) -> Value {
        let id = self.send(request);
        let reply = self.reply();
        assert_eq!(reply["id"], id, "{reply}");
        reply
    }

    fn load(&mut self, source: &str, path: Option<&Path>) -> Value {
        self.request(json!({"op": "load", "source": source, "path": path}))
    }

    fn render(&mut self, output: &Path, extra: Value) -> Value {
        let mut request = json!({
            "op": "render", "output": output, "width": 160, "height": 120, "backend": "cpu",
        });
        if let (Some(request), Value::Object(extra)) = (request.as_object_mut(), extra) {
            request.extend(extra);
        }
        self.request(request)
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A fresh directory for one test's files.
fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("the scratch directory is writable");
    dir
}

/// A binary PPM's width, height and pixels.
fn read_ppm(path: &Path) -> (usize, usize, Vec<[u8; 3]>) {
    let data = std::fs::read(path).expect("the frame exists");
    let text = String::from_utf8_lossy(&data[..data.len().min(32)]).into_owned();
    let mut fields = text.split_ascii_whitespace();
    assert_eq!(fields.next(), Some("P6"));
    let width: usize = fields.next().and_then(|f| f.parse().ok()).expect("a width");
    let height: usize = fields
        .next()
        .and_then(|f| f.parse().ok())
        .expect("a height");
    assert_eq!(fields.next(), Some("255"));
    let header = format!("P6\n{width} {height}\n255\n").len();
    let pixels: Vec<[u8; 3]> = data[header..]
        .chunks_exact(3)
        .map(|c| [c[0], c[1], c[2]])
        .collect();
    assert_eq!(pixels.len(), width * height);
    (width, height, pixels)
}

/// A binary STL's vertices, three per triangle
fn read_stl(path: &Path) -> Vec<[f32; 3]> {
    let data = std::fs::read(path).expect("the mesh exists");
    let triangles = u32::from_le_bytes([data[80], data[81], data[82], data[83]]) as usize;
    assert_eq!(data.len(), 84 + 50 * triangles);
    data[84..]
        .chunks_exact(50)
        .flat_map(|triangle| triangle[12..48].chunks_exact(12))
        .map(|v| {
            std::array::from_fn(|i| f32::from_le_bytes(v[4 * i..4 * i + 4].try_into().unwrap()))
        })
        .collect()
}

fn diagnostic(reply: &Value) -> &Value {
    &reply["diagnostics"][0]
}

fn position(reply: &Value) -> [f64; 3] {
    let p = &reply["position"];
    std::array::from_fn(|i| {
        p[i].as_f64()
            .unwrap_or_else(|| panic!("no position in {reply}"))
    })
}

fn close(a: f64, b: f64, tolerance: f64) -> bool {
    (a - b).abs() <= tolerance
}

// --- load ---

#[test]
fn syntax_error_position() {
    let mut server = Server::start(&[]);
    let reply = server.load("let a = 1;\nlet b = (2 +;\ndraw(sphere(1));\n", None);
    assert_eq!(reply["loaded"], false);
    let d = diagnostic(&reply);
    assert_eq!(d["severity"], "error");
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(2), Some(13))
    );
    assert!(
        d["message"]
            .as_str()
            .unwrap_or("")
            .starts_with("Syntax error"),
        "{d}"
    );
}

#[test]
fn unknown_function_position() {
    let mut server = Server::start(&[]);
    let reply = server.load("let a = sphere(1);\ndraw(frobnicate(a, 2));\n", None);
    let d = diagnostic(&reply);
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(2), Some(6))
    );
    assert!(
        d["message"].as_str().unwrap_or("").contains("frobnicate"),
        "{d}"
    );
    let reply = server.load("draw(frobnicate(\"M3\", 2));\n", None);
    assert_eq!(
        diagnostic(&reply)["message"],
        "Function not found: frobnicate (string, i64)"
    );
}

#[test]
fn error_inside_a_function_has_its_call_sites() {
    let mut server = Server::start(&[]);
    let source = "fn inner(s) {\n    s + undefined\n}\nfn outer(s) {\n    inner(s)\n}\ndraw(outer(sphere(1)));\n";
    let reply = server.load(source, None);
    let d = diagnostic(&reply);
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(2), Some(9))
    );
    let trace = d["trace"].as_array().expect("a trace");
    let sites: Vec<_> = trace
        .iter()
        .map(|f| (f["line"].as_u64(), f["message"].as_str()))
        .collect();
    assert_eq!(
        sites,
        [
            (Some(5), Some("in call to fn inner")),
            (Some(7), Some("in call to fn outer")),
        ]
    );
}

#[test]
fn error_in_an_imported_file_names_it() {
    let dir = scratch("import");
    std::fs::create_dir_all(dir.join("lib")).expect("writable");
    std::fs::write(
        dir.join("lib/parts.keycap"),
        "fn peg(r) {\n    circle(r) + nope\n}\n",
    )
    .expect("writable");
    std::fs::write(dir.join("lib/broken.rhai"), "let a = 1;\nlet b = ;\n").expect("writable");
    let script = dir.join("main.keycap");
    let mut server = Server::start(&[]);

    let reply = server.load(
        "import \"lib/parts\" as parts;\ndraw(parts::peg(2));\n",
        Some(&script),
    );
    let d = diagnostic(&reply);
    let lib = std::fs::canonicalize(dir.join("lib/parts.keycap")).expect("exists");
    assert_eq!(d["file"].as_str(), lib.to_str());
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(2), Some(17))
    );
    assert_eq!(d["trace"][0]["line"], 2);
    assert!(
        d["trace"][0].get("file").is_none(),
        "the call site is in the script: {d}"
    );

    let reply = server.load(
        "import \"lib/broken\" as b;\ndraw(sphere(1));\n",
        Some(&script),
    );
    let d = diagnostic(&reply);
    assert!(
        d["file"]
            .as_str()
            .unwrap_or("")
            .ends_with("lib/broken.rhai"),
        "{d}"
    );
    assert_eq!(d["line"], 2);
    assert_eq!(d["trace"][0]["message"], "in import of broken.rhai");

    let reply = server.load("import \"lib/missing\" as m;\n", Some(&script));
    assert!(
        diagnostic(&reply)["message"]
            .as_str()
            .unwrap_or("")
            .contains("lib/missing")
    );
}

#[test]
fn load_lists_the_functions_a_script_defines_and_imports() {
    let dir = scratch("functions");
    std::fs::write(
        dir.join("parts.rhai"),
        "import \"inner\" as inner;\n\n\
         /// A peg of radius `r`.\n///\n/// Stands on z = 0.\nfn peg(r) { inner::post(r) }\n\n\
         /// Hidden.\nprivate fn helper() { 1.0 }\n",
    )
    .expect("writable");
    std::fs::write(
        dir.join("inner.rhai"),
        "/// A post.\nfn post(r) { circle(r) }\n",
    )
    .expect("writable");
    let mut server = Server::start(&[]);
    let reply = server.load(
        "import \"parts\" as p;\n// import \"parts\" as q;\n\n\
         /** Twice `v`. */\nfn twice(v) { v * 2 }\n\
         fn twice(a, v) { a + v }\n\ndraw(p::peg(twice(1.0)));\n",
        Some(&dir.join("main.keycap")),
    );
    assert_eq!(reply["loaded"], true, "{reply}");
    let functions = reply["functions"].as_array().cloned().unwrap_or_default();
    let named = |name: &str| {
        functions
            .iter()
            .find(|f| f["name"] == name)
            .cloned()
            .unwrap_or_default()
    };
    // Only those the script can call by these names, not by a commented-out
    // import's
    assert_eq!(functions.len(), 2, "{functions:?}");
    assert_eq!(
        named("p::peg"),
        json!({"name": "p::peg", "signatures": ["p::peg(r)"],
               "doc": "A peg of radius `r`.\n\nStands on z = 0.",
               "source": "import", "file": "parts.rhai"})
    );
    assert_eq!(
        named("twice"),
        json!({"name": "twice", "signatures": ["a.twice(v)", "twice(a, v)"],
               "doc": "Twice `v`.", "source": "script", "file": null})
    );
    // Known even when the script fails after defining them
    let reply = server.load("fn f() { 1 }\nlet a = nope;\n", None);
    assert_eq!(reply["loaded"], false);
    assert_eq!(reply["functions"][0]["name"], "f", "{reply}");
}

/// A closure's name is Rhai's, with a hash that changes from one server to
/// the next: neither the script's closures nor a module's are listed.
#[test]
fn load_lists_no_closures() {
    let source = "import \"keycap/points\" as points;\n\n\
                  fn twice(v) { v * 2 }\n\n\
                  print(points::regular_polygon(4, 1.0).map(|p| p[0]));\n";
    let functions = || {
        let reply = with_prelude().load(source, None);
        assert_eq!(reply["loaded"], true, "{reply}");
        reply["functions"].clone()
    };
    let first = functions();
    let names: Vec<&str> = first
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|f| f["name"].as_str())
        .collect();
    assert!(names.contains(&"twice"), "{names:?}");
    assert!(names.iter().any(|n| n.starts_with("points::")), "{names:?}");
    assert!(!names.iter().any(|n| n.contains("anon$")), "{names:?}");
    assert_eq!(first, functions());
}

#[test]
fn a_failed_load_keeps_the_scene() {
    let dir = scratch("keep");
    let mut server = Server::start(&[]);
    assert_eq!(server.load("draw(sphere(1));\n", None)["loaded"], true);
    assert_eq!(server.load("draw(sphere(;\n", None)["loaded"], false);
    let reply = server.render(&dir.join("frame.ppm"), json!({}));
    assert!(reply.get("ms").is_some(), "{reply}");
}

#[test]
fn stats_count_the_union() {
    let mut server = Server::start(&[]);
    let reply = server.request(json!({"op": "stats"}));
    assert_eq!(reply["error"], "no script is loaded", "{reply}");
    server.load("draw(sphere(1));\n", None);
    let one = server.request(json!({"op": "stats"}));
    assert_eq!(one["choices"], 0, "{one}");
    server.load("draw(sphere(1));\ndraw(sphere([2, 0, 0], 1));\n", None);
    let two = server.request(json!({"op": "stats"}));
    assert_eq!(two["choices"], 1, "{two}");
    for key in ["nodes", "tape", "registers"] {
        assert!(two[key].as_u64() > one[key].as_u64(), "{key}: {one} {two}");
    }
}

#[test]
fn shapes_colours_bounds_resolution_and_output() {
    let mut server = Server::start(&[]);
    let source = "bounds([-2, -2, -2], [2, 2, 2]);\n\
                  resolution(20);\n\
                  draw(sphere(1));\n\
                  draw_rgb(circle(0.5), 1, 0.5, 0);\n\
                  print(\"hello\");\n\
                  debug(42);\n";
    let reply = server.load(source, None);
    assert_eq!(reply["loaded"], true, "{reply}");
    assert_eq!(
        reply["shapes"],
        json!([
            {"line": 3, "column": 1, "color": null},
            {"line": 4, "column": 1, "color": [1.0, 0.5, 0.0]},
        ])
    );
    assert_eq!(
        reply["bounds"]["script"],
        json!({"lower": [-2.0, -2.0, -2.0], "upper": [2.0, 2.0, 2.0]})
    );
    assert_eq!(reply["resolution"], 20.0);
    assert_eq!(reply["output"], json!(["hello", "42"]));
    assert_eq!(reply["diagnostics"], json!([]));
}

#[test]
fn bounds_take_2d_corners_with_z_0() {
    let mut server = Server::start(&[]);
    let reply = server.load("bounds([-2, -2], [2, 2, 2]);\ndraw(sphere(1));\n", None);
    assert_eq!(reply["loaded"], true, "{reply}");
    assert_eq!(
        reply["bounds"]["script"],
        json!({"lower": [-2.0, -2.0, 0.0], "upper": [2.0, 2.0, 2.0]})
    );
}

#[test]
fn script_api_errors() {
    let mut server = Server::start(&[]);
    for (source, message) in [
        (
            "bounds([-1, -1, -1, -1], [1, 1, 1]);",
            "bounds' lower corner must be [x, y] or [x, y, z]",
        ),
        (
            "bounds([-1, -1], [1, 1]);",
            "bounds are empty on z: lower must be below upper",
        ),
        (
            "bounds([1, -1, -1], [1, 1, 1]);",
            "bounds are empty on x: lower must be below upper",
        ),
        (
            "bounds([-1, -1, -1], [1, 1, 1]);\nbounds([-1, -1, -1], [1, 1, 1]);",
            "bounds are already set",
        ),
        ("resolution(0);", "resolution must be positive, not 0"),
        (
            "let s = sphere(1);\nif s < 0 { draw(s); }",
            "cannot compare Tree types during function tracing",
        ),
    ] {
        let reply = server.load(source, None);
        assert_eq!(reply["loaded"], false, "{source}");
        assert_eq!(diagnostic(&reply)["message"], message, "{source}");
    }
}

#[test]
fn an_endless_loop_stops() {
    let mut server = Server::start(&[]);
    let reply = server.load("let i = 0;\nloop { i += 1; }\n", None);
    assert_eq!(reply["loaded"], false);
    assert!(
        diagnostic(&reply)["message"]
            .as_str()
            .unwrap_or("")
            .contains("operations")
    );
}

// --- Bounds ---

#[test]
fn fitted_bounds_of_3d_and_2d_shapes() {
    let mut server = Server::start(&[]);
    let reply = server.load("draw(sphere([1, 0, 0], 2));\n", None);
    let fitted = &reply["bounds"]["fitted"];
    let lower: Vec<f64> = (0..3)
        .map(|i| fitted["lower"][i].as_f64().unwrap_or(f64::NAN))
        .collect();
    let upper: Vec<f64> = (0..3)
        .map(|i| fitted["upper"][i].as_f64().unwrap_or(f64::NAN))
        .collect();
    // Never inside the shape, padded by a few percent.
    for (got, side) in [(lower[0], -1.0), (lower[1], -2.0), (lower[2], -2.0)] {
        assert!(got <= side && got >= side - 0.4, "{fitted}");
    }
    for (got, side) in [(upper[0], 3.0), (upper[1], 2.0), (upper[2], 2.0)] {
        assert!(got >= side && got <= side + 0.4, "{fitted}");
    }

    let reply = server.load("draw(circle([0, 1], 1));\n", None);
    let fitted = &reply["bounds"]["fitted"];
    assert!(
        fitted["lower"][2].is_null() && fitted["upper"][2].is_null(),
        "{fitted}"
    );
    assert!(
        close(fitted["upper"][1].as_f64().unwrap_or(0.0), 2.0, 0.1),
        "{fitted}"
    );

    // The half space below z = 0.
    let reply = server.load("draw(z);\n", None);
    let fitted = &reply["bounds"]["fitted"];
    assert_eq!(fitted["lower"], json!([null, null, null]));
    assert_eq!(fitted["upper"][0], Value::Null);
    assert!(
        close(fitted["upper"][2].as_f64().unwrap_or(1.0), 0.0, 0.1),
        "{fitted}"
    );

    let reply = server.load("let a = 1;\n", None);
    assert_eq!(reply["bounds"]["fitted"], Value::Null);
    assert!(
        diagnostic(&reply)["message"]
            .as_str()
            .unwrap_or("")
            .contains("draws nothing")
    );
}

#[test]
fn shapes_past_the_bounds_warn() {
    let mut server = Server::start(&[]);
    let source = "bounds([-1, -1, -1], [1, 1, 1]);\n\
                  draw(sphere(0.5));\n\
                  draw(move(sphere(1), [1.5, 0, 0]));\n\
                  draw(circle(0.5));\n\
                  // Folded, and seen through intervals that stay loose\n\
                  let one = 0.5 * (square(sin(x * 50)) + square(cos(x * 50)));\n\
                  draw(remap(move(sphere(0.5), [0.45, 0, 0]) + one - 0.5, abs(x), y, z));\n";
    let reply = server.load(source, None);
    assert_eq!(reply["loaded"], true);
    let warnings: Vec<_> = reply["diagnostics"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|d| {
            (
                d["severity"].as_str(),
                d["line"].as_u64(),
                d["message"].as_str(),
            )
        })
        .collect();
    assert_eq!(
        warnings,
        [(
            Some("warning"),
            Some(3),
            Some("shape extends past the bounds on +x")
        )]
    );
}

#[test]
fn shapes_unbounded_on_one_side_past_the_bounds_load() {
    let mut server = with_prelude();
    // Fitted bounds unbounded below on one axis, and above the script's on
    // another, once made an inverted interval of the part past a side.
    let source = "bounds([-30, -30, -30], [30, 30, 30]);\n\
                  draw(sphere(1).move([0, 59, 0]).repeat_polar(40, 17));\n";
    let reply = server.load(source, None);
    assert_eq!(reply["loaded"], true, "{reply}");
}

#[test]
fn unbounded_and_empty_shapes_warn() {
    let dir = scratch("unbounded");
    let mut server = Server::start(&[]);
    let warning = |reply: &Value| {
        let d = diagnostic(reply);
        (
            d["severity"].clone(),
            d["line"].clone(),
            d["message"].clone(),
        )
    };

    let reply = server.load(
        "draw(sphere(1));\ndraw(sin(x) * cos(y) + sin(y) * cos(z) + sin(z) * cos(x));\n",
        None,
    );
    assert_eq!(
        warning(&reply),
        (
            json!("warning"),
            json!(2),
            json!("unbounded on every axis; set bounds(...)")
        )
    );
    // Shown 20 across, rather than 2
    let frame = server.render(&dir.join("gyroid.ppm"), json!({"view": "sdf"}));
    assert!(
        close(
            frame["scale"].as_f64().unwrap_or(0.0) * 120.0 * 0.9,
            20.0,
            1e-6
        ),
        "{frame}"
    );
    assert_eq!(frame["empty"], false);
    let reply = server.load(
        "bounds([-5, -5, -5], [5, 5, 5]);\ndraw(sin(x) + sin(y));\n",
        None,
    );
    assert_eq!(reply["diagnostics"], json!([]));
    assert_eq!(reply["bounds"]["loose"], Value::Null);

    // A band along the diagonal, cut to a disc: (x - y)² as x² + y² - 2xy
    // is negative as an interval on every cell the diagonal crosses, so
    // its sqrt is NaN there, though never as a value.
    let reply = server.load(
        "let band = sqrt(x * x + y * y - 2.0 * x * y) - 1.0;\n\
         draw(max(band, sqrt(x * x + y * y) - 5.0));\n",
        None,
    );
    assert_eq!(
        warning(&reply),
        (
            json!("warning"),
            json!(2),
            json!("could not fit bounds: the shapes' intervals are NaN; set bounds(...)")
        )
    );
    assert_eq!(reply["bounds"]["loose"], "the shapes' intervals are NaN");

    // A squircle's radius per direction, from sin 2θ = 2xy / (x² + y²):
    // within ±1, but not as an interval, so the sqrt of 1 - s² sin² 2θ
    // is NaN as one far out, and the bounds come out loose.  Clamped to
    // what it is anyway, it has an interval everywhere.
    let squircle = |sin2: &str| {
        format!(
            "let sin2 = {sin2};\n\
             let r = 5.0 * sqrt(2.0 / (1.0 + sqrt(1.0 - 0.9 * sin2 * sin2)));\n\
             draw(sqrt(x * x + y * y) - r);\n"
        )
    };
    let reply = server.load(&squircle("2.0 * x * y / (x * x + y * y + 1e-6)"), None);
    assert_eq!(reply["bounds"]["loose"], "the shapes' intervals are NaN");
    let reply = server.load(
        &squircle("min(max(2.0 * x * y / (x * x + y * y + 1e-6), -1.0), 1.0)"),
        None,
    );
    assert_eq!(reply["diagnostics"], json!([]), "{reply}");
    assert_eq!(reply["bounds"]["loose"], Value::Null);
    let upper = &reply["bounds"]["fitted"]["upper"];
    assert!(
        upper[0].as_f64().is_some_and(|x| x > 5.0 && x < 6.0),
        "{reply}"
    );

    let reply = server.load(
        "let a = sphere(1);\ndraw(max(a, move(a, [5, 0, 0])));\n",
        None,
    );
    assert_eq!(
        warning(&reply),
        (
            json!("warning"),
            json!(2),
            json!("the shapes are empty: nothing is inside them")
        )
    );
    for view in ["shaded", "sdf"] {
        let frame = server.render(&dir.join("empty.ppm"), json!({ "view": view }));
        assert_eq!(frame["empty"], true, "{view}: {frame}");
    }
}

// --- render and probe ---

#[test]
fn renders_every_view() {
    let dir = scratch("views");
    let mut server = Server::start(&[]);
    server.load(
        "draw(sphere(1));\ndraw_rgb(move(box([-1, -1, -1], [1, 1, 1]), [2, 0, 0]), 0, 0, 1);\n",
        None,
    );
    for view in ["shaded", "heightmap", "sdf", "mono"] {
        let output = dir.join(format!("{view}.ppm"));
        let reply = server.render(&output, json!({"view": view, "background": [0, 1, 0]}));
        assert_eq!(reply["backend"], "cpu", "{reply}");
        assert_eq!(reply["bounds"], "fitted");
        assert!(reply["scale"].as_f64().is_some_and(|s| s > 0.0), "{reply}");
        let (width, height, pixels) = read_ppm(&output);
        assert_eq!((width, height), (160, 120));
        let mut temporary = output.into_os_string();
        temporary.push(".tmp");
        assert!(!Path::new(&temporary).exists());
        let background = pixels.iter().filter(|&&p| p == [0, 255, 0]).count();
        if view == "shaded" || view == "heightmap" {
            // The corners are empty, a good part of the rest is not.
            assert_eq!(pixels[0], [0, 255, 0], "{view}");
            assert!(background < pixels.len() * 9 / 10, "{view}");
        } else {
            assert_eq!(background, 0, "{view}");
        }
        if view == "shaded" {
            assert!(
                pixels.iter().any(|p| p[2] > 2 * p[0].max(p[1]).max(10)),
                "the box is blue"
            );
        }
    }
}

/// A scene renders to the same bytes in every run of the server, on the
/// CPU and, asked to be reproducible, on the GPU, occlusion included, so
/// pictures built from scripts are reproducible.
#[test]
fn shaded_frames_are_the_same_in_every_run() {
    let dir = scratch("reproducible");
    let mut backends = vec!["cpu"];
    if std::env::var("KEYCAP_SERVER_TEST_GPU").as_deref() == Ok("1") {
        backends.push("gpu");
    }
    for backend in backends {
        let frames: Vec<_> = (0..2)
            .map(|run| {
                let mut server = Server::start(&[]);
                server.load(
                    "draw(sphere(1));\ndraw(move(box([-1, -1, -1], [1, 1, 1]), [1.2, 0, 0]));\n",
                    None,
                );
                let output = dir.join(format!("{backend}-{run}.ppm"));
                let reply =
                    server.render(&output, json!({"backend": backend, "reproducible": true}));
                assert_eq!(reply["backend"], backend, "{reply}");
                std::fs::read(&output).expect("the frame is written")
            })
            .collect();
        assert!(frames[0] == frames[1], "{backend}: the runs differ");
    }
}

/// The GPU's own occlusion, which it draws its samples for once per run,
/// keeps a scene's frames the same within the run, and is only used when
/// a frame need not be reproducible.
#[test]
fn fast_gpu_frames_are_the_same_within_a_run() {
    if std::env::var("KEYCAP_SERVER_TEST_GPU").as_deref() != Ok("1") {
        return;
    }
    let dir = scratch("fast-gpu");
    let mut server = Server::start(&[]);
    server.load(
        "draw(sphere(1));\ndraw(move(box([-1, -1, -1], [1, 1, 1]), [1.2, 0, 0]));\n",
        None,
    );
    let frames: Vec<_> = [false, false, true]
        .into_iter()
        .enumerate()
        .map(|(i, reproducible)| {
            let output = dir.join(format!("{i}.ppm"));
            let reply = server.render(
                &output,
                json!({"backend": "gpu", "reproducible": reproducible}),
            );
            assert_eq!(reply["backend"], "gpu", "{reply}");
            std::fs::read(&output).expect("the frame is written")
        })
        .collect();
    assert!(frames[0] == frames[1], "the frames flicker");
    assert!(frames[0] != frames[2], "the frames share their occlusion");
}

#[test]
fn probes_follow_the_camera() {
    let dir = scratch("probe");
    let output = dir.join("frame.ppm");
    let mut server = Server::start(&[]);
    server.load("draw(sphere(1));\n", None);
    let (width, height) = (200.0, 200.0);
    let camera = |server: &mut Server, azimuth: f64, elevation: f64, pan: [f64; 2]| {
        let camera = json!({"azimuth": azimuth, "elevation": elevation, "pan": pan});
        server.render(
            &output,
            json!({"width": 200, "height": 200, "camera": camera}),
        )
    };
    for (azimuth, elevation, expected) in [
        (0.0, 0.0, [1.0, 0.0, 0.0]),
        (90.0, 0.0, [0.0, 1.0, 0.0]),
        (180.0, 0.0, [-1.0, 0.0, 0.0]),
        (0.0, 89.0, [0.0, 0.0, 1.0]),
    ] {
        camera(&mut server, azimuth, elevation, [0.0, 0.0]);
        let reply = server.request(json!({"op": "probe", "x": width / 2.0, "y": height / 2.0}));
        let p = position(&reply);
        assert!(
            (0..3).all(|i| close(p[i], expected[i], 0.05)),
            "{azimuth} {elevation}: {reply}"
        );
        assert!(
            reply["value"].as_f64().is_some_and(|v| v.abs() < 0.05),
            "{reply}"
        );
    }

    // From +X with Z up, the image's right is +Y and its up is +Z.
    camera(&mut server, 0.0, 0.0, [0.0, 0.0]);
    let right = position(&server.request(json!({"op": "probe", "x": 130.0, "y": 100.0})));
    let up = position(&server.request(json!({"op": "probe", "x": 100.0, "y": 70.0})));
    assert!(right[1] > 0.1 && right[2].abs() < 0.05, "{right:?}");
    assert!(up[2] > 0.1 && up[1].abs() < 0.05, "{up:?}");

    // Panning right brings what was right of the centre into it.
    let reply = camera(&mut server, 0.0, 0.0, [0.2, 0.0]);
    let half_height = reply["scale"].as_f64().unwrap_or(0.0) * height / 2.0;
    let p = position(&server.request(json!({"op": "probe", "x": 100.0, "y": 100.0})));
    assert!(close(p[1], 0.2 * half_height, 0.05), "{p:?} {half_height}");

    assert_eq!(
        server.request(json!({"op": "probe", "x": 100.0, "y": 100.0}))["shape"],
        0
    );
    let reply = server.request(json!({"op": "probe", "x": 1.0, "y": 1.0}));
    assert_eq!(reply["position"], Value::Null);
    assert_eq!(reply["shape"], Value::Null);
}

#[test]
fn probes_name_the_shape_under_the_cursor() {
    let dir = scratch("probe-shape");
    let output = dir.join("frame.ppm");
    let mut server = Server::start(&[]);
    let reply = server.load(
        "draw(sphere(1));\ndraw(move(sphere(0.5), [0, 2, 0]));\n",
        None,
    );
    let fitted = &reply["bounds"]["fitted"];
    let middle = (fitted["lower"][1].as_f64().unwrap_or(0.0)
        + fitted["upper"][1].as_f64().unwrap_or(0.0))
        / 2.0;
    // Looking down from the south, +Y is up in the image: the small sphere is
    // above the big one.
    let top = json!({"azimuth": -90, "elevation": 89.9});
    for view in ["shaded", "sdf"] {
        let reply = server.render(&output, json!({"view": view, "camera": top}));
        let scale = reply["scale"].as_f64().unwrap_or(1.0);
        let at = |server: &mut Server, y: f64| {
            // The views look at the middle of the fitted bounds.
            let row = 60.0 - ((y - middle) / scale).round();
            server.request(json!({"op": "probe", "x": 80.0, "y": row}))
        };
        assert_eq!(at(&mut server, 0.0)["shape"], 0, "{view}");
        assert_eq!(at(&mut server, 2.0)["shape"], 1, "{view}");
    }
}

#[test]
fn slices_lie_in_their_planes() {
    let dir = scratch("slices");
    let output = dir.join("frame.ppm");
    let mut server = Server::start(&[]);
    server.load("draw(sphere(1));\n", None);
    for (axis, right, up) in [("z", 0, 1), ("y", 0, 2), ("x", 1, 2)] {
        server.render(
            &output,
            json!({"view": "sdf", "slice": {"axis": axis, "offset": 0.5}}),
        );
        let center = position(&server.request(json!({"op": "probe", "x": 80.0, "y": 60.0})));
        let corner = server.request(json!({"op": "probe", "x": 150.0, "y": 10.0}));
        let p = position(&corner);
        let normal = 3 - right - up;
        assert!(
            close(p[normal], 0.5, 1e-6) && close(center[normal], 0.5, 1e-6),
            "{axis}: {corner}"
        );
        assert!(
            p[right] > center[right] + 0.1 && p[up] > center[up] + 0.1,
            "{axis}: {corner}"
        );
        // The sphere's field: the distance from the centre, less the radius.
        let distance = p.iter().map(|v| v * v).sum::<f64>().sqrt() - 1.0;
        assert!(
            close(corner["value"].as_f64().unwrap_or(f64::NAN), distance, 1e-3),
            "{corner}"
        );
    }
}

#[test]
fn tilted_slices_cut_spheres_in_circles() {
    let dir = scratch("tilted");
    let output = dir.join("frame.ppm");
    let mut server = Server::start(&[]);
    server.load("bounds([-6, -6, -6], [6, 6, 6]);\ndraw(sphere(5));\n", None);
    let (right, up) = (30.0_f64.to_radians(), -20.0_f64.to_radians());
    // The level plane's normal, turned about its right, then its up
    let turned = [up.sin(), -right.sin() * up.cos(), right.cos() * up.cos()];
    for (axis, [i, j, k]) in [("z", [0, 1, 2]), ("y", [0, 2, 1]), ("x", [1, 2, 0])] {
        let mut normal = [0.0; 3];
        for (n, t) in [i, j, k].into_iter().zip(turned) {
            normal[n] = t;
        }
        let slice = json!({"axis": axis, "offset": 3, "tilt": [30, -20]});
        let reply = server.render(&output, json!({"view": "mono", "slice": slice}));
        let scale = reply["scale"].as_f64().unwrap_or(f64::NAN);
        let (width, _, pixels) = read_ppm(&output);
        // 3 from the centre, the plane cuts a circle of radius 4.
        let inside = pixels.iter().filter(|p| p[0] > 127).count() as f64;
        let area = inside * scale * scale;
        assert!(
            close(area, std::f64::consts::PI * 16.0, 1.0),
            "{axis}: {area}"
        );

        let dot = |a: [f64; 3], b: [f64; 3]| (0..3).map(|n| a[n] * b[n]).sum::<f64>();
        let center = position(&server.request(json!({"op": "probe", "x": 80, "y": 60})));
        for (x, y) in [(80, 20), (120, 60), (110, 90), (60, 100), (20, 30)] {
            let reply = server.request(json!({"op": "probe", "x": x, "y": y}));
            let p = position(&reply);
            // On the plane, as far from the centre as the pixel is
            let apart: [f64; 3] = std::array::from_fn(|n| p[n] - center[n]);
            let pixels_apart = f64::hypot(f64::from(x - 80), f64::from(y - 60));
            assert!(close(dot(p, normal), 3.0, 1e-4), "{axis} {x} {y}: {p:?}");
            assert!(
                close(dot(apart, apart).sqrt(), pixels_apart * scale, 1e-3),
                "{axis} {x} {y}: {p:?}"
            );
            // and inside on the frame where the sphere holds it
            let distance = dot(p, p).sqrt() - 5.0;
            let white = pixels[y as usize * width + x as usize][0] > 127;
            assert!(
                distance.abs() < 2.0 * scale || white == (distance < 0.0),
                "{axis} {x} {y}: {distance}"
            );
            let value = reply["value"].as_f64().unwrap_or(f64::NAN);
            assert!(close(value, distance, 1e-3), "{reply}");
        }
    }
}

#[test]
fn a_newer_render_cancels_older_ones() {
    let dir = scratch("cancel");
    let mut server = Server::start(&[]);
    let model = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/models/gyroid-sphere.rhai"),
    )
    .expect("the model exists");
    server.load(&model, None);
    let ids: Vec<i64> = (0..5)
        .map(|i| {
            server.send(json!({
                "op": "render", "output": dir.join(format!("{i}.ppm")), "width": 600, "height": 600,
                "backend": "cpu", "camera": {"azimuth": 10 * i},
            }))
        })
        .collect();
    let replies: Vec<Value> = ids.iter().map(|_| server.reply()).collect();
    let got: Vec<i64> = replies.iter().filter_map(|r| r["id"].as_i64()).collect();
    assert_eq!(got, ids, "replies come in request order");
    let last = replies.last().cloned().unwrap_or_default();
    assert!(
        last.get("ms").is_some(),
        "the newest render finishes: {last}"
    );
    assert!(
        replies.iter().any(|r| r["cancelled"] == true),
        "{replies:?}"
    );
}

/// The gyroid sphere's frames on one thread take seconds.
fn slow_server() -> (Server, String) {
    let mut server = Server::start(&["--threads", "1"]);
    let model = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/models/gyroid-sphere.rhai"),
    )
    .expect("the model exists");
    server.load(&model, None);
    (server, model)
}

#[test]
fn loads_do_not_wait_for_renders() {
    let dir = scratch("load-beside-render");
    let (mut server, _) = slow_server();
    let slow = json!({
        "op": "render", "output": dir.join("slow.ppm"), "width": 600, "height": 600,
        "backend": "cpu",
    });
    let render = server.send(slow);
    let load = server.send(json!({
        "op": "load", "source": "bounds([-1, -1, -1], [1, 1, 1]);\ndraw(sphere(0.5).move([5, 0, 0]));\n",
        "path": null,
    }));
    let first = server.reply();
    assert_eq!(first["id"], load, "{first}");
    assert_eq!(server.reply()["id"], render);
    // The frame after the load is of its scene, which shows nothing.
    let frame = server.render(&dir.join("frame.ppm"), json!({}));
    assert_eq!(frame["empty"], true, "{frame}");
}

#[test]
fn a_new_scene_cancels_the_render_of_the_old_one() {
    let dir = scratch("load-cancels");
    let (mut server, model) = slow_server();
    let slow = json!({
        "op": "render", "output": dir.join("slow.ppm"), "width": 300, "height": 300,
        "backend": "cpu",
    });
    let render = server.send(slow.clone());
    server.load("draw(sphere(1));\n", None);
    let reply = server.reply();
    assert_eq!(reply["id"], render);
    assert_eq!(reply["cancelled"], true, "{reply}");

    // A load that fails keeps the scene, and its frame.
    server.load(&model, None);
    let render = server.send(slow);
    server.load("draw(sphere(1)", None);
    let reply = server.reply();
    assert_eq!(reply["id"], render);
    assert!(reply.get("ms").is_some(), "{reply}");
}

#[test]
fn an_edit_that_draws_the_same_keeps_the_scene() {
    let dir = scratch("same-scene");
    let (mut server, model) = slow_server();
    let first = server.load(&model, None);
    let slow = json!({
        "op": "render", "output": dir.join("slow.ppm"), "width": 300, "height": 300,
        "backend": "cpu",
    });
    let render = server.send(slow);
    let edited = server.load(&format!("// A comment\n\n{model}"), None);
    assert_eq!(edited["scene"], first["scene"], "{edited}");
    let line = |reply: &Value| reply["shapes"][0]["line"].as_i64().unwrap_or_default();
    assert_eq!(line(&edited), line(&first) + 2, "{edited}");
    let reply = server.reply();
    assert_eq!(reply["id"], render);
    assert_eq!(reply["scene"], first["scene"], "{reply}");

    let other = server.load(&model.replace("- 25", "- 24"), None);
    assert_ne!(other["scene"], first["scene"], "{other}");
}

#[test]
fn a_render_waits_for_the_loads_before_it() {
    let dir = scratch("render-after-load");
    let mut server = Server::start(&[]);
    let model = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/models/gyroid-sphere.rhai"),
    )
    .expect("the model exists");
    let load = server.send(json!({"op": "load", "source": model, "path": null}));
    let render = server.send(json!({
        "op": "render", "output": dir.join("frame.ppm"), "width": 60, "height": 60,
        "backend": "cpu",
    }));
    let replies = [server.reply(), server.reply()];
    assert_eq!(replies[0]["id"], load, "{replies:?}");
    assert_eq!(replies[1]["id"], render, "{replies:?}");
    assert_eq!(replies[1]["empty"], false, "{replies:?}");
}

#[test]
fn gpu_frames_match_the_cpu() {
    if std::env::var("KEYCAP_SERVER_TEST_GPU").as_deref() != Ok("1") {
        return;
    }
    let dir = scratch("gpu");
    let mut server = Server::start(&[]);
    server.load(
        "draw(sphere(1));\ndraw_rgb(move(sphere(0.5), [0, 1, 0]), 1, 0, 0);\n",
        None,
    );
    for view in ["shaded", "heightmap", "sdf", "mono"] {
        let frames: Vec<_> = ["cpu", "gpu"]
            .into_iter()
            .map(|backend| {
                let output = dir.join(format!("{view}-{backend}.ppm"));
                let reply = server.render(&output, json!({"view": view, "backend": backend}));
                assert_eq!(reply["backend"], backend, "{reply}");
                read_ppm(&output).2
            })
            .collect();
        // The GPU finds depths a voxel or two off the CPU's, so frames only
        // nearly match.
        let differing = frames[0]
            .iter()
            .zip(&frames[1])
            .filter(|(a, b)| (0..3).any(|i| a[i].abs_diff(b[i]) > 24))
            .count();
        assert!(
            differing < frames[0].len() / 50,
            "{view}: {differing} pixels differ"
        );
    }
}

#[test]
fn gpu_frames_of_shapes_too_big_for_it_match_the_cpu() {
    if std::env::var("KEYCAP_SERVER_TEST_GPU").as_deref() != Ok("1") {
        return;
    }
    let dir = scratch("gpu-big");
    // The feather's tape spills registers into memory, which the GPU's
    // interpreter has none of.
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let prelude = root.join("prelude").to_string_lossy().into_owned();
    let source = std::fs::read_to_string(root.join("examples/feather.keycap")).expect("readable");
    let mut server = Server::start(&["--prelude", &prelude]);
    let reply = server.load(&source, None);
    assert_eq!(reply["loaded"], true, "{reply}");
    for view in ["heightmap", "sdf"] {
        let frames: Vec<_> = ["cpu", "gpu"]
            .into_iter()
            .map(|backend| {
                let output = dir.join(format!("{view}-{backend}.ppm"));
                let reply = server.render(&output, json!({"view": view, "backend": backend}));
                assert_eq!(reply["backend"], "cpu", "{reply}");
                if backend == "gpu" {
                    let why = reply["fallback"].as_str().unwrap_or_default();
                    assert!(why.contains("registers"), "{reply}");
                }
                read_ppm(&output).2
            })
            .collect();
        let differing = frames[0]
            .iter()
            .zip(&frames[1])
            .filter(|(a, b)| a != b)
            .count();
        assert_eq!(differing, 0, "{view}: {differing} pixels differ");
    }
}

/// The knob, which once stalled the preview on the GPU, in one tile and in
/// tiles of a few milliseconds each, matches the CPU's frames.
#[test]
fn gpu_frames_in_tiles_match_the_cpu() {
    if std::env::var("KEYCAP_SERVER_TEST_GPU").as_deref() != Ok("1") {
        return;
    }
    let dir = scratch("gpu-tiles");
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let prelude = root.join("prelude").to_string_lossy().into_owned();
    let source = std::fs::read_to_string(root.join("examples/knob.keycap")).expect("readable");
    for budget in ["400", "60"] {
        let mut server = Server::start(&["--prelude", &prelude, "--gpu-budget", budget]);
        let reply = server.load(&source, None);
        assert_eq!(reply["loaded"], true, "{reply}");
        for view in ["shaded", "heightmap"] {
            let mut render = |backend: &str, live: bool| {
                let output = dir.join(format!("{view}-{backend}-{budget}-{live}.ppm"));
                let size = json!({
                    "view": view, "backend": backend, "width": 1000, "height": 800, "live": live,
                });
                let reply = server.render(&output, size);
                assert_eq!(reply["backend"], backend, "{reply}");
                read_ppm(&output).2
            };
            let cpu = render("cpu", false);
            // The first frame measures the tiles, the second is cut into them;
            // a live frame's tiles are smaller.
            render("gpu", false);
            for live in [false, true] {
                let gpu = render("gpu", live);
                let differing = cpu
                    .iter()
                    .zip(&gpu)
                    .filter(|(a, b)| (0..3).any(|i| a[i].abs_diff(b[i]) > 24))
                    .count();
                assert!(
                    differing < cpu.len() / 50,
                    "{view}, {budget} ms, live {live}: {differing} pixels differ"
                );
            }
        }
    }
}

/// A frame that the GPU would take too long over goes to the CPU, and the
/// reply says why.
#[test]
fn gpu_frames_too_slow_for_it_go_to_the_cpu() {
    if std::env::var("KEYCAP_SERVER_TEST_GPU").as_deref() != Ok("1") {
        return;
    }
    let dir = scratch("gpu-slow");
    let mut server = Server::start(&["--gpu-budget", "1"]);
    server.load(
        "let g = sin(x) * cos(y) + sin(y) * cos(z) + sin(z) * cos(x);\n\
         draw(max(sqrt(x * x + y * y + z * z) - 8, abs(g) - 0.2));\n",
        None,
    );
    for _ in 0..2 {
        let output = dir.join("frame.ppm");
        let reply = server.render(&output, json!({"view": "shaded", "backend": "gpu"}));
        assert_eq!(reply["backend"], "cpu", "{reply}");
        let why = reply["fallback"].as_str().unwrap_or_default();
        assert!(why.starts_with("too slow for the GPU"), "{reply}");
    }
}

/// Asked to choose, the server renders where the frame is sooner, without
/// calling it a fallback.
#[test]
fn auto_frames_go_where_they_render_sooner() {
    if std::env::var("KEYCAP_SERVER_TEST_GPU").as_deref() != Ok("1") {
        return;
    }
    let dir = scratch("auto");
    let mut server = Server::start(&[]);
    server.load("draw(sphere(1));\n", None);
    let output = dir.join("frame.ppm");
    let cpu = server.render(&output, json!({}));
    let cpu_pixels = read_ppm(&output).2;
    for _ in 0..3 {
        let reply = server.render(&output, json!({"backend": "auto"}));
        assert!(reply.get("fallback").is_none(), "{reply}");
        let differing = cpu_pixels
            .iter()
            .zip(&read_ppm(&output).2)
            .filter(|(a, b)| (0..3).any(|i| a[i].abs_diff(b[i]) > 24))
            .count();
        assert!(differing < cpu_pixels.len() / 50, "{reply}, {cpu}");
    }
}

// --- mesh ---

/// An export read before stdin closed is still answered, as a CLI that
/// closes stdin after its last request needs.
#[test]
fn answers_an_export_after_stdin_closes() {
    let output = scratch("mesh-after-close").join("model.stl");
    let mut child = Command::new(env!("CARGO_BIN_EXE_keycap-server"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("the server starts");
    let mut input = child.stdin.take().expect("stdin is piped");
    for request in [
        json!({"id": 1, "op": "load", "source": "draw(sphere(1));\n", "path": null}),
        json!({"id": 2, "op": "mesh", "output": output, "resolution": 10}),
    ] {
        writeln!(input, "{request}").expect("the server reads");
    }
    drop(input);
    let replies = child.wait_with_output().expect("the server exits").stdout;
    let mesh = String::from_utf8_lossy(&replies)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|reply| reply["id"] == 2 && reply.get("progress").is_none());
    let mesh = mesh.expect("the mesh is answered");
    assert!(mesh["triangles"].as_u64() > Some(0), "{mesh}");
    assert!(output.exists());
}

#[test]
fn meshes_cut_to_the_region() {
    let dir = scratch("mesh");
    let output = dir.join("model.stl");
    let mut server = Server::start(&[]);
    server.load(
        "bounds([-1, -1, -1], [1, 1, 1]);\ndraw(sphere(1.2));\n",
        None,
    );
    let reply = server.request(json!({"op": "mesh", "output": output, "resolution": 10}));
    let triangles = reply["triangles"]
        .as_u64()
        .unwrap_or_else(|| panic!("{reply}"));
    assert!(triangles > 100, "{reply}");
    // Simplified to a tenth of the cells, 1/16 across
    assert!(reply["meshed"].as_u64() > Some(triangles * 4), "{reply}");
    assert_eq!(reply["tolerance"], 2.0 / 32.0 / 10.0);
    assert_eq!(reply["bounds"], "script");
    let stages: Vec<&Value> = server
        .progress
        .iter()
        .filter(|p| p["id"] == reply["id"])
        .map(|p| &p["progress"])
        .collect();
    assert_eq!(stages, ["octree", "triangles", "simplifying", "writing"]);
    let vertices = read_stl(&output);
    assert_eq!(vertices.len() as u64, 3 * triangles);
    // Every vertex lies within the bounds, which close the cut sphere.
    for v in vertices.iter().flatten() {
        assert!(v.abs() <= 1.0 + 1e-3, "{v}");
    }

    let reply = server.request(json!({"op": "mesh", "output": output, "resolution": 1e6}));
    assert!(
        reply["error"].as_str().unwrap_or("").contains("octree"),
        "{reply}"
    );
}

#[test]
fn meshes_simplify_to_the_tolerance_asked() {
    let dir = scratch("mesh-tolerance");
    let output = dir.join("model.stl");
    let mut server = Server::start(&[]);
    server.load(
        "bounds([-1, -1, -1], [1, 1, 1]);\ndraw(sphere(0.8));\n",
        None,
    );
    let mesh = |server: &mut Server, tolerance: f64| {
        let reply = server.request(json!({
            "op": "mesh", "output": output, "resolution": 10, "tolerance": tolerance,
        }));
        let triangles = reply["triangles"].as_u64();
        assert!(triangles.is_some(), "{reply}");
        assert_eq!(reply["tolerance"], tolerance);
        (triangles, reply["meshed"].as_u64())
    };
    let (all, meshed) = mesh(&mut server, 0.0);
    assert_eq!(all, meshed);
    let (fine, _) = mesh(&mut server, 0.001);
    let (coarse, _) = mesh(&mut server, 0.01);
    assert!(coarse < fine && fine < all, "{coarse:?} {fine:?} {all:?}");

    let reply = server.request(json!({"op": "mesh", "output": output, "tolerance": -1}));
    assert!(
        reply["error"].as_str().unwrap_or("").contains("tolerance"),
        "{reply}"
    );
}

#[test]
fn exports_run_beside_renders_and_cancel() {
    let dir = scratch("mesh-cancel");
    let output = dir.join("model.stl");
    std::fs::write(&output, "an earlier mesh").unwrap();
    let mut server = Server::start(&[]);
    assert_eq!(server.request(json!({"op": "cancel"}))["stopped"], false);
    let model = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/models/gyroid-sphere.rhai"),
    )
    .expect("the model exists");
    server.load(&model, None);
    // An octree 1024 cells across takes the gyroid far longer than a frame.
    let mesh = server.send(json!({"op": "mesh", "output": output, "resolution": 500}));
    let frame = server.render(&dir.join("frame.ppm"), json!({}));
    assert!(frame.get("ms").is_some(), "{frame}");

    let cancel = server.send(json!({"op": "cancel"}));
    let replies = [server.reply(), server.reply()];
    let reply_to = |id: i64| {
        replies
            .iter()
            .find(|r| r["id"] == id)
            .unwrap_or_else(|| panic!("no reply to {id}: {replies:?}"))
    };
    assert_eq!(reply_to(cancel)["stopped"], true);
    assert_eq!(reply_to(mesh)["cancelled"], true);
    assert_eq!(std::fs::read(&output).unwrap(), b"an earlier mesh");
    assert!(
        server.progress.iter().any(|p| p["id"] == mesh),
        "{:?}",
        server.progress
    );
}

#[test]
fn refuses_an_empty_mesh() {
    let dir = scratch("mesh-empty");
    let output = dir.join("model.stl");
    std::fs::write(&output, "an earlier mesh").unwrap();
    let mut server = Server::start(&[]);
    server.load(
        "bounds([-1, -1, -1], [1, 1, 1]);\ndraw(move(sphere(1), [5, 0, 0]));\n",
        None,
    );
    let reply = server.request(json!({"op": "mesh", "output": output, "resolution": 10}));
    assert!(
        reply["error"].as_str().unwrap_or("").contains("empty"),
        "{reply}"
    );
    assert_eq!(std::fs::read(&output).unwrap(), b"an earlier mesh");
}

#[test]
fn mesh_vertices_lie_on_the_surface() {
    let dir = scratch("mesh-surface");
    let output = dir.join("model.stl");
    let mut server = Server::start(&[]);
    // A small cylinder whose top lies just above a boundary between cells
    // 16 leaves across: fidget merges the leaves above its rim into one
    // cell, whose vertex lands nine leaves off the surface.
    server.load(
        "bounds([0, 0, -160], [320, 320, 160]);\n\
         draw(circle([159.65, 162.6], 0.4).extrude_z(0.68, 1.28));\n",
        None,
    );
    let reply = server.request(json!({
        "op": "mesh", "output": output, "resolution": 10, "tolerance": 0,
    }));
    assert!(reply["triangles"].as_u64() > Some(0), "{reply}");
    let leaf = 320.0 / 4096.0;
    for [x, y, z] in read_stl(&output).into_iter().map(|v| v.map(f64::from)) {
        let field = ((x - 159.65).hypot(y - 162.6) - 0.4)
            .max(0.68 - z)
            .max(z - 1.28);
        assert!(field.abs() <= leaf, "[{x}, {y}, {z}] is {field} off");
    }
}

// --- trace ---

#[test]
fn traces_each_role_into_svg_and_dxf() {
    let dir = scratch("trace");
    let mut server = Server::start(&[]);
    let loaded = server.load(
        "draw(difference(rectangle([-10, -6], [10, 6]), circle(2)));\n\
         draw(circle([6, 3], 1), #{role: \"engrave\"});\n",
        None,
    );
    assert_eq!(loaded["loaded"], true, "{loaded}");
    let svg = dir.join("plate.svg");
    let reply = server.request(json!({
        "op": "trace", "output": svg, "format": "svg", "resolution": 10,
    }));
    // The plate's four sides, and each circle as two half circles
    assert_eq!(reply["outlines"], 3, "{reply}");
    assert_eq!(reply["lines"], 4, "{reply}");
    assert_eq!(reply["arcs"], 4, "{reply}");
    assert_eq!(reply["tolerance"], 0.01);
    assert_eq!(reply["slice"], json!({"axis": "z", "offset": 0.0}));
    let stages: Vec<&Value> = server
        .progress
        .iter()
        .filter(|p| p["id"] == reply["id"])
        .map(|p| &p["progress"])
        .collect();
    let role = ["grid", "contours", "simplifying"];
    assert_eq!(stages, [&role[..], &role[..], &["writing"]].concat());
    let text = std::fs::read_to_string(&svg).expect("the drawing exists");
    assert!(
        text.contains(r#"width="20mm" height="12mm" viewBox="-10 -6 20 12""#),
        "{text}"
    );
    let engrave = text.find(r#"<g id="engrave""#);
    assert!(
        engrave.is_some() && engrave < text.find(r#"<g id="cut""#),
        "{text}"
    );
    assert!(
        text.contains("A 2 2 0 0 1") && text.contains("A 1 1 0 0 0"),
        "{text}"
    );

    let dxf = dir.join("plate.dxf");
    let reply = server.request(json!({
        "op": "trace", "output": dxf, "format": "dxf", "resolution": 10,
    }));
    assert_eq!(reply["outlines"], 3, "{reply}");
    let text = std::fs::read_to_string(&dxf).expect("the drawing exists");
    assert!(text.starts_with("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n"));
    assert_eq!(text.matches("\nPOLYLINE\n").count(), 3);
    assert!(text.contains("\nLAYER\n2\ncut\n70\n0\n62\n1\n"), "{text}");
}

/// A rounded rectangle is its four sides and four corners, each corner one
/// arc of its own radius: the sides do not run on into the corners as far
/// as the tolerance would let them.
#[test]
fn traces_rounded_corners_as_their_arcs() {
    let dir = scratch("trace-corners");
    let output = dir.join("plate.svg");
    let mut server = with_prelude();
    server.load(
        "draw(rect([20, 10], #{round: 2}).move([0.37, 0.21]));\n",
        None,
    );
    let reply = server.request(json!({
        "op": "trace", "output": output, "format": "svg", "resolution": 10,
    }));
    assert_eq!(
        (&reply["lines"], &reply["arcs"]),
        (&json!(4), &json!(4)),
        "{reply}"
    );
    let text = std::fs::read_to_string(&output).expect("the drawing exists");
    let radii: Vec<f64> = text
        .split(" A ")
        .skip(1)
        .filter_map(|arc| arc.split(' ').next()?.parse().ok())
        .collect();
    assert_eq!(radii.len(), 4, "{text}");
    assert!(radii.iter().all(|&r| close(r, 2.0, 1e-3)), "{radii:?}");
}

#[test]
fn traces_a_slice_of_a_solid_grown_by_the_kerf() {
    let dir = scratch("trace-slice");
    let output = dir.join("slice.svg");
    let mut server = Server::start(&[]);
    server.load("draw(sphere(5));\n", None);
    let mut radius = |extra: Value| {
        let mut request = json!({"op": "trace", "output": output, "format": "svg"});
        if let (Some(request), Value::Object(extra)) = (request.as_object_mut(), extra) {
            request.extend(extra);
        }
        let reply = server.request(request);
        assert_eq!(reply["arcs"], 2, "{reply}");
        let text = std::fs::read_to_string(&output).expect("the drawing exists");
        let arc = text.split(" A ").nth(1).expect("an arc");
        arc.split(' ').next().and_then(|r| r.parse::<f64>().ok())
    };
    // Through the middle of the bounds by default
    assert_eq!(radius(json!({})), Some(5.0));
    assert_eq!(
        radius(json!({"slice": {"axis": "z", "offset": 3}})),
        Some(4.0)
    );
    assert_eq!(
        radius(json!({"slice": {"axis": "x", "offset": -3}})),
        Some(4.0)
    );
    // The sphere's field rises along the slice at 4/5 of its slope, which
    // the kerf allows for to first order.
    let grown = radius(json!({"slice": {"axis": "z", "offset": 3}, "kerf": 0.2}));
    assert!(grown.is_some_and(|r| close(r, 4.1, 1e-3)), "{grown:?}");
    // Tilted about the bounds' centre, the sphere's, it is 3 from it still.
    assert_eq!(
        radius(json!({"slice": {"axis": "y", "offset": 3, "tilt": [30, -20]}})),
        Some(4.0)
    );
}

#[test]
fn trace_errors() {
    let dir = scratch("trace-errors");
    let output = dir.join("part.svg");
    std::fs::write(&output, "an earlier drawing").unwrap();
    let mut server = Server::start(&[]);
    server.load("draw(sphere(1));\n", None);
    let error = |server: &mut Server, extra: Value| {
        let mut request = json!({"op": "trace", "output": output, "format": "svg"});
        if let (Some(request), Value::Object(extra)) = (request.as_object_mut(), extra) {
            request.extend(extra);
        }
        let reply = server.request(request);
        reply["error"].as_str().unwrap_or_default().to_owned()
    };
    assert!(error(&mut server, json!({"kerf": -1})).contains("kerf"));
    assert!(error(&mut server, json!({"tolerance": -1})).contains("tolerance"));
    assert!(error(&mut server, json!({"resolution": 1e5})).contains("grid"));
    assert!(error(&mut server, json!({"format": "png"})).contains("`svg` or `dxf`"));
    let missed = json!({"slice": {"axis": "z", "offset": 2}});
    assert!(error(&mut server, missed).contains("nothing to export"));
    assert_eq!(std::fs::read(&output).unwrap(), b"an earlier drawing");
}

// --- layers ---

/// A cylinder with a hole across it is a ring on each layer below the
/// hole and two half rings on each layer through it, every point on the
/// surface; written as JSON, or in the reply.
#[test]
fn layers_of_a_solid() {
    let dir = scratch("layers");
    let output = dir.join("layers.json");
    let mut server = with_prelude();
    let loaded = server.load(
        "let tube = cylinder(5, [0, 10]).difference(cylinder(2, [-1, 11]));\n\
         let bore = cylinder(1, [-8, 8]).rotate_x(90).move([0, 0, 7]);\n\
         draw(tube.difference(bore));\n",
        None,
    );
    assert_eq!(loaded["loaded"], true, "{loaded}");
    let reply = server.request(json!({
        "op": "layers", "z": [3.05, 7.0], "bounds": "fitted", "resolution": 10,
    }));
    let layers = reply["layers"].as_array().expect("the layers");
    let shapes: Vec<usize> = layers
        .iter()
        .map(|l| l["shapes"].as_array().map_or(0, Vec::len))
        .collect();
    assert_eq!(shapes, [1, 2], "{reply}");
    let ring = layers[0]["shapes"][0].as_array().expect("a ring");
    assert_eq!(ring.len(), 2);
    for (contour, r) in ring.iter().zip([5.0, 2.0]) {
        let flat: Vec<f64> = contour
            .as_array()
            .expect("points")
            .iter()
            .filter_map(Value::as_f64)
            .collect();
        for p in flat.chunks(2) {
            assert!(close(p[0].hypot(p[1]), r, 1e-3), "{p:?} off {r}");
        }
    }

    let reply = server.request(json!({
        "op": "layers", "output": output, "layer_height": 0.5, "bounds": "fitted",
        "resolution": 10,
    }));
    let text = std::fs::read_to_string(&output).expect("the layers exist");
    let written: Value = serde_json::from_str(&text).expect("JSON");
    let count = written["layers"].as_array().map_or(0, Vec::len);
    assert_eq!(reply["layers"], count, "{reply}");
    // The fitted bounds reach past the cylinder's 10 by a few percent.
    assert!((20..=23).contains(&count), "{count}");
    let bottom = written["layers"][0]["z"].as_f64().unwrap_or_default() - 0.25;
    assert!((-0.4..-0.2).contains(&bottom), "{bottom}");
}

#[test]
fn draw_roles() {
    let mut server = Server::start(&[]);
    for (source, message) in [
        (
            "draw(sphere(1), #{role: \"etch\"});",
            "role is cut, score or engrave",
        ),
        ("draw(sphere(1), #{colour: 1});", "no option \"colour\""),
    ] {
        let reply = server.load(source, None);
        let error = diagnostic(&reply)["message"].as_str().unwrap_or_default();
        assert!(error.contains(message), "{reply}");
    }
    let reply = server.request(json!({
        "op": "load", "source": "draw(sphere(1), #{role: \"cut\"});", "dialect": "fidget",
    }));
    assert_eq!(reply["loaded"], false, "{reply}");

    // The 2D views outline each shape in its role's colour, a score
    // inside a part to cut too.
    let frame = scratch("draw-roles").join("frame.ppm");
    server.load(
        "draw(circle(5));\ndraw(circle(3), #{role: \"score\"});\n",
        None,
    );
    for view in ["sdf", "mono"] {
        server.render(&frame, json!({"view": view}));
        let (_, _, pixels) = read_ppm(&frame);
        for colour in [[255, 0, 0], [0, 0, 255]] {
            assert!(pixels.contains(&colour), "{view}: no {colour:?}");
        }
    }
}

// --- eval ---

#[test]
fn eval_values_and_errors() {
    let mut server = Server::start(&[]);
    let script = "let r = 2;\nfn ring(a, b) { a + b }\n";
    let eval = |server: &mut Server, expression: &str| {
        server.request(
            json!({"op": "eval", "source": script, "path": null, "expression": expression}),
        )
    };
    assert_eq!(eval(&mut server, "ring(r, 1.5)")["value"], "3.5");
    assert_eq!(
        eval(&mut server, "[1, \"a\", #{b: x}]")["value"],
        "[1, \"a\", #{b: tree}]"
    );
    let tree = eval(&mut server, "sphere(r)")["value"]
        .as_str()
        .unwrap_or("")
        .to_owned();
    assert!(tree.starts_with("tree: -2 at the origin; x -2"), "{tree}");

    let reply = eval(&mut server, "1 +\nfrob(2)");
    let d = diagnostic(&reply);
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(2), Some(1)),
        "{reply}"
    );
    assert!(d.get("file").is_none());

    // The script's own errors stay where they are in it.
    let reply = server.request(json!({
        "op": "eval", "source": "let a = 1;\nlet b = ;\n", "path": "/m.keycap", "expression": "1",
    }));
    let d = diagnostic(&reply);
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(2), Some(9)),
        "{reply}"
    );
    assert!(d.get("file").is_none(), "{reply}");
}

// --- overrides ---

/// The script's value with `overrides`, as `eval` prints it.
fn overridden(server: &mut Server, source: &str, expression: &str, overrides: Value) -> Value {
    server.request(json!({
        "op": "eval", "source": source, "path": null, "expression": expression,
        "overrides": overrides,
    }))
}

#[test]
fn overrides_replace_top_level_constants() {
    let mut server = Server::start(&[]);
    let source = "const SIZE = 1;\nconst HALF = SIZE / 2.0;\nfn twice(v) { v * 2 }\n";
    assert_eq!(
        overridden(&mut server, source, "[SIZE, HALF]", json!({}))["value"],
        "[1, 0.5]"
    );
    // The value is replaced before the script runs: what uses it follows,
    // although Rhai would have folded the old value into it.
    assert_eq!(
        overridden(
            &mut server,
            source,
            "[SIZE, HALF, twice(SIZE)]",
            json!({"SIZE": 3})
        )["value"],
        "[3, 1.5, 6]"
    );

    let reply = server.request(json!({
        "op": "load", "source": "const R = 1.0;\nbounds([-4, -4, -4], [4, 4, 4]);\ndraw(sphere(R));\n",
        "path": null, "overrides": {"R": 3.0},
    }));
    assert_eq!(reply["loaded"], true, "{reply}");
    assert_eq!(reply["diagnostics"], json!([]), "{reply}");
    let fitted = &reply["bounds"]["fitted"]["upper"][0];
    assert!(fitted.as_f64().is_some_and(|x| x > 2.9), "{reply}");
}

#[test]
fn overrides_take_every_type() {
    let mut server = Server::start(&[]);
    let source =
        "const N = 1;\nconst F = 1.5;\nconst S = \"a\";\nconst B = false;\nconst A = [1, 2];\n";
    let reply = overridden(
        &mut server,
        source,
        "[N, F, S, B, A, type_of(N), type_of(F)]",
        json!({"N": 2, "F": 2.0, "S": "column", "B": true, "A": [1.4, "x", [false]]}),
    );
    assert_eq!(
        reply["value"], "[2, 2.0, \"column\", true, [1.4, \"x\", [false]], \"i64\", \"f64\"]",
        "{reply}"
    );
}

#[test]
fn overrides_only_name_top_level_constants() {
    let mut server = Server::start(&[]);
    let source = "const SIZE = 1;\nlet width = 2;\nif true { const INNER = 3; }\n\
                  fn f() { const LOCAL = 4; LOCAL }\ndraw(sphere(SIZE));\n";
    let load = |server: &mut Server, overrides: Value| {
        server
            .request(json!({"op": "load", "source": source, "path": null, "overrides": overrides}))
    };
    let reply = load(&mut server, json!({"SIZE": 2, "WIDTH": 2}));
    assert_eq!(reply["loaded"], false, "{reply}");
    assert_eq!(
        diagnostic(&reply)["message"],
        "cannot override `WIDTH`: the script has no top-level const of that name"
    );

    let reply = load(&mut server, json!({"width": 3}));
    assert_eq!(reply["loaded"], false, "{reply}");
    let d = diagnostic(&reply);
    assert_eq!(
        d["message"],
        "cannot override `width`: it is a let, not a const"
    );
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(2), Some(1))
    );

    for name in ["INNER", "LOCAL"] {
        let reply = load(&mut server, json!({name: 3}));
        assert_eq!(reply["loaded"], false, "{reply}");
        assert_eq!(
            diagnostic(&reply)["message"],
            format!("cannot override `{name}`: the script has no top-level const of that name")
        );
    }
}

// --- dialects ---

/// A server with the prelude, as keycap starts it.
fn with_prelude() -> Server {
    let prelude = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude");
    Server::start(&["--prelude", &prelude.to_string_lossy()])
}

fn load_fidget(server: &mut Server, source: &str, path: Option<&Path>) -> Value {
    server.request(json!({"op": "load", "source": source, "path": path, "dialect": "fidget"}))
}

#[test]
fn the_fidget_dialect_runs_what_fidgets_tools_run() {
    let mut server = with_prelude();
    let reply = load_fidget(
        &mut server,
        "let s = sphere(#{center: [0, 0, 0], radius: 1});\ndraw_rgb(s, 1, 0.5, 0);\n",
        None,
    );
    assert_eq!(reply["loaded"], true, "{reply}");
    assert_eq!(reply["shapes"][0]["color"], json!([1.0, 0.5, 0.0]));
    assert_eq!(reply["bounds"]["script"], Value::Null);
    assert!(reply["bounds"]["fitted"]["lower"][0].is_number(), "{reply}");

    // fidget's sample models are written for its tools.
    let models = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/models");
    for entry in std::fs::read_dir(&models).expect("the models exist") {
        let path = entry.expect("readable").path();
        let source = std::fs::read_to_string(&path).expect("readable");
        let reply = load_fidget(&mut server, &source, Some(&path));
        assert_eq!(reply["loaded"], true, "{}: {reply}", path.display());
    }

    // fidget's tools stop a script past 50,000 operations, keycap past far
    // more.
    let long = "let n = 0;\nfor i in 0..20000 { n += 1; }\ndraw(sphere(1));\n";
    let reply = load_fidget(&mut server, long, None);
    assert_eq!(reply["loaded"], true, "{reply}");
    let d = diagnostic(&reply);
    assert_eq!(d["severity"], "warning");
    assert_eq!(d["line"], 1);
    let message = d["message"].as_str().unwrap_or_default();
    assert!(
        message.ends_with("operations; fidget's own tools stop at 50000 operations"),
        "{message}"
    );
    let reply = server.load(long, None);
    assert_eq!(reply["diagnostics"], json!([]), "{reply}");
    let reply = load_fidget(&mut server, "draw(sphere(1));\n", None);
    assert_eq!(reply["diagnostics"], json!([]), "{reply}");
}

#[test]
fn the_fidget_dialect_names_keycaps_extensions() {
    let mut server = with_prelude();
    for (source, name) in [
        ("draw(text(\"A\"));\n", "text"),
        ("draw(svg(\"a.svg\"));\n", "svg"),
        ("bounds([-1, -1, -1], [1, 1, 1]);\n", "bounds"),
        ("resolution(10);\n", "resolution"),
        ("draw(cuboid([1, 2, 3]));\n", "cuboid"),
        ("draw(sphere(1).cuboid());\n", "cuboid"),
    ] {
        let reply = load_fidget(&mut server, source, None);
        assert_eq!(
            diagnostic(&reply)["message"],
            format!("`{name}` is a keycap extension: rename the file to .keycap"),
            "{source}"
        );
    }
    // Other missing functions are Rhai's to report.
    let reply = load_fidget(&mut server, "draw(frobnicate(1));\n", None);
    let message = diagnostic(&reply)["message"]
        .as_str()
        .unwrap_or("")
        .to_owned();
    assert!(
        message.starts_with("Function not found: frobnicate"),
        "{message}"
    );

    // fidget's viewer draws any number of shapes.
    let reply = load_fidget(
        &mut server,
        "draw(sphere(1));\ndraw_rgb(sphere(2), 1, 0, 0);\n",
        None,
    );
    assert_eq!(reply["loaded"], true, "{reply}");
    assert_eq!(reply["shapes"].as_array().map(Vec::len), Some(2), "{reply}");

    // The keycap dialect has them all.
    let reply = server.load(
        "draw(cuboid([1, 2, 3]));\ndraw(text(\"A\").extrude(1));\nbounds([-9, -9, -9], [9, 9, 9]);\n",
        None,
    );
    assert_eq!(reply["loaded"], true, "{reply}");

    // So does an expression evaluated in the script's scope.
    let reply = server.request(json!({
        "op": "eval", "source": "let a = 1;\n", "path": null, "dialect": "fidget",
        "expression": "cuboid([a, a, a])",
    }));
    assert_eq!(
        diagnostic(&reply)["message"],
        "`cuboid` is a keycap extension: rename the file to .keycap"
    );
}

/// A `.fidget` script means the same as a `.keycap` one: keycap adds names
/// and overloads, and wraps a fidget or Rhai built-in (`hypot`) only to
/// take trees or numbers as well, never changing the value of a call of it.
#[test]
fn fidget_calls_mean_the_same_in_the_keycap_dialect() {
    let mut server = with_prelude();
    let mut eval = |dialect: &str, expression: &str| {
        server.request(json!({
            "op": "eval", "source": "", "path": null, "dialect": dialect, "expression": expression,
        }))["value"]
            .clone()
    };
    // Trees read at a point off the origin, moved there.
    let at = |shape: &str| format!("move({shape}, [-1.25, -0.5, -0.75])");
    for expression in [
        "hypot(3.0, 4.0)".to_owned(),
        "hypot(0.1, 0.7)".to_owned(),
        "sin(0.5)".to_owned(),
        "atan(1.0, -1.0)".to_owned(),
        "min(2, 3.5)".to_owned(),
        at("atan2(y, x)"),
        at("rectangle([-1, -1], [1, 1])"),
        at("box([-1, -1, -1], [1, 2, 3])"),
        at("extrude_z(circle(1), 0, 2)"),
        at("scale_uniform(sphere(1), 2.0)"),
        at("rotate_z(sphere([1, 0, 0], 1), 30)"),
        at("union(sphere(1), sphere([2, 0, 0], 1)).inverse()"),
        at("loft_z(circle(1), circle(2), 0, 1)"),
    ] {
        let fidget = eval("fidget", &expression);
        assert!(fidget.is_string(), "{expression}: {fidget}");
        assert_eq!(eval("keycap", &expression), fidget, "{expression}");
    }
}

/// keycap's math takes numbers where fidget's takes only trees, or turns
/// integers into trees, and trees where Rhai's takes only numbers; a
/// `.fidget` script keeps fidget's and Rhai's own.
#[test]
fn keycap_math_takes_numbers_and_trees_alike() {
    let mut server = with_prelude();
    let mut eval = |dialect: &str, expression: &str| {
        let reply = server.request(json!({
            "op": "eval", "source": "", "path": null, "dialect": dialect, "expression": expression,
        }));
        let value = reply["value"].as_str().map(str::to_owned);
        value.unwrap_or_else(|| {
            diagnostic(&reply)["message"]
                .as_str()
                .unwrap_or("")
                .to_owned()
        })
    };
    for (expression, keycap, fidget) in [
        ("sqrt(4)", "2.0", "tree: 2 at the origin"),
        ("square(3.0)", "9.0", "tree: 9 at the origin"),
        (
            "atan2(0.0, 1.0)",
            "0.0",
            "Function not found: atan2 (f64, f64)",
        ),
        (
            "move(x ** 2, [3, 0, 0])",
            "tree: 9 at the origin",
            "Function not found: ** (Tree, i64)",
        ),
        (
            "move(tanh(x), [-1, 0, 0])",
            "tree: 0.7616 at the origin",
            "Function not found: tanh (Tree)",
        ),
        (
            "move(sphere(1).remap(x, 0, 0), [1, 0, 0])",
            "tree: 0 at the origin",
            "Function not found: remap",
        ),
    ] {
        let got = eval("keycap", expression);
        assert!(got.starts_with(keycap), "{expression}: {got}");
        let got = eval("fidget", expression);
        assert!(
            got.starts_with(fidget),
            "{expression} in fidget's dialect: {got}"
        );
    }
}

#[test]
fn the_dialects_import_their_own_files() {
    let dir = scratch("dialects");
    std::fs::write(dir.join("part.keycap"), "fn size() { 2 }\n").expect("writable");
    std::fs::write(dir.join("part.fidget"), "fn size() { 1 }\n").expect("writable");
    std::fs::write(dir.join("text.rhai"), "fn label() { text(\"A\") }\n").expect("writable");
    let script = dir.join("main");
    let mut server = with_prelude();
    let source = "import \"part\" as part;\nprint(part::size());\ndraw(sphere(1));\n";

    let reply = server.load(source, Some(&script));
    assert_eq!(reply["output"], json!(["2"]), "{reply}");
    let reply = load_fidget(&mut server, source, Some(&script));
    assert_eq!(reply["output"], json!(["1"]), "{reply}");

    // An imported file is in the importing script's dialect.
    let reply = load_fidget(
        &mut server,
        "import \"text\" as t;\ndraw(t::label());\n",
        Some(&script),
    );
    let d = diagnostic(&reply);
    assert!(
        d["file"].as_str().unwrap_or("").ends_with("text.rhai"),
        "{d}"
    );
    assert_eq!(
        d["message"],
        "`text` is a keycap extension: rename the file to .keycap"
    );
}

#[test]
fn docs_of_the_fidget_dialect_are_fidgets_own() {
    let mut server = with_prelude();
    let functions = |reply: &Value| -> Vec<(String, String)> {
        reply["functions"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|f| {
                let text = |key: &str| f[key].as_str().unwrap_or("").to_owned();
                (text("name"), text("source"))
            })
            .collect()
    };
    let fidget = functions(&server.request(json!({"op": "docs", "dialect": "fidget"})));
    let keycap = functions(&server.request(json!({"op": "docs"})));
    let source = |functions: &[(String, String)], name: &str| {
        functions
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, source)| source.clone())
    };

    assert_eq!(source(&fidget, "draw").as_deref(), Some("fidget"));
    assert_eq!(source(&fidget, "draw_rgb").as_deref(), Some("fidget"));
    assert_eq!(source(&fidget, "min").as_deref(), Some("fidget"));
    for name in ["text", "svg", "bounds", "resolution", "cuboid"] {
        assert_eq!(source(&fidget, name), None, "{name}");
    }
    assert!(
        fidget.iter().all(|(_, s)| s == "fidget" || s == "rhai"),
        "{fidget:?}"
    );

    assert_eq!(source(&keycap, "draw").as_deref(), Some("keycap"));
    assert_eq!(source(&keycap, "text").as_deref(), Some("keycap"));
    assert_eq!(source(&keycap, "cuboid").as_deref(), Some("prelude"));
}

/// fidget's built-ins with a better keycap call name it in the keycap
/// dialect, a function of the prelude, and say nothing of it in fidget's.
#[test]
fn docs_name_the_keycap_call_to_prefer() {
    let mut server = with_prelude();
    let keycap = server.request(json!({"op": "docs"}));
    let fidget = server.request(json!({"op": "docs", "dialect": "fidget"}));
    let entries = |reply: &Value| -> Vec<Value> {
        ["shapes", "functions"]
            .iter()
            .flat_map(|key| reply[key].as_array().cloned().unwrap_or_default())
            .collect()
    };
    let prelude: Vec<String> = entries(&keycap)
        .iter()
        .filter(|f| f["source"] == "prelude")
        .filter_map(|f| f["name"].as_str().map(str::to_owned))
        .collect();
    let preferred: Vec<Value> = entries(&keycap)
        .into_iter()
        .filter(|e| e.get("prefer").is_some())
        .collect();
    assert!(preferred.iter().any(|e| e["name"] == "rectangle"));
    for entry in preferred {
        let prefer = entry["prefer"].as_str().unwrap_or("");
        let name = prefer.split('(').next().unwrap_or("");
        assert!(prelude.iter().any(|p| p == name), "{entry}");
        assert!(
            entry["why"].as_str().is_some_and(|w| !w.is_empty()),
            "{entry}"
        );
    }
    assert!(entries(&fidget).iter().all(|e| e.get("prefer").is_none()));
}

// --- docs and the prelude ---

#[test]
fn docs_describe_shapes_and_functions() {
    let mut server = Server::start(&[]);
    let reply = server.request(json!({"op": "docs"}));
    let circle = reply["shapes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|s| s["name"] == "circle")
        .cloned()
        .unwrap_or_default();
    assert_eq!(circle["fields"][0]["name"], "center");
    assert_eq!(circle["fields"][0]["type"], "Vec2");
    assert_eq!(circle["fields"][0]["default"], "[0, 0]");
    assert!(!circle["doc"].as_str().unwrap_or("").is_empty());

    let function = |name: &str| {
        reply["functions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|f| f["name"] == name)
            .cloned()
    };
    assert_eq!(
        function("draw_rgb").map(|f| f["source"].clone()),
        Some("keycap".into())
    );
    assert_eq!(
        function("min").map(|f| f["source"].clone()),
        Some("fidget".into())
    );
    assert_eq!(
        function("push").map(|f| f["source"].clone()),
        Some("rhai".into())
    );
    assert!(
        function("circle").is_none(),
        "shapes are described with the shapes"
    );
    assert!(function("get$x").is_none());
}

#[test]
fn docs_give_typed_signatures() {
    let mut server = with_prelude();
    let reply = server.request(json!({"op": "docs"}));
    let named = |kind: &str, name: &str| {
        reply[kind]
            .as_array()
            .into_iter()
            .flatten()
            .find(|f| f["name"] == name)
            .cloned()
            .unwrap_or_default()
    };
    // A doc comment's signatures, and their method forms
    let offset = named("functions", "offset");
    assert_eq!(
        offset["signatures"],
        json!([
            "offset(shape: Shape, d: Tree): Shape",
            "shape.offset(d: Tree): Shape"
        ])
    );
    assert!(offset.get("types").is_none());
    assert!(
        offset["doc"]
            .as_str()
            .unwrap_or("")
            .starts_with("Grows a shape")
    );
    // The prelude's hypot, not Rhai's own it shadows
    let hypot = named("functions", "hypot");
    let doc = hypot["doc"].as_str().unwrap_or("");
    assert!(doc.starts_with("The length of `[a, b]`"), "{doc}");
    assert!(!doc.contains("Return the hypotenuse"), "{doc}");
    let loft = named("functions", "loft");
    assert_eq!(
        loft["signatures"],
        json!([
            "loft(slices: Slice[]): Shape",
            "loft(h: Height, slice: (t: Tree) => Shape | Section): Shape"
        ])
    );
    assert!(
        loft["types"][0]
            .as_str()
            .unwrap_or("")
            .starts_with("type Slice = #{\n")
    );
    // fidget's shapes, from their fields
    assert_eq!(
        named("shapes", "sphere")["signatures"],
        json!([
            "sphere(center: Vec3 = [0, 0, 0], radius: number = 1): Shape",
            "sphere(#{ center?: Vec3, radius?: number }): Shape"
        ])
    );
    assert_eq!(
        named("shapes", "union")["signatures"],
        json!([
            "union(...input: Shape[]): Shape",
            "union(input: Shape[]): Shape"
        ])
    );
    assert_eq!(
        named("shapes", "move")["signatures"],
        json!([
            "move(shape: Shape, offset: Vec3 = [0, 0, 0]): Shape",
            "shape.move(offset: Vec3 = [0, 0, 0]): Shape",
            "shape.move(#{ offset: Vec3 }): Shape"
        ])
    );
    // Two numbers: by position, both come, in order; only the map leaves
    // either out.
    assert_eq!(
        named("shapes", "repeat_x")["signatures"],
        json!([
            "repeat_x(shape: Shape, radius: number, offset: number): Shape",
            "shape.repeat_x(radius: number, offset: number): Shape",
            "shape.repeat_x(#{ radius: number, offset: number }): Shape",
            "repeat_x(#{ shape: Shape, radius?: number, offset?: number }): Shape"
        ])
    );
    // A function that takes the parameters after a number is no method.
    assert_eq!(
        named("functions", "ease_in_pow")["signatures"],
        json!([
            "ease_in_pow(t: Tree, n: number): Tree",
            "ease_in_pow(n: number): Ease"
        ])
    );
}

/// The reference's sections are the files that describe its entries:
/// every one declares its kind, and each entry names its file and kind.
#[test]
fn docs_set_out_the_reference_by_file() {
    let mut server = with_prelude();
    let reply = server.request(json!({"op": "docs"}));
    let sections = reply["sections"].as_array().cloned().unwrap_or_default();
    let file = |name: &str| {
        sections
            .iter()
            .find(|s| s["file"] == name)
            .cloned()
            .unwrap_or_default()
    };
    for section in &sections {
        assert!(section["kind"].is_string(), "{section} declares no kind");
    }
    assert_eq!(
        file("server/docs/shapes-3d.toml")["names"],
        json!(["sphere", "box", "plane"])
    );
    assert_eq!(file("prelude/csg.rhai")["kind"], "csg");
    assert_eq!(file("prelude/csg.rhai")["names"][0], "offset");
    assert_eq!(file("prelude/modules/lasercut.rhai")["module"], "lc");

    let entries: Vec<Value> = ["shapes", "functions", "modules"]
        .iter()
        .flat_map(|key| reply[key].as_array().cloned().unwrap_or_default())
        .collect();
    let named = |name: &str| {
        entries
            .iter()
            .find(|e| e["name"] == name)
            .cloned()
            .unwrap_or_default()
    };
    assert_eq!(named("sphere")["kind"], "3d");
    let sphere = named("sphere")["doc"].as_str().unwrap_or("").to_owned();
    assert!(sphere.contains("Example:"), "the docs' own, not fidget's");
    assert_eq!(named("offset")["file"], "prelude/csg.rhai");
    assert_eq!(named("TAU")["kind"], "math", "variables are described too");
    // An alias has its name's entry, and only the name is in the section.
    assert_eq!(named("TAU")["doc"], named("PI")["doc"]);
    assert_eq!(named("PI")["aliases"][0], "TAU");
    let constants = file("server/docs/constants.toml")["names"].to_string();
    assert!(constants.contains("\"PI\"") && !constants.contains("\"TAU\""));
    // Every name a section lists is described.
    for section in &sections {
        for name in section["names"].as_array().into_iter().flatten() {
            assert!(named(name.as_str().unwrap_or("")).is_object(), "{name}");
        }
    }
    // A module's functions, by the name its header imports it as
    let hole = named("screws::hole");
    assert_eq!(hole["kind"], "3d");
    assert_eq!(hole["file"], "prelude/modules/screws.rhai");
    let signatures = hole["signatures"].as_array().cloned().unwrap_or_default();
    assert!(!signatures.is_empty());
    assert!(
        signatures
            .iter()
            .all(|s| s.as_str().unwrap_or("").starts_with("screws::hole(")),
        "{signatures:?}"
    );
    assert!(!hole["doc"].as_str().unwrap_or("").starts_with("hole("));
}

/// A module a script imports is described under the name it gives it,
/// its signatures too.
#[test]
fn imported_functions_have_their_signatures() {
    let mut server = with_prelude();
    let reply = server.load("import \"keycap/screws\" as s;\ndraw(sphere(1));\n", None);
    let hole = reply["functions"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|f| f["name"] == "s::hole")
        .cloned()
        .unwrap_or_default();
    let signature = hole["signatures"][0].as_str().unwrap_or("");
    assert!(signature.starts_with("s::hole(d: number"), "{hole}");
}

#[test]
fn the_prelude_is_global_and_documented() {
    let dir = scratch("prelude");
    // The files make one module: `b.rhai` calls `a.rhai`'s private helper,
    // and `a.rhai` ends without a newline.
    std::fs::write(dir.join("a.rhai"), "private fn helper(v) {\n    v * 2\n}").expect("writable");
    std::fs::write(
        dir.join("b.rhai"),
        "/// Doubles a number.\nfn twice(v) {\n    helper(v)\n}\n\nfn broken(s) {\n    s + nope\n}\n\
         \n/// Scales a shape.\nfn scaled(s, v) {\n    s * v\n}\n\nfn scaled(v) { scaled(this, v) }\n",
    )
    .expect("writable");
    let prelude = dir.to_string_lossy().into_owned();
    let mut server = Server::start(&["--prelude", &prelude]);

    let reply = server.load("draw(sphere(twice(1)));\n", None);
    assert_eq!(reply["loaded"], true, "{reply}");
    assert_eq!(reply["diagnostics"], json!([]));

    let reply = server.load("let s = sphere(1);\ndraw(broken(s));\n", None);
    let d = diagnostic(&reply);
    assert!(d["file"].as_str().unwrap_or("").ends_with("b.rhai"), "{d}");
    assert_eq!(d["line"], 7);
    assert_eq!(d["trace"][0]["line"], 2);
    assert!(d["trace"][0].get("file").is_none(), "{d}");

    let reply = server.load("draw(sphere(helper(1)));\n", None);
    assert_eq!(
        reply["loaded"], false,
        "private functions stay in the prelude"
    );

    let reply = server.request(json!({"op": "docs"}));
    let function = |name: &str| {
        reply["functions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|f| f["name"] == name)
            .cloned()
    };
    let twice = function("twice").unwrap_or_default();
    assert_eq!(twice["source"], "prelude");
    assert_eq!(twice["category"], "Prelude: b");
    assert_eq!(twice["doc"], "Doubles a number.");
    let scaled = function("scaled").unwrap_or_default();
    assert_eq!(scaled["doc"], "Scales a shape.");
    assert_eq!(scaled["signatures"], json!(["s.scaled(v)", "scaled(s, v)"]));
    assert!(
        function("helper").is_none(),
        "private functions are not documented"
    );
}

#[test]
fn broken_prelude_files_warn() {
    let dir = scratch("broken-prelude");
    std::fs::write(dir.join("bad.rhai"), "fn oops( {\n").expect("writable");
    std::fs::write(dir.join("good.rhai"), "fn fine() {\n    1\n}\n").expect("writable");
    let prelude = dir.to_string_lossy().into_owned();
    let mut server = Server::start(&["--prelude", &prelude]);
    let reply = server.load("draw(sphere(fine()));\n", None);
    assert_eq!(reply["loaded"], true, "the other files still load: {reply}");
    let d = diagnostic(&reply);
    assert_eq!(d["severity"], "warning");
    assert!(
        d["file"].as_str().unwrap_or("").ends_with("bad.rhai"),
        "{d}"
    );
    assert_eq!(d["line"], 1);
}

#[test]
fn the_preludes_modules_import_by_name() {
    let dir = scratch("modules");
    std::fs::create_dir_all(dir.join("prelude/modules")).expect("writable");
    std::fs::create_dir_all(dir.join("work/keycap")).expect("writable");
    std::fs::write(dir.join("prelude/base.rhai"), "fn twice(v) { v * 2 }\n").expect("writable");
    // A module calls the prelude, and other modules by their names.
    std::fs::write(
        dir.join("prelude/modules/pegs.rhai"),
        "import \"keycap/sizes\" as sizes;\n\n\
         /// A peg's radius.\nfn radius(name) { twice(sizes::of(name)) }\n",
    )
    .expect("writable");
    std::fs::write(
        dir.join("prelude/modules/sizes.rhai"),
        "fn of(name) { #{small: 1, large: 2}[name] }\n",
    )
    .expect("writable");
    // The prefix is the prelude's, whatever lies beside the script.
    std::fs::write(
        dir.join("work/keycap/pegs.keycap"),
        "fn radius(name) { 0 }\n",
    )
    .expect("writable");
    let script = dir.join("work/main.keycap");
    let prelude = dir.join("prelude").to_string_lossy().into_owned();
    let mut server = Server::start(&["--prelude", &prelude]);
    let source =
        "import \"keycap/pegs\" as pegs;\nprint(pegs::radius(\"large\"));\ndraw(sphere(1));\n";

    let reply = server.load(source, Some(&script));
    assert_eq!(reply["output"], json!(["4"]), "{reply}");
    let radius = &reply["functions"][0];
    assert_eq!(radius["name"], "pegs::radius", "{reply}");
    assert_eq!(radius["doc"], "A peg's radius.");

    // Modules are not global, so the prelude alone does not load them.
    let reply = server.load("print(radius(\"large\"));\n", Some(&script));
    assert_eq!(reply["loaded"], false, "{reply}");

    let reply = server.load("import \"keycap/missing\" as m;\n", Some(&script));
    assert!(
        diagnostic(&reply)["message"]
            .as_str()
            .unwrap_or("")
            .contains("keycap/missing"),
        "{reply}"
    );

    // fidget's tools have no such modules, but a file of that name is
    // still its own.
    let reply = load_fidget(&mut server, source, Some(&script));
    assert_eq!(
        diagnostic(&reply)["message"],
        "`keycap/pegs` is a keycap module: rename the file to .keycap"
    );
    std::fs::write(
        dir.join("work/keycap/pegs.fidget"),
        "fn radius(name) { 3 }\n",
    )
    .expect("writable");
    let reply = load_fidget(&mut server, source, Some(&script));
    assert_eq!(reply["output"], json!(["3"]), "{reply}");
}

/// Every example in the prelude's modules runs, with all of them imported
/// in the order of their names, each under the name its header imports it
/// as, and a shape it makes is bounded.  An example is a block: its last
/// expression is the value.
#[test]
fn the_preludes_modules_examples_run() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../prelude/modules");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("the prelude has modules")
        .filter_map(|entry| Some(entry.ok()?.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "rhai"))
        .collect();
    files.sort();
    let imports: String = files
        .iter()
        .map(|file| {
            let text = std::fs::read_to_string(file).expect("readable");
            // The header's `//     import "keycap/nuts" as nuts;`
            text.lines()
                .find_map(|l| {
                    l.strip_prefix("//     import ")
                        .map(|l| format!("import {l}\n"))
                })
                .unwrap_or_else(|| panic!("{} has no import line", file.display()))
        })
        .collect();
    let mut server = with_prelude();
    let mut examples = 0;
    for file in &files {
        let text = std::fs::read_to_string(file).expect("readable");
        let lines: Vec<&str> = text.lines().map(|l| l.trim_start_matches("///")).collect();
        let mut rest = lines.as_slice();
        while let Some(at) = rest.iter().position(|l| l.starts_with(" Example:")) {
            let code: Vec<&str> = rest[at + 2..]
                .iter()
                .take_while(|l| l.trim() != "```")
                .map(|l| l.strip_prefix(' ').unwrap_or(l))
                .collect();
            rest = &rest[at + 2 + code.len()..];
            let code = code.join("\n");
            let source = format!(
                "{imports}let v = {{\n{code}\n}};\nif type_of(v) == \"Tree\" {{ draw(v); }} else {{ print(v); }}\n"
            );
            let reply = server.load(&source, None);
            let place = format!("{}: {code}", file.display());
            assert_eq!(reply["loaded"], true, "{place}\n{reply}");
            // A 2D shape has no bounds along Z, but every other has some.
            let fitted = &reply["bounds"]["fitted"];
            if !fitted.is_null() {
                let planar = fitted["lower"][2].is_null() && fitted["upper"][2].is_null();
                let axes = if planar { 2 } else { 3 };
                let bounded = (0..axes)
                    .all(|i| fitted["lower"][i].is_number() && fitted["upper"][i].is_number());
                assert!(bounded, "{place}\nunbounded: {fitted}");
            }
            examples += 1;
        }
    }
    assert!(examples > 20, "only {examples} examples found");
}

/// The gears refuse an option they do not know, as the rest of the prelude
/// does, and `gear_radii` takes `involute_gear`'s `fillet`, so that one map
/// serves both.
#[test]
fn gears_refuse_unknown_options() {
    let mut server = with_prelude();
    for call in [
        "involute_gear(12, 2, #{presure_angle: 25})",
        "gear_radii(12, 2, #{presure_angle: 25})",
    ] {
        let reply = server.load(&format!("let v = {call};\n"), None);
        assert_eq!(reply["loaded"], false, "{call}\n{reply}");
        let message = diagnostic(&reply)["message"].as_str().unwrap_or("");
        assert!(
            message.contains("unknown option presure_angle"),
            "{call}\n{reply}"
        );
    }
    let reply = server.load("let v = gear_radii(12, 2, #{fillet: 0.76});\n", None);
    assert_eq!(reply["loaded"], true, "{reply}");
}

/// The panels of a box from `keycap/lasercut` mate: along each kind of
/// joint, in the middle of every finger, exactly one of the two panels has
/// material.
#[test]
fn the_lasercut_boxes_joints_mate() {
    let mut server = with_prelude();
    let script = "import \"keycap/lasercut\" as lc;\nlet p = lc::box_panels([60, 40, 30], 3);\n";
    let mut inside = |shape: &str, at: [f64; 2]| -> bool {
        // The field at a point, as the value at the origin of the shape
        // moved there.
        let expression = format!("{shape}.move([{}, {}])", -at[0], -at[1]);
        let reply = server.request(
            json!({"op": "eval", "source": script, "path": null, "expression": expression}),
        );
        let value = reply["value"].as_str().unwrap_or("");
        let v: f64 = value
            .strip_prefix("tree: ")
            .and_then(|v| v.split(' ').next())
            .and_then(|v| v.parse().ok())
            .unwrap_or_else(|| panic!("{reply}"));
        v < 0.0
    };
    // Each joint as two panels, the middle of its strip in each, as a
    // point and a direction along the edge, the joint's length and its
    // count of fingers: 60 / 6 and 40 / 6 rounded to odd counts, and the
    // upright edges' 24 between the bottom and the top.
    let joints = [
        (
            "p.bottom",
            [0.0, -18.5],
            [1.0, 0.0],
            "p.front",
            [0.0, -13.5],
            [1.0, 0.0],
            60.0,
            11,
        ),
        (
            "p.bottom",
            [-28.5, 0.0],
            [0.0, 1.0],
            "p.left",
            [0.0, -13.5],
            [1.0, 0.0],
            40.0,
            7,
        ),
        (
            "p.front",
            [-28.5, 0.0],
            [0.0, 1.0],
            "p.left",
            [-18.5, 0.0],
            [0.0, 1.0],
            24.0,
            5,
        ),
    ];
    for (a, a_at, a_dir, b, b_at, b_dir, length, n) in joints {
        for i in 0..n {
            let s = length * ((i as f64 + 0.5) / n as f64 - 0.5);
            let pa = [a_at[0] + a_dir[0] * s, a_at[1] + a_dir[1] * s];
            let pb = [b_at[0] + b_dir[0] * s, b_at[1] + b_dir[1] * s];
            assert_ne!(
                inside(a, pa),
                inside(b, pb),
                "{a} and {b}, finger {i} of {n}"
            );
        }
    }
}

/// A point on a Bézier curve has as many components as its control
/// points, `vec2`s included.
#[test]
fn bezier_points_keep_their_control_points_dimension() {
    let mut server = with_prelude();
    for (expression, value) in [
        (
            "bezier_point([[0, 0], [10, 20], [20, 0]], 0.5)",
            "[10.0, 10.0]",
        ),
        (
            "bezier_point([vec2(0, 0), vec2(10, 20), vec2(20, 0)], 0.5)",
            "[10.0, 10.0]",
        ),
        (
            "bezier_point([[0, 0, 0], [10, 20, 4], [20, 0, 0]], 0.5)",
            "[10.0, 10.0, 2.0]",
        ),
        ("bezier_point([0, 10, 10, 0], 0.5)", "7.5"),
    ] {
        let reply = server
            .request(json!({"op": "eval", "source": "", "path": null, "expression": expression}));
        assert_eq!(reply["value"], value, "{expression}\n{reply}");
    }
}

// --- The protocol itself ---

#[test]
fn malformed_requests_get_errors() {
    let mut server = Server::start(&[]);
    server.send_line("{not json");
    let reply = server.reply();
    assert_eq!(reply["id"], Value::Null);
    assert!(reply["error"].as_str().unwrap_or("").contains("JSON"));

    let reply = server.request(json!({"op": "frobnicate"}));
    assert!(
        reply["error"].as_str().unwrap_or("").contains("frobnicate"),
        "{reply}"
    );

    let reply = server.request(json!({"op": "probe", "x": 1, "y": 1}));
    assert!(
        reply["error"].is_string(),
        "nothing is rendered yet: {reply}"
    );

    let reply = server.render(Path::new("/nonexistent/frame.ppm"), json!({}));
    assert!(reply["error"].is_string(), "nothing is loaded: {reply}");
}

#[test]
fn threads_are_capped() {
    let dir = scratch("threads");
    let mut server = Server::start(&["--threads", "2"]);
    server.load("draw(sphere(1));\n", None);
    server.render(&dir.join("frame.ppm"), json!({}));
    let reply = server.request(json!({"op": "mesh", "output": dir.join("model.stl")}));
    assert!(reply.get("triangles").is_some(), "{reply}");
    // The main thread, the reader, the render thread, and two threads each
    // to render and to export, once the thread the export replied from is
    // gone
    let count = || {
        std::fs::read_dir(format!("/proc/{}/task", server.child.id()))
            .map(|tasks| tasks.count())
            .unwrap_or(0)
    };
    let mut tasks = count();
    for _ in 0..20 {
        if tasks <= 7 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
        tasks = count();
    }
    assert!(tasks <= 7, "{tasks} threads");

    // Frames give way to the rest of the machine, exports more so.
    let nice = |name: &str| -> Vec<String> {
        let tasks = std::fs::read_dir(format!("/proc/{}/task", server.child.id()));
        let mut nice: Vec<String> = tasks
            .into_iter()
            .flatten()
            .flatten()
            .filter(|task| {
                std::fs::read_to_string(task.path().join("comm"))
                    .is_ok_and(|comm| comm.starts_with(name))
            })
            .filter_map(|task| {
                let stat = std::fs::read_to_string(task.path().join("stat")).ok()?;
                // The fields after the name, which may hold spaces
                let fields: Vec<&str> = stat.rsplit_once(')')?.1.split_whitespace().collect();
                fields.get(16).map(|nice| nice.to_string())
            })
            .collect();
        nice.sort();
        nice
    };
    assert_eq!(nice("keycap-render"), ["5", "5"]);
    assert_eq!(nice("keycap-export"), ["10", "10"]);

    for bad in ["0", "many"] {
        let status = Command::new(env!("CARGO_BIN_EXE_keycap-server"))
            .args(["--threads", bad])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .expect("the server starts");
        assert_eq!(status.code(), Some(2), "--threads {bad}");
    }
}

#[test]
fn the_sample_models_load() {
    let dir = scratch("models");
    let models = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/models");
    let mut server = Server::start(&[]);
    for entry in std::fs::read_dir(&models).expect("the models exist") {
        let path = entry.expect("readable").path();
        let source = std::fs::read_to_string(&path).expect("readable");
        let reply = server.load(&source, Some(&path));
        assert_eq!(reply["loaded"], true, "{}: {reply}", path.display());
        let fitted = &reply["bounds"]["fitted"];
        // Perlin noise fills all of space; the others are bounded.
        let bounded = !path.ends_with("perlin.rhai");
        assert_eq!(
            (0..3).all(|i| fitted["lower"][i].is_number() && fitted["upper"][i].is_number()),
            bounded,
            "{}: {fitted}",
            path.display()
        );
        let reply = server.render(&dir.join("frame.ppm"), json!({"width": 64, "height": 64}));
        assert!(reply.get("ms").is_some(), "{}: {reply}", path.display());
    }
}

// --- notes on built-ins with a better keycap call ---

/// The notes of `reply`, as `(line, column, message)`.
fn notes(reply: &Value) -> Vec<(u64, u64, String)> {
    reply["diagnostics"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|d| d["severity"] == "note")
        .map(|d| {
            let number = |key: &str| d[key].as_u64().expect("a position");
            let message = d["message"].as_str().expect("a message").to_owned();
            (number("line"), number("column"), message)
        })
        .collect()
}

#[test]
fn keycap_scripts_get_a_note_on_a_built_in_with_a_better_call() {
    let mut server = with_prelude();
    let source = "let a = 1;\n  draw(rectangle([0, 0], [1, 1]));\n";
    let reply = server.load(source, None);
    let found = notes(&reply);
    assert_eq!(found.len(), 1, "{reply}");
    let (line, column, message) = &found[0];
    assert_eq!((*line, *column), (2, 8), "{reply}");
    assert!(
        message.starts_with("`rectangle`: prefer `rect("),
        "{message}"
    );
    assert!(message.contains(" -- "), "{message}");
    // The script still ran.
    assert_eq!(reply["loaded"], true, "{reply}");

    // fidget's scripts stay as they are.
    let reply = load_fidget(&mut server, source, None);
    assert!(notes(&reply).is_empty(), "{reply}");
}

#[test]
fn a_comment_silences_the_notes() {
    let mut server = with_prelude();
    let source = "draw(rectangle([0, 0], [1, 1]));\n";
    for silenced in [
        format!("// keycap: no-prefer\n{source}"),
        format!("{source}  // keycap: no-prefer  \n"),
    ] {
        let reply = server.load(&silenced, None);
        assert!(notes(&reply).is_empty(), "{reply}");
        assert_eq!(reply["loaded"], true, "{reply}");
    }
    // Only a line of its own does.
    let reply = server.load(&format!("{source}// keycap: no-prefer, please\n"), None);
    assert_eq!(notes(&reply).len(), 1, "{reply}");
}

#[test]
fn a_note_needs_a_call_of_the_built_in() {
    let mut server = with_prelude();
    let reply = server.load("let box = 1;\ndraw(circle(box));\n", None);
    assert!(notes(&reply).is_empty(), "{reply}");
    let reply = server.load("fn box(s) { s }\ndraw(box(circle(1)));\n", None);
    assert!(notes(&reply).is_empty(), "{reply}");
}
