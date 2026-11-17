// SPDX-License-Identifier: MPL-2.0

//! Requests as they arrive on stdin, the cancellation of stale renders and
//! of exports, and replies on stdout.

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

use fidget::render::CancelToken;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::script::{Dialect, Overrides};

// --- Requests ---

/// One line of stdin: a request, or why it is not one.
pub enum Incoming {
    Request(Request),
    Malformed { id: Value, error: String },
}

pub struct Request {
    pub id: i64,
    pub op: Op,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Op {
    Load(Script),
    Render(Box<Render>),
    Probe(Probe),
    Mesh(Mesh),
    Trace(Trace),
    Cancel(Cancel),
    Eval(Eval),
    Docs(Docs),
}

#[derive(Deserialize)]
pub struct Script {
    pub source: String,
    pub path: Option<PathBuf>,
    #[serde(default)]
    pub dialect: Dialect,
    #[serde(default)]
    pub overrides: Overrides,
}

#[derive(Deserialize)]
pub struct Eval {
    pub source: String,
    pub path: Option<PathBuf>,
    pub expression: String,
    #[serde(default)]
    pub dialect: Dialect,
    #[serde(default)]
    pub overrides: Overrides,
}

#[derive(Deserialize)]
pub struct Docs {
    #[serde(default)]
    pub dialect: Dialect,
}

#[derive(Deserialize)]
pub struct Render {
    pub output: PathBuf,
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    pub view: View,
    #[serde(default)]
    pub bounds: BoundsChoice,
    #[serde(default)]
    pub backend: Backend,
    #[serde(default)]
    pub reproducible: bool,
    #[serde(default)]
    pub camera: Camera,
    #[serde(default)]
    pub slice: Slice,
    #[serde(default = "default_background")]
    pub background: [f32; 3],
    /// Set by the reader: renders are numbered so a newer one can tell an
    /// older one it is stale.
    #[serde(skip)]
    pub generation: u64,
}

fn default_background() -> [f32; 3] {
    [0.2, 0.2, 0.2]
}

#[derive(Deserialize)]
pub struct Probe {
    pub x: f64,
    pub y: f64,
}

#[derive(Deserialize)]
pub struct Mesh {
    pub output: PathBuf,
    #[serde(default)]
    pub bounds: BoundsChoice,
    pub resolution: Option<f64>,
    pub tolerance: Option<f64>,
    /// Set by the reader, so that a `cancel` reaches the export even while
    /// it waits behind other requests.
    #[serde(skip)]
    pub export: Export,
}

#[derive(Deserialize)]
pub struct Trace {
    pub output: PathBuf,
    pub format: Format,
    #[serde(default)]
    pub bounds: BoundsChoice,
    /// The plane to trace on; across Z through the middle of the region
    /// when not given
    pub slice: Option<Slice>,
    pub resolution: Option<f64>,
    pub tolerance: Option<f64>,
    /// The width the laser burns away, half of which the shapes to cut
    /// grow by
    #[serde(default)]
    pub kerf: f64,
    /// As `Mesh`'s
    #[serde(skip)]
    pub export: Export,
}

#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    Svg,
    Dxf,
}

#[derive(Deserialize)]
pub struct Cancel {
    /// Set by the reader: whether an export was waiting or running.
    #[serde(skip)]
    pub stopped: bool,
}

#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Default, Debug)]
#[serde(rename_all = "lowercase")]
pub enum View {
    #[default]
    Shaded,
    Heightmap,
    Sdf,
    Mono,
}

impl View {
    pub fn is_3d(self) -> bool {
        matches!(self, View::Shaded | View::Heightmap)
    }
}

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Default, Debug)]
#[serde(rename_all = "lowercase")]
pub enum BoundsChoice {
    #[default]
    Script,
    Fitted,
}

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Default, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    #[default]
    Gpu,
    Cpu,
}

#[derive(Deserialize, Clone, Copy, Debug)]
#[serde(default)]
pub struct Camera {
    pub azimuth: f64,
    pub elevation: f64,
    pub zoom: f64,
    pub pan: [f64; 2],
    pub orthographic: bool,
}

impl Default for Camera {
    fn default() -> Self {
        Camera {
            azimuth: -45.0,
            elevation: 30.0,
            zoom: 1.0,
            pan: [0.0, 0.0],
            orthographic: true,
        }
    }
}

#[derive(Deserialize, Serialize, Clone, Copy, Debug, Default)]
#[serde(default)]
pub struct Slice {
    pub axis: Axis,
    pub offset: f64,
    /// Degrees the plane turns about the image's right, then its up
    #[serde(skip_serializing_if = "is_level")]
    pub tilt: [f64; 2],
}

fn is_level(tilt: &[f64; 2]) -> bool {
    *tilt == [0.0, 0.0]
}

impl Slice {
    pub fn is_finite(&self) -> bool {
        self.offset.is_finite() && self.tilt.iter().all(|a| a.is_finite())
    }
}

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash, Default, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Axis {
    X,
    Y,
    #[default]
    Z,
}

