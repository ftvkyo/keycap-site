// SPDX-License-Identifier: MPL-2.0

//! `text` and `svg` through the protocol: their dimensions against the
//! font's metrics and OpenSCAD's, SVG units and fill rules, and the files
//! a load reports.
//!
//! The default font is the one the build names in `KEYCAP_SERVER_FONT`,
//! Liberation Sans, OpenSCAD's own default.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};

struct Server {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next: i64,
}

impl Server {
    fn start() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_keycap-server"))
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
        }
    }

    fn request(&mut self, mut request: Value) -> Value {
        request["id"] = self.next.into();
        self.next += 1;
        writeln!(self.input, "{request}").expect("the server reads");
        self.input.flush().expect("the server reads");
        let mut line = String::new();
        self.output
            .read_line(&mut line)
            .expect("the server answers");
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("bad reply {line:?}: {e}"))
    }

    fn load(&mut self, source: &str, path: &Path) -> Value {
        self.request(json!({"op": "load", "source": source, "path": path}))
    }

    /// The field of the tree `expression` makes, at `p`, run as the script
    /// `path` would run it.
    fn at(&mut self, path: &Path, expression: &str, p: [f64; 2]) -> f64 {
        let moved = format!("({expression}).remap(x + {:?}, y + {:?}, z)", p[0], p[1]);
        let reply = self.request(json!({
            "op": "eval", "source": "", "path": path, "expression": moved,
        }));
        let value = reply["value"].as_str().unwrap_or_default();
        value
            .strip_prefix("tree: ")
            .and_then(|v| v.split(' ').next())
            .and_then(|v| v.parse().ok())
            .unwrap_or_else(|| panic!("no value for {expression} at {p:?}: {reply}"))
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

fn diagnostic(reply: &Value) -> &Value {
    &reply["diagnostics"][0]
}

/// Asserts the field of `expression` at each point, to `tolerance`.
fn assert_field(
    server: &mut Server,
    path: &Path,
    expression: &str,
    expected: &[([f64; 2], f64)],
    tolerance: f64,
) {
    for &(p, value) in expected {
        let v = server.at(path, expression, p);
        assert!(
            (v - value).abs() <= tolerance,
            "{expression} at {p:?} is {v}, not {value}"
        );
    }
}

// --- text ---

/// An H in Liberation Sans, whose stems are straight, at OpenSCAD 2021.01's
/// size: its cap height is 1409/2048 of an em of size / 0.72, and it starts
/// at its left side bearing.  The numbers are OpenSCAD's own export.
#[test]
fn text_has_openscad_dimensions() {
    let dir = scratch("text");
    let script = dir.join("text.keycap");
    let mut server = Server::start();
    let h = r#"text("H")"#;
    assert_field(
        &mut server,
        &script,
        h,
        &[
            // 1 mm left of the left stem, below it and above it
            ([0.1393, 4.0], 1.0),
            ([1.5, -1.0], 1.0),
            ([1.5, 10.5548], 1.0),
            // 1 mm right of the right stem
            ([9.8970, 4.0], 1.0),
            // Inside the left stem, 0.3 mm from its side
            ([1.4393, 7.0], -0.3),
        ],
        0.005,
    );

    // Centred both ways, the box of "Hg" is OpenSCAD's
    let hg = r#"text("Hg", #{size: 10, halign: "center", valign: "center"})"#;
    assert_field(
        &mut server,
        &script,
        hg,
        &[([-8.5298, 0.0], 1.0), ([-7.0, 7.2985], 1.0)],
        0.005,
    );

    // Spacing stretches the advance, which OpenSCAD takes 1.024 times
    // smaller than the font's
    let spaced = r#"text("HH", #{spacing: 1.5})"#;
    assert_field(
        &mut server,
        &script,
        spaced,
        &[([24.5895, 4.0], 1.0)],
        0.005,
    );

    // Twice the size, twice the H, aligned by OpenSCAD's metrics: 1 mm
    // above its right stem
    let big = r#"text("H", #{size: 20, valign: "top", halign: "right"})"#;
    let top = 2.0 * 9.5548 - 2.0 * 9.3313;
    assert_field(&mut server, &script, big, &[([-3.0, top + 1.0], 1.0)], 0.01);
}

#[test]
fn libfive_font_is_capital_height_size() {
    let dir = scratch("libfive");
    let script = dir.join("text.keycap");
    let mut server = Server::start();
    // libfive's H: stems 0.1 wide, 1 tall, its left one at the origin
    let h = r#"text("H", #{font: "libfive", size: 10})"#;
    assert_field(
        &mut server,
        &script,
        h,
        &[([-1.0, 5.0], 1.0), ([0.5, 9.0], -0.5), ([0.5, 11.0], 1.0)],
        1e-3,
    );
}

#[test]
fn text_errors_name_the_problem() {
    let dir = scratch("text-errors");
    let script = dir.join("text.keycap");
    let mut server = Server::start();
    let cases = [
        (
            r#"text("a", #{font: "No Such Font 4711"})"#,
            "no installed font",
        ),
        (
            r#"text("a", #{font: "missing.ttf"})"#,
            "cannot read the font",
        ),
        (r#"text("a", #{sizes: 3})"#, "no option \"sizes\""),
        (
            r#"text("a", #{halign: "middle"})"#,
            "halign is left, center or right",
        ),
        (r#"text("a", #{size: -1})"#, "size must be positive"),
    ];
    for (expression, message) in cases {
        let reply = server.load(&format!("let a = 1;\ndraw({expression});\n"), &script);
        let d = diagnostic(&reply);
        assert_eq!(d["line"], 2, "{reply}");
        assert!(
            d["message"].as_str().unwrap_or("").contains(message),
            "{expression}: {reply}"
        );
    }
}

// --- svg ---

const SQUARE: &str = r#"<svg xmlns="http://www.w3.org/2000/svg" width="20mm" height="10mm" viewBox="0 0 20 10">
  <rect x="2" y="1" width="10" height="5"/>
</svg>
"#;

/// The SVG's millimetres stay millimetres, its y turned to run up from
/// the document's bottom; without units, 96 pixels make an inch.
#[test]
fn svg_imports_in_millimetres() {
    let dir = scratch("svg");
    std::fs::write(dir.join("square.svg"), SQUARE).expect("writable");
    std::fs::write(
        dir.join("pixels.svg"),
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96">
  <g transform="translate(48 0)"><rect width="48" height="48"/></g>
</svg>
"#,
    )
    .expect("writable");
    let script = dir.join("svg.keycap");
    let mut server = Server::start();
    // The rectangle runs from 2 to 12 in x and, flipped, 4 to 9 in y.
    assert_field(
        &mut server,
        &script,
        r#"svg("square.svg")"#,
        &[
            ([1.0, 6.5], 1.0),
            ([13.0, 6.5], 1.0),
            ([7.0, 3.0], 1.0),
            ([7.0, 10.0], 1.0),
            ([7.0, 6.5], -2.5),
            ([15.0, 13.0], 5.0),
        ],
        1e-3,
    );
    assert_field(
        &mut server,
        &script,
        r#"svg("square.svg", #{center: true})"#,
        &[([-6.0, 0.0], 1.0), ([0.0, 0.0], -2.5)],
        1e-3,
    );
    // Half an inch square, in the top right quarter of an inch square
    assert_field(
        &mut server,
        &script,
        r#"svg("pixels.svg")"#,
        &[([11.7, 19.05], 1.0), ([19.05, 19.05], -6.35)],
        1e-3,
    );
}

/// Each path keeps its fill rule; closed subpaths fill whatever their
/// paint, open ones import as their stroke.
#[test]
fn svg_fill_rules_and_strokes() {
    let dir = scratch("svg-rules");
    let squares = "M 0 0 H 30 V 30 H 0 Z M 10 10 H 20 V 20 H 10 Z";
    std::fs::write(
        dir.join("rules.svg"),
        format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" viewBox="0 0 100 100">
  <path id="evenodd" fill-rule="evenodd" d="{squares}"/>
  <path id="nonzero" transform="translate(40 0)" d="{squares}"/>
  <path id="outline" transform="translate(0 40)" style="fill:none;stroke:#000;stroke-width:0.2" d="{squares}"/>
  <path id="line" style="fill:none;stroke:#000;stroke-width:2" d="M 40 50 L 60 50"/>
</svg>
"#
        ),
    )
    .expect("writable");
    let script = dir.join("svg.keycap");
    let mut server = Server::start();
    let id = |id: &str| format!(r#"svg("rules.svg", #{{id: "{id}"}})"#);
    // The centre of each pair of squares, y flipped from the 100 mm page
    assert_field(
        &mut server,
        &script,
        &id("evenodd"),
        &[([15.0, 85.0], 5.0)],
        1e-3,
    );
    assert_field(
        &mut server,
        &script,
        &id("nonzero"),
        &[([55.0, 85.0], -15.0)],
        1e-3,
    );
    assert_field(
        &mut server,
        &script,
        &id("outline"),
        &[([15.0, 45.0], 5.0)],
        1e-3,
    );
    // A 2 mm stroke with butt ends, SVG's default
    assert_field(
        &mut server,
        &script,
        &id("line"),
        &[
            ([50.0, 50.0], -1.0),
            ([50.0, 53.0], 2.0),
            ([62.0, 50.0], 2.0),
        ],
        1e-3,
    );
    let reply = server.load(&format!("draw({});\n", id("nope")), &script);
    assert!(
        diagnostic(&reply)["message"]
            .as_str()
            .unwrap_or("")
            .contains("no element with id \"nope\""),
        "{reply}"
    );
}

#[test]
fn a_missing_svg_errors_on_its_line() {
    let dir = scratch("svg-missing");
    let script = dir.join("svg.keycap");
    let mut server = Server::start();
    let reply = server.load("let a = 1;\n\nlet b = svg(\"gone.svg\");\n", &script);
    assert_eq!(reply["loaded"], false);
    let d = diagnostic(&reply);
    assert_eq!(
        (d["line"].as_u64(), d["column"].as_u64()),
        (Some(3), Some(9)),
        "{reply}"
    );
    assert!(
        d["message"].as_str().unwrap_or("").contains("cannot read"),
        "{reply}"
    );
}

/// A load lists the files the script read, through imports too and when
/// it fails, so that the preview can reload when they change.
#[test]
fn loads_list_the_files_read() {
    let dir = scratch("files");
    std::fs::create_dir_all(dir.join("parts")).expect("writable");
    std::fs::write(dir.join("parts/square.svg"), SQUARE).expect("writable");
    std::fs::write(
        dir.join("parts/plate.keycap"),
        "fn plate() {\n    svg(\"square.svg\")\n}\n",
    )
    .expect("writable");
    let script = dir.join("main.keycap");
    let mut server = Server::start();
    let canonical = |p: &str| {
        std::fs::canonicalize(dir.join(p))
            .expect("exists")
            .to_string_lossy()
            .into_owned()
    };
    let reply = server.load(
        "import \"parts/plate\" as parts;\ndraw(parts::plate());\n",
        &script,
    );
    assert_eq!(reply["loaded"], true, "{reply}");
    assert_eq!(
        reply["files"],
        json!([
            canonical("parts/plate.keycap"),
            canonical("parts/square.svg")
        ])
    );

    let reply = server.load(
        "import \"parts/plate\" as parts;\ndraw(parts::plate() + nope);\n",
        &script,
    );
    assert_eq!(reply["loaded"], false);
    assert_eq!(reply["files"].as_array().map(Vec::len), Some(2), "{reply}");
}

#[test]
fn docs_describe_text_and_svg() {
    let mut server = Server::start();
    let reply = server.request(json!({"op": "docs"}));
    for name in ["text", "svg"] {
        let function = reply["functions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|f| f["name"] == name)
            .cloned()
            .unwrap_or_default();
        assert_eq!(function["source"], "keycap", "{function}");
        assert_eq!(function["signatures"].as_array().map(Vec::len), Some(2));
        assert!(function["doc"].as_str().unwrap_or("").contains("OpenSCAD"));
    }
}
