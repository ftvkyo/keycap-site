// SPDX-License-Identifier: MPL-2.0

//! The threads that answer requests: the language thread, which loads,
//! evaluates, probes and starts exports in order, and the render thread,
//! whose frames are of the scene the loads before them made.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError, mpsc};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use fidget::context::Tree;
use fidget::eval::{Function, TracingEvaluator};
use fidget::jit::{JitFunction, JitShape};
use fidget::render::{CancelToken, ThreadPool};
use fidget::shape::{ShapeTape, ShapeTracingEval};
use rhai::Dynamic;
use serde_json::{Map, Value, json};

use crate::bounds::{self, Box3, Fitted};
use crate::camera::{self, View2, View3};
use crate::diagnostic::{Diagnostic, Location};
use crate::gpu::Gpu;
use crate::prefer;
use crate::protocol::{
    self, Axis, Backend, BoundsChoice, Eval, Export, Incoming, Interrupts, Op, Probe, Render,
    Replies, Request, Script, Slice,
};
use crate::render;
use crate::scene::{self, Orientation, Scene};
use crate::script::{self, Dialect, Engine, Run};
use crate::{contour, docs, drawing, mesh};

/// The largest image side, well past any screen.
const MAX_SIDE: u32 = 16384;

/// Octree depth for meshes when neither request nor script sets a
/// resolution: 256 cells across.
const DEFAULT_DEPTH: u8 = 8;

/// Grid cells across the longer side of a 2D export when neither request
/// nor script sets a resolution.
const DEFAULT_CELLS: f64 = 1024.0;

enum Reply {
    Done(Map<String, Value>),
    Failed(String),
    Cancelled,
    /// Sent later, by the export the request started
    Later,
}

impl Reply {
    fn fields(self) -> Option<Map<String, Value>> {
        match self {
            Reply::Done(map) => Some(map),
            Reply::Failed(error) => Some(Map::from_iter([("error".to_owned(), error.into())])),
            Reply::Cancelled => Some(Map::from_iter([("cancelled".to_owned(), true.into())])),
            Reply::Later => None,
        }
    }
}

/// Replies are built as `json!` objects.
impl From<Value> for Reply {
    fn from(value: Value) -> Self {
        match value {
            Value::Object(map) => Reply::Done(map),
            other => Reply::Failed(format!("not a reply: {other}")),
        }
    }
}

/// A frame rendered, before it is written
struct Rendered {
    pixels: Vec<render::Rgb>,
    backend: Backend,
    /// Why a frame asked of the GPU was rendered on the CPU
    fallback: Option<String>,
    scale: f64,
    frame: Frame,
    /// Whether no pixel shows the inside of a shape
    empty: bool,
}

/// The last frame, and the scene it shows
struct Shown {
    frame: Frame,
    scene: Arc<Scene>,
}

/// What a probe needs from the last frame.
enum Frame {
    View3 {
        view: View3,
        depth: Vec<u32>,
    },
    View2 {
        view: View2,
        width: u32,
        height: u32,
    },
}

type PointEval = <JitFunction as Function>::PointEval;

/// The drawn shapes compiled for point evaluation, kept between probes
struct Point {
    scene: u64,
    tapes: Vec<ShapeTape<<PointEval as TracingEvaluator>::Tape>>,
    eval: ShapeTracingEval<PointEval>,
}

/// What the language and render threads share
#[derive(Default)]
struct Shared {
    scene: Mutex<Option<Arc<Scene>>>,
    shown: Mutex<Option<Arc<Shown>>>,
}

/// The language thread's
struct Server {
    keycap: Engine,
    fidget: Engine,
    point: Option<Point>,
    interrupts: Interrupts,
    shared: Arc<Shared>,
    docs: HashMap<Dialect, Value>,
    replies: Replies,
    /// How many threads exports run on, or one per core
    threads: Option<usize>,
    /// The exports' threads, started with the first
    exporters: Option<Arc<ThreadPool>>,
    /// The exports that may still be running, each on a thread of its own
    exports: Vec<JoinHandle<()>>,
}