impl Axis {
    pub fn index(self) -> usize {
        match self {
            Axis::X => 0,
            Axis::Y => 1,
            Axis::Z => 2,
        }
    }
}

fn parse(line: &str) -> Incoming {
    let value: Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            return Incoming::Malformed {
                id: Value::Null,
                error: format!("bad JSON: {error}"),
            };
        }
    };
    let Some(id) = value.get("id").and_then(Value::as_i64) else {
        return Incoming::Malformed {
            id: value.get("id").cloned().unwrap_or(Value::Null),
            error: "the request has no integer id".into(),
        };
    };
    match Op::deserialize(&value) {
        Ok(op) => Incoming::Request(Request { id, op }),
        Err(error) => Incoming::Malformed {
            id: id.into(),
            error: format!("bad request: {error}"),
        },
    }
}

// --- Cancellation ---

/// What the reader tells the worker out of band: that a render went stale,
/// or that an export is cancelled.
#[derive(Clone, Default)]
pub struct Interrupts {
    renders: Arc<Mutex<Renders>>,
    exports: Arc<Mutex<Exports>>,
}

#[derive(Default)]
struct Renders {
    /// The generation of the newest render request read so far
    latest: u64,
    /// The token of the render in progress
    running: CancelToken,
}

#[derive(Default)]
struct Exports {
    /// The generation of the newest export request read so far
    latest: u64,
    /// Its token, until it is done
    pending: Option<CancelToken>,
}

/// An export's generation and cancellation token.
#[derive(Default)]
pub struct Export {
    pub generation: u64,
    pub cancel: CancelToken,
}

impl Interrupts {
    /// Called by the reader for each export: cancels the one waiting or
    /// running, since one runs at a time.
    fn new_export(&self) -> Export {
        let mut exports = self.exports.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(older) = exports.pending.take() {
            older.cancel();
        }
        exports.latest += 1;
        let cancel = CancelToken::new();
        exports.pending = Some(cancel.clone());
        Export {
            generation: exports.latest,
            cancel,
        }
    }

    /// Called by the reader for a `cancel`: whether an export was waiting or
    /// running to cancel.
    fn cancel_export(&self) -> bool {
        let mut exports = self.exports.lock().unwrap_or_else(PoisonError::into_inner);
        exports
            .pending
            .take()
            .inspect(CancelToken::cancel)
            .is_some()
    }

    /// Called once the export of `generation` is done, one way or another.
    pub fn export_done(&self, generation: u64) {
        let mut exports = self.exports.lock().unwrap_or_else(PoisonError::into_inner);
        if exports.latest == generation {
            exports.pending = None;
        }
    }

    /// Called by the reader for each render: cancels whatever render is
    /// waiting or running, and returns the new one's generation.
    fn supersede(&self) -> u64 {
        let mut renders = self.renders.lock().unwrap_or_else(PoisonError::into_inner);
        renders.latest += 1;
        renders.running.cancel();
        renders.latest
    }

    /// Called by the worker before a render: its cancellation token, or
    /// `None` when a newer render already arrived.
    pub fn start_render(&self, generation: u64) -> Option<CancelToken> {
        let mut renders = self.renders.lock().unwrap_or_else(PoisonError::into_inner);
        if renders.latest != generation {
            return None;
        }
        renders.running = CancelToken::new();
        Some(renders.running.clone())
    }
}

/// Reads requests from stdin until it closes, numbering renders and
/// exports and cancelling them as requests arrive rather than when the
/// worker gets to them.  Requests read before stdin closed are still
/// answered.
pub fn read_requests(queue: Sender<Incoming>, interrupts: Interrupts) {
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let mut incoming = parse(&line);
        if let Incoming::Request(Request { op, .. }) = &mut incoming {
            match op {
                Op::Render(render) => render.generation = interrupts.supersede(),
                Op::Mesh(mesh) => mesh.export = interrupts.new_export(),
                Op::Trace(trace) => trace.export = interrupts.new_export(),
                Op::Cancel(cancel) => cancel.stopped = interrupts.cancel_export(),
                _ => {}
            }
        }
        if queue.send(incoming).is_err() {
            break;
        }
    }
}

// --- Replies ---

/// stdout, shared by the worker and the export running beside it, a line
/// at a time.
#[derive(Clone)]
pub struct Replies(Arc<Mutex<std::io::Stdout>>);

impl Replies {
    pub fn new() -> Self {
        Replies(Arc::new(Mutex::new(std::io::stdout())))
    }

    /// Writes `fields` and `id` as one line; false once stdout is closed.
    pub fn send(&self, id: Value, mut fields: Map<String, Value>) -> bool {
        fields.insert("id".to_owned(), id);
        let stdout = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        let mut stdout = stdout.lock();
        serde_json::to_writer(&mut stdout, &fields)
            .map_err(std::io::Error::from)
            .and_then(|()| stdout.write_all(b"\n"))
            .and_then(|()| stdout.flush())
            .is_ok()
    }
}