/// The render thread's
struct Renderer {
    gpu: Gpu,
    interrupts: Interrupts,
    shared: Arc<Shared>,
}

/// Serves requests until stdin closes; exports run on `threads` threads,
/// or one per core, and a GPU submission runs for at most about `budget`.
pub fn run(prelude: Option<&Path>, threads: Option<usize>, budget: Duration) {
    // A thread reads stdin, so that a newer render or export cancels an
    // older one at once.  Renders go to a thread of their own, so that a
    // load, completion or probe never waits for a frame; the language
    // thread answers the rest in order, so that each sees the loads before
    // it, and a frame waits only for those loads.  Exports run beside both,
    // each on a thread of its own.
    let (requests, queue) = mpsc::channel();
    let (renders, render_queue) = mpsc::channel();
    let interrupts = Interrupts::default();
    let reader = interrupts.clone();
    std::thread::spawn(move || protocol::read_requests(requests, renders, reader));

    let replies = Replies::new();
    let shared = Arc::new(Shared::default());
    let renderer = std::thread::spawn({
        let (interrupts, shared, replies) = (interrupts.clone(), shared.clone(), replies.clone());
        move || {
            let mut renderer = Renderer {
                gpu: Gpu::new(budget),
                interrupts,
                shared,
            };
            let served = catch_unwind(AssertUnwindSafe(|| {
                for (id, request) in render_queue {
                    let reply = renderer.render(*request).unwrap_or_else(Reply::Failed);
                    if let Some(fields) = reply.fields()
                        && !replies.send(id.into(), fields)
                    {
                        break;
                    }
                }
            }));
            // A panic stops the server, as one on the language thread does,
            // rather than leave renders unanswered.
            if served.is_err() {
                std::process::exit(101);
            }
        }
    });

    let keycap = Engine::new(prelude);
    let mut server = Server {
        fidget: Engine::fidget(&keycap),
        keycap,
        point: None,
        interrupts,
        shared,
        docs: HashMap::new(),
        replies: replies.clone(),
        threads,
        exporters: None,
        exports: Vec::new(),
    };
    for incoming in queue {
        let (id, reply) = match incoming {
            Incoming::Malformed { id, error } => (id, Reply::Failed(error)),
            Incoming::Request(Request { id, op }) => (id.into(), server.handle(id, op)),
        };
        if let Some(fields) = reply.fields()
            && !replies.send(id, fields)
        {
            // No one reads the replies, of frames and exports either.
            return;
        }
    }
    let _ = renderer.join();
    // An export still running answers before the server exits.
    for export in server.exports {
        let _ = export.join();
    }
}

fn ms(start: Instant) -> f64 {
    (start.elapsed().as_secs_f64() * 1e4).round() / 10.0
}

impl Server {
    fn handle(&mut self, id: i64, op: Op) -> Reply {
        let reply = match op {
            Op::Load(script) => {
                let reply = self.load(script);
                self.interrupts.load_done();
                Ok(reply)
            }
            Op::Render(_) => Err("renders are answered on a thread of their own".into()),
            Op::Probe(probe) => self.probe(probe),
            Op::Mesh(request) => {
                let generation = request.export.generation;
                let reply = self.mesh(id, request);
                self.unless_started(generation, reply)
            }
            Op::Trace(request) => {
                let generation = request.export.generation;
                let reply = self.trace(id, request);
                self.unless_started(generation, reply)
            }
            Op::Cancel(cancel) => Ok(json!({ "stopped": cancel.stopped }).into()),
            Op::Eval(eval) => Ok(self.eval(eval)),
            Op::Docs(request) => Ok(self.docs(request.dialect)),
        };
        reply.unwrap_or_else(Reply::Failed)
    }

    /// `reply` to the export request of `generation`, which is done with
    /// unless the reply comes later, from the export it started.
    fn unless_started(
        &self,
        generation: u64,
        reply: Result<Reply, String>,
    ) -> Result<Reply, String> {
        if !matches!(reply, Ok(Reply::Later)) {
            self.interrupts.export_done(generation);
        }
        reply
    }

    fn engine(&self, dialect: Dialect) -> &Engine {
        match dialect {
            Dialect::Fidget => &self.fidget,
            Dialect::Keycap => &self.keycap,
        }
    }

    fn engine_mut(&mut self, dialect: Dialect) -> &mut Engine {
        match dialect {
            Dialect::Fidget => &mut self.fidget,
            Dialect::Keycap => &mut self.keycap,
        }
    }

    fn scene(&self) -> Result<Arc<Scene>, String> {
        self.shared
            .scene()
            .ok_or_else(|| "no script is loaded".to_owned())
    }

    // --- load ---

    fn load(&mut self, script: Script) -> Reply {
        let start = Instant::now();
        let engine = self.engine_mut(script.dialect);
        let (run, result) = engine.run(&script.source, script.path.as_deref(), &script.overrides);
        let mut diagnostics: Vec<Diagnostic> = vec![];
        let output = output(&run);
        let files = run.files.clone();
        let functions = docs::script_functions(&run.functions);
        let loaded = match result {
            Err(error) => {
                diagnostics.push(error);
                None
            }
            Ok(_) => match Scene::new(run.drawn, run.bounds, run.resolution) {
                Ok(scene) => Some(scene),
                Err(error) => {
                    diagnostics.push(Diagnostic::error(
                        Location::start(),
                        format!("cannot compile the shapes: {error}"),
                    ));
                    None
                }
            },
        };
        diagnostics.extend(engine.prelude().problems.iter().cloned());
        if engine.dialect() == Dialect::Keycap {
            diagnostics.extend(prefer::notes(engine.rhai(), &script.source));
        }
        if engine.dialect() == Dialect::Fidget && run.operations > script::FIDGET_OPERATIONS {
            diagnostics.push(Diagnostic::warning(
                Location::start(),
                format!(
                    "the script ran {} operations; fidget's own tools stop at {} operations",
                    run.operations,
                    script::FIDGET_OPERATIONS
                ),
            ));
        }
        let Some(scene) = loaded else {
            return json!({
                "loaded": false,
                "functions": functions,
                "output": output,
                "files": files,
                "diagnostics": diagnostics,
                "ms": ms(start),
            })
            .into();
        };

        if scene.drawn.is_empty() {
            diagnostics.push(Diagnostic::warning(
                Location::start(),
                "the script draws nothing; draw(shape) shows a shape".into(),
            ));
        }
        let loose = loose(&scene);
        diagnostics.extend(clipping(&scene));
        diagnostics.extend(extent(&scene, loose));

        let shapes: Vec<Value> = scene
            .drawn
            .iter()
            .map(|d| {
                let mut shape = serde_json::to_value(&d.at).unwrap_or_default();
                shape["color"] = json!(d.color);
                shape
            })
            .collect();
        let reply = json!({
            "loaded": true,
            "shapes": shapes,
            "bounds": {
                "script": scene.bounds,
                "fitted": scene.fitted.as_ref().map(Fitted::padded),
                "loose": loose,
            },
            "resolution": scene.resolution,
            "functions": functions,
            "output": output,
            "files": files,
            "diagnostics": diagnostics,
            "ms": ms(start),
        });
        self.interrupts.scene_replaced(script.renders_before);
        *lock(&self.shared.scene) = Some(Arc::new(scene));
        reply.into()
    }

    // --- probe ---

    fn probe(&mut self, probe: Probe) -> Result<Reply, String> {
        let shown = lock(&self.shared.shown).clone();
        let shown = shown.ok_or("nothing is rendered yet")?;
        let frame = &shown.frame;
        // The pixel under (x, y), whose centre the frame shows
        let (x, y) = (probe.x.floor(), probe.y.floor());
        let position = match frame {
            Frame::View2 {
                view,
                width,
                height,
            } => Some(view.point(x, y, *width, *height)),
            Frame::View3 { view, depth } => {
                let inside =
                    x >= 0.0 && y >= 0.0 && x < f64::from(view.width) && y < f64::from(view.height);
                let d = if inside {
                    depth
                        .get(y as usize * view.width as usize + x as usize)
                        .copied()
                } else {
                    None
                };
                // The surface lies between the last empty voxel and the
                // first full one.
                d.filter(|&d| d > 0)
                    .map(|d| view.point(x, y, f64::from(d) - 0.5))
            }
        };
        let Some(position) = position else {
            return Ok(json!({ "position": null, "shape": null }).into());
        };
        let (value, shape) = self.nearest_shape(&shown.scene, position)?.unzip();
        Ok(json!({ "position": position, "value": value, "shape": shape }).into())
    }

    /// The union's value at `p` and the shape it comes from, the one whose
    /// field is lowest there: the shape containing `p`, or nearest it.
    fn nearest_shape(
        &mut self,
        scene: &Scene,
        p: [f64; 3],
    ) -> Result<Option<(f64, usize)>, String> {
        if self
            .point
            .as_ref()
            .is_none_or(|point| point.scene != scene.id)
        {
            let compiled = scene.compiled(Orientation::Slice(Axis::Z))?;
            let shapes = compiled.each()?;
            self.point = Some(Point {
                scene: scene.id,
                tapes: shapes
                    .iter()
                    .map(|shape| shape.point_tape(Default::default()))
                    .collect(),
                eval: JitShape::new_point_eval(),
            });
        }
        let Some(point) = self.point.as_mut() else {
            return Ok(None);
        };
        let [x, y, z] = p.map(|v| v as f32);
        let values = point.tapes.iter().enumerate().filter_map(|(index, tape)| {
            let (value, _) = point.eval.eval(tape, x, y, z).ok()?;
            value.is_finite().then_some((f64::from(value), index))
        });
        Ok(values.min_by(|a, b| a.0.total_cmp(&b.0)))
    }

    // --- exports ---

    /// Starts `work`, the request's `export`, on a thread of its own, which
    /// reports its stages, `tolerance` with simplifying, and then replies
    /// with what `work` returns, or as cancelled for `None`, while the
    /// language thread goes on with other requests.
    fn start_export(
        &mut self,
        id: i64,
        export: Export,
        tolerance: f64,
        work: impl FnOnce(&mesh::Job) -> Result<Option<Value>, String> + Send + 'static,
    ) -> Result<Reply, String> {
        let threads = match &self.exporters {
            Some(threads) => threads.clone(),
            None => self
                .exporters
                .insert(Arc::new(mesh::pool(self.threads)?))
                .clone(),
        };
        let (replies, interrupts) = (self.replies.clone(), self.interrupts.clone());
        self.exports.retain(|export| !export.is_finished());
        self.exports.push(std::thread::spawn(move || {
            let progress = |stage: mesh::Stage| {
                let mut fields = Map::from_iter([("progress".to_owned(), stage.name().into())]);
                if let mesh::Stage::Simplifying = stage {
                    fields.insert("tolerance".to_owned(), tolerance.into());
                }
                replies.send(id.into(), fields);
            };
            let job = mesh::Job {
                threads: &threads,
                cancel: &export.cancel,
                progress: &progress,
            };
            let reply = match catch_unwind(AssertUnwindSafe(|| work(&job))) {
                Ok(Ok(Some(reply))) => reply.into(),
                Ok(Ok(None)) => Reply::Cancelled,
                Ok(Err(error)) => Reply::Failed(error),
                Err(_) => Reply::Failed("exporting failed inside fidget".into()),
            };
            interrupts.export_done(export.generation);
            if let Some(fields) = reply.fields() {
                replies.send(id.into(), fields);
            }
        }));
        Ok(Reply::Later)
    }

    // --- mesh ---

    fn mesh(&mut self, id: i64, request: protocol::Mesh) -> Result<Reply, String> {
        let start = Instant::now();
        let protocol::Mesh {
            output,
            bounds,
            resolution,
            tolerance,
            export,
        } = request;
        if export.cancel.is_cancelled() {
            return Ok(Reply::Cancelled);
        }
        let scene = self.scene()?;
        if scene.drawn.is_empty() {
            return Err("the script draws nothing".into());
        }
        let (region, used) = scene.region(bounds);
        let depth = match resolution.or(scene.resolution) {
            Some(resolution) => mesh::depth(&region, resolution)?,
            None => DEFAULT_DEPTH,
        };
        let tolerance = match tolerance {
            Some(tolerance) if tolerance.is_finite() && tolerance >= 0.0 => tolerance,
            Some(tolerance) => {
                return Err(format!("tolerance must be 0 or more, not {tolerance}"));
            }
            None => mesh::default_tolerance(&region, depth),
        };
        let shape = scene.compiled(Orientation::Solid(used))?.union.clone();
        self.start_export(id, export, tolerance, move |job| {
            let exported = mesh::mesh(&shape, &region, depth, tolerance, &output, job)?;
            Ok(exported.map(|exported| {
                json!({
                    "triangles": exported.triangles,
                    "meshed": exported.meshed,
                    "tolerance": tolerance,
                    "bounds": used,
                    "ms": ms(start),
                })
            }))
        })
    }

    // --- trace ---

    fn trace(&mut self, id: i64, request: protocol::Trace) -> Result<Reply, String> {
        let start = Instant::now();
        let protocol::Trace {
            output,
            format,
            bounds,
            slice,
            resolution,
            tolerance,
            kerf,
            export,
        } = request;
        if export.cancel.is_cancelled() {
            return Ok(Reply::Cancelled);
        }
        let scene = self.scene()?;
        if scene.drawn.is_empty() {
            return Err("the script draws nothing".into());
        }
        if !(kerf.is_finite() && kerf >= 0.0) {
            return Err(format!("kerf must be 0 or more, not {kerf}"));
        }
        let (region, used) = scene.region(bounds);
        let slice = slice.unwrap_or(Slice {
            axis: Axis::Z,
            offset: region.center()[2],
            tilt: [0.0, 0.0],
        });
        if !slice.is_finite() {
            return Err("the slice needs a finite offset and tilt".into());
        }
        let [i, j] = camera::plane_axes(slice.axis);
        let center = region.center();
        let size = camera::plane_size(&region, &slice);
        let lower = [center[i] - size[0] / 2.0, center[j] - size[1] / 2.0];
        let upper = [center[i] + size[0] / 2.0, center[j] + size[1] / 2.0];
        let cell = match resolution.or(scene.resolution) {
            Some(resolution) if resolution.is_finite() && resolution > 0.0 => 1.0 / resolution,
            Some(resolution) => {
                return Err(format!("resolution must be positive, not {resolution}"));
            }
            None => (upper[0] - lower[0]).max(upper[1] - lower[1]) / DEFAULT_CELLS,
        };
        let grid = contour::Grid::new(lower, upper, cell)?;
        let tolerance = match tolerance {
            Some(tolerance) if tolerance.is_finite() && tolerance >= 0.0 => tolerance,
            Some(tolerance) => {
                return Err(format!("tolerance must be 0 or more, not {tolerance}"));
            }
            None => cell / 10.0,
        };
        let shapes = drawing::shapes(&scene, slice, &region, lower, upper, kerf)?;
        self.start_export(id, export, tolerance, move |job| {
            let exported = drawing::export(
                &shapes,
                &grid,
                slice.offset,
                tolerance,
                format,
                &output,
                job,
            )?;
            Ok(exported.map(|exported| {
                json!({
                    "outlines": exported.outlines,
                    "lines": exported.lines,
                    "arcs": exported.arcs,
                    "tolerance": tolerance,
                    "bounds": used,
                    "slice": slice,
                    "ms": ms(start),
                })
            }))
        })
    }

    // --- eval ---

    fn eval(&mut self, request: Eval) -> Reply {
        // The expression runs as the script's last statement, so that it
        // sees the script's variables, functions and imports.
        let script_lines = request.source.split('\n').count();
        let combined = format!("{}\n;\n{}", request.source, request.expression);
        let engine = self.engine_mut(request.dialect);
        let (run, result) = engine.run(&combined, request.path.as_deref(), &request.overrides);
        let output = output(&run);
        match result {
            Ok(value) => json!({ "value": describe(value), "output": output }).into(),
            Err(mut diagnostic) => {
                let relocate = |at: &mut Location| {
                    if at.file.is_none() && at.line > script_lines + 1 {
                        at.line -= script_lines + 1;
                    }
                };
                relocate(&mut diagnostic.at);
                for frame in &mut diagnostic.trace {
                    relocate(&mut frame.at);
                }
                json!({ "diagnostics": [diagnostic], "output": output }).into()
            }
        }
    }

    // --- docs ---

    fn docs(&mut self, dialect: Dialect) -> Reply {
        if !self.docs.contains_key(&dialect) {
            let docs = docs::docs(self.engine(dialect));
            self.docs.insert(dialect, docs);
        }
        self.docs[&dialect].clone().into()
    }
}

impl Renderer {
    // --- render ---

    fn render(&mut self, request: Render) -> Result<Reply, String> {
        let Some(cancel) = self.interrupts.start_render(&request) else {
            return Ok(Reply::Cancelled);
        };
        let start = Instant::now();
        let (width, height) = (request.width, request.height);
        if !(1..=MAX_SIDE).contains(&width) || !(1..=MAX_SIDE).contains(&height) {
            return Err(format!("the image must be 1 to {MAX_SIDE} pixels a side"));
        }
        let camera = request.camera;
        let numbers = [
            camera.azimuth,
            camera.elevation,
            camera.zoom,
            camera.pan[0],
            camera.pan[1],
        ];
        if !numbers.iter().all(|n| n.is_finite()) || camera.zoom <= 0.0 {
            return Err("the camera needs finite numbers and a positive zoom".into());
        }
        if !request.slice.is_finite() {
            return Err("the slice needs a finite offset and tilt".into());
        }

        let scene = self.shared.scene().ok_or("no script is loaded")?;
        let gpu = &mut self.gpu;
        let (region, bounds) = scene.region(request.bounds);
        let rendered = if request.view.is_3d() {
            render3(&scene, gpu, &request, (&region, bounds), &cancel)?
        } else {
            render2(&scene, gpu, &request, &region, &cancel)?
        };
        // A frame finished after a newer request arrived is no use to it.
        let Some(rendered) = rendered.filter(|_| !cancel.is_cancelled()) else {
            return Ok(Reply::Cancelled);
        };
        render::write_ppm(&request.output, width, height, &rendered.pixels)?;
        *lock(&self.shared.shown) = Some(Arc::new(Shown {
            frame: rendered.frame,
            scene,
        }));
        let mut reply = json!({
            "backend": rendered.backend,
            "bounds": bounds,
            "ms": ms(start),
            "scale": rendered.scale,
            "empty": rendered.empty,
        });
        if let Some(fallback) = rendered.fallback {
            reply["fallback"] = fallback.into();
        }
        Ok(reply.into())
    }
}

impl Shared {
    fn scene(&self) -> Option<Arc<Scene>> {
        lock(&self.scene).clone()
    }
}

/// `mutex`'s value, which a panic elsewhere leaves as it was
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A 3D frame of `region`, the region of `bounds`, on the GPU when asked
/// and possible; `None` once cancelled.
fn render3(
    scene: &Scene,
    gpu: &mut Gpu,
    request: &Render,
    (region, bounds): (&Box3, BoundsChoice),
    cancel: &CancelToken,
) -> Result<Option<Rendered>, String> {
    let view = camera::view3(region, &request.camera, request.width, request.height);
    let (kind, background) = (request.view, request.background);
    let on_gpu = (request.backend == Backend::Gpu).then(|| {
        gpu.run(scene.id, |device| {
            device.render3(scene, bounds, &view, request, cancel)
        })
    });
    let (frame, backend, fallback) = match on_gpu {
        Some(Ok(frame)) => (frame, Backend::Gpu, None),
        other => (
            render::render3(scene, bounds, &view, kind, background, cancel)?,
            Backend::Cpu,
            other.and_then(Result::err),
        ),
    };
    let Some(frame) = frame else {
        return Ok(None);
    };
    Ok(Some(Rendered {
        pixels: frame.pixels,
        backend,
        fallback,
        scale: view.scale,
        empty: frame.depth.iter().all(|&d| d == 0),
        frame: Frame::View3 {
            view,
            depth: frame.depth,
        },
    }))
}

/// A 2D frame of `region`, on the GPU when asked and possible; `None` once
/// cancelled.
fn render2(
    scene: &Scene,
    gpu: &mut Gpu,
    request: &Render,
    region: &Box3,
    cancel: &CancelToken,
) -> Result<Option<Rendered>, String> {
    let (width, height, kind) = (request.width, request.height, request.view);
    let view = camera::view2(region, &request.camera, &request.slice, width, height);
    let on_gpu = (request.backend == Backend::Gpu).then(|| {
        gpu.run(scene.id, |device| {
            device.field2(scene, &view, kind, width, height)
        })
    });
    let (field, backend, fallback) = match on_gpu {
        Some(Ok(field)) => (Some(field), Backend::Gpu, None),
        other => (
            render::field2(scene, &view, kind, width, height, cancel)?,
            Backend::Cpu,
            other.and_then(Result::err),
        ),
    };
    let Some(field) = field else {
        return Ok(None);
    };
    Ok(Some(Rendered {
        pixels: render::colour2(scene, &field, &view, kind, width, height),
        backend,
        fallback,
        scale: view.scale,
        frame: Frame::View2 {
            view,
            width,
            height,
        },
        empty: !field.distance.iter().any(|p| p.inside()),
    }))
}

fn output(run: &Run) -> Vec<String> {
    let mut output = run.output.clone();
    if run.dropped > 0 {
        output.push(format!("... {} more lines", run.dropped));
    }
    output
}

/// Warnings for drawn shapes that reach out of the script's bounds.
fn clipping(scene: &Scene) -> Vec<Diagnostic> {
    let Some(region) = scene.bounds else {
        return vec![];
    };
    let Ok(compiled) = scene.compiled(Orientation::Slice(Axis::Z)) else {
        return vec![];
    };
    let Ok(each) = compiled.each() else {
        return vec![];
    };
    scene
        .drawn
        .iter()
        .zip(each)
        .filter_map(|(drawn, shape)| {
            let sides = bounds::sides_outside(shape, &bounds::fit(&drawn.tree, shape)?, &region);
            (!sides.is_empty()).then(|| {
                Diagnostic::warning(
                    drawn.at.clone(),
                    format!("shape extends past the bounds on {}", sides.join(", ")),
                )
            })
        })
        .collect()
}

/// Why the fitted bounds may be far looser than the shapes, or miss sides
/// they have.
fn loose(scene: &Scene) -> Option<&'static str> {
    scene.fitted?;
    let union = &scene.compiled(Orientation::Slice(Axis::Z)).ok()?.union;
    bounds::nan_far_out(union).then_some("the shapes' intervals are NaN")
}

/// A warning for shapes that are provably empty, or that the fitting finds
/// unbounded on every axis when the script sets no bounds, at the first
/// shape that is, with `loose`, why.
fn extent(scene: &Scene, loose: Option<&str>) -> Option<Diagnostic> {
    let first = scene.drawn.first()?.at.clone();
    let Some(fitted) = scene.fitted else {
        return Some(Diagnostic::warning(
            first,
            "the shapes are empty: nothing is inside them".into(),
        ));
    };
    if scene.bounds.is_some() || !fitted.unbounded() {
        return None;
    }
    let compiled = scene.compiled(Orientation::Slice(Axis::Z));
    let each = compiled
        .as_ref()
        .map_err(Clone::clone)
        .and_then(|c| c.each());
    let at = each.ok().and_then(|each| {
        let mut drawn = scene.drawn.iter().zip(each);
        drawn
            .find(|(d, shape)| bounds::fit(&d.tree, shape).is_some_and(|f| f.unbounded()))
            .map(|(d, _)| d.at.clone())
    });
    let message = match loose {
        Some(why) => format!("could not fit bounds: {why}; set bounds(...)"),
        None => "unbounded on every axis; set bounds(...)".into(),
    };
    Some(Diagnostic::warning(at.unwrap_or(first), message))
}

/// A value for the echo area: a tree as its value at the origin and the
/// bounds fitted to it, since its expression is unreadable, anything else
/// as a script would write it.
fn describe(value: Dynamic) -> String {
    let Some(tree) = value.clone().try_cast::<Tree>() else {
        return literal(&value);
    };
    let Ok(shape) = scene::jit(&tree) else {
        return "tree".into();
    };
    let at_origin = JitShape::new_point_eval()
        .eval(&shape.point_tape(Default::default()), 0.0, 0.0, 0.0)
        .map(|(v, _)| number(f64::from(v)))
        .unwrap_or_else(|_| "?".into());
    let extent = match bounds::fit(&tree, &shape) {
        None => "empty".to_owned(),
        Some(fitted) => (0..3)
            .map(|i| {
                let side = |v: Option<f64>| v.map_or("unbounded".to_owned(), number);
                let name = ["x", "y", "z"][i];
                format!(
                    "{name} {} to {}",
                    side(fitted.lower[i]),
                    side(fitted.upper[i])
                )
            })
            .collect::<Vec<_>>()
            .join(", "),
    };
    format!("tree: {at_origin} at the origin; {extent}")
}

pub fn number(v: f64) -> String {
    let text = format!("{v:.4}");
    match text.trim_end_matches('0').trim_end_matches('.') {
        // What rounds to 0 from below
        "-0" => "0".to_owned(),
        text => text.to_owned(),
    }
}

/// `value` as a script would write it, with trees inside it only named.
fn literal(value: &Dynamic) -> String {
    use fidget::shapes::types::{Vec2, Vec3, Vec4};
    let list = |items: Vec<String>| items.join(", ");
    if value.is::<Tree>() {
        "tree".into()
    } else if let Some(v) = value.clone().try_cast::<Vec2>() {
        format!("vec2({}, {})", v.x, v.y)
    } else if let Some(v) = value.clone().try_cast::<Vec3>() {
        format!("vec3({}, {}, {})", v.x, v.y, v.z)
    } else if let Some(v) = value.clone().try_cast::<Vec4>() {
        format!("vec4({}, {}, {}, {})", v.x, v.y, v.z, v.w)
    } else if let Ok(array) = value.clone().into_array() {
        format!("[{}]", list(array.iter().map(literal).collect()))
    } else if let Some(map) = value.clone().try_cast::<rhai::Map>() {
        format!(
            "#{{{}}}",
            list(
                map.iter()
                    .map(|(k, v)| format!("{k}: {}", literal(v)))
                    .collect()
            )
        )
    } else {
        format!("{value:?}")
    }
}
