// SPDX-License-Identifier: MPL-2.0

//! Meshes for export: the union of the shapes, cut to a region, meshed
//! with fidget's Manifold Dual Contouring on a pool of its own, the
//! vertices it leaves off the surface put back, and simplified to a
//! tolerance; written as STL here, and as 3MF by `printing`.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread::JoinHandle;
use std::time::Duration;

use fidget::jit::JitShape;
use fidget::mesh::{Mesh, Octree, Settings};
use fidget::render::{CancelToken, ThreadPool};

use crate::bounds::Box3;
use crate::{render, reproject, scene, simplify};

/// Cells of deeper octrees are too small for 32-bit floats to place.
const MAX_DEPTH: u8 = 16;

/// The share of the memory free when an export starts that it may take
const MEMORY_SHARE: f64 = 0.8;

/// The octree depth whose cells, spanning the cube around `region`, are no
/// larger than 1/`resolution`.
pub fn depth(region: &Box3, resolution: f64) -> Result<u8, String> {
    if !(resolution.is_finite() && resolution > 0.0) {
        return Err(format!("resolution must be positive, not {resolution}"));
    }
    let depth = (cube_side(region) * resolution).log2().ceil().max(1.0);
    if depth > f64::from(MAX_DEPTH) {
        return Err(format!(
            "resolution {resolution} needs an octree {depth} deep over this region; \
             at most {MAX_DEPTH} is supported"
        ));
    }
    Ok(depth as u8)
}

/// The tolerance an export simplifies its mesh to when the request sets
/// none: a tenth of the octree's cells.
pub fn default_tolerance(region: &Box3, depth: u8) -> f64 {
    cell(region, depth) / 10.0
}

/// The side of the octree's cells `depth` deep
pub fn cell(region: &Box3, depth: u8) -> f64 {
    cube_side(region) / 2f64.powi(i32::from(depth))
}

fn cube_side(region: &Box3) -> f64 {
    region.size().into_iter().fold(0.0, f64::max)
}

/// The stages of an export, as its progress reports them.
#[derive(Clone, Copy, Debug)]
pub enum Stage {
    /// Sampling the shape into an octree, most of the time
    Octree,
    /// Walking the octree's dual into triangles
    Triangles,
    /// Sampling a 2D export's shapes on a grid
    Grid,
    /// Tracing their outlines on the grid
    Contours,
    /// Tracing a stack of layers for printing
    Layers,
    /// Finding the slopes the layers' heights follow
    Heights,
    Simplifying,
    Writing,
}

impl Stage {
    pub fn name(self) -> &'static str {
        match self {
            Stage::Octree => "octree",
            Stage::Triangles => "triangles",
            Stage::Grid => "grid",
            Stage::Contours => "contours",
            Stage::Layers => "layers",
            Stage::Heights => "heights",
            Stage::Simplifying => "simplifying",
            Stage::Writing => "writing",
        }
    }
}

/// An export's means: the threads it runs on, its cancellation, and where
/// it reports each stage as it starts.
pub struct Job<'a> {
    pub threads: &'a ThreadPool,
    pub cancel: &'a CancelToken,
    pub progress: &'a dyn Fn(Stage),
}

/// What an export wrote.
pub struct Exported {
    pub triangles: usize,
    /// Triangles the mesher made, before simplifying
    pub meshed: usize,
}

/// Writes the STL of `shape`, the union cut to `region`, to `output`,
/// simplified to within `tolerance` of the mesher's surface unless that is
/// 0, or returns `None` once cancelled; a cancelled export leaves `output`
/// as it was.
pub fn mesh(
    shape: &JitShape,
    region: &Box3,
    depth: u8,
    tolerance: f64,
    output: &Path,
    job: &Job,
) -> Result<Option<Exported>, String> {
    let Some((mesh, meshed)) = build(shape, region, depth, tolerance, job)? else {
        return Ok(None);
    };
    (job.progress)(Stage::Writing);
    render::write_atomically(output, |file| mesh.write_stl(file))?;
    Ok(Some(Exported {
        triangles: mesh.triangles.len(),
        meshed,
    }))
}

/// The mesh of `shape`, the union cut to `region`, simplified to within
/// `tolerance` of the mesher's surface unless that is 0, and the triangles
/// it had before; `None` once cancelled.
pub fn build(
    shape: &JitShape,
    region: &Box3,
    depth: u8,
    tolerance: f64,
    job: &Job,
) -> Result<Option<(Mesh, usize)>, String> {
    let shape = scene::bound(shape.clone())?;

    // The octree spans the cube around the region, as [-1, 1]³ in its own
    // coordinates.
    let center = region.center();
    let half = cube_side(region) / 2.0;
    let world_to_model =
        nalgebra::Translation3::new(center[0] as f32, center[1] as f32, center[2] as f32)
            .to_homogeneous()
            * nalgebra::Scale3::new(half as f32, half as f32, half as f32).to_homogeneous();
    let settings = Settings {
        depth,
        world_to_model,
        threads: Some(job.threads),
        cancel: job.cancel.clone(),
    };
    let watchdog = Watchdog::start(job.cancel);
    let stopped = || match &watchdog {
        Some(watchdog) if watchdog.tripped() => Err(format!(
            "an octree {depth} deep takes more memory than is free; lower the resolution"
        )),
        _ => Ok(None),
    };

    (job.progress)(Stage::Octree);
    let Some(octree) = Octree::build(&shape, &settings) else {
        return stopped();
    };
    (job.progress)(Stage::Triangles);
    let mut mesh = octree.walk_dual();
    drop(octree);
    // An empty file would only replace a good one.
    if mesh.triangles.is_empty() {
        return Err("the mesh is empty: no surface within the bounds".into());
    }
    if job.cancel.is_cancelled() {
        return stopped();
    }

    // TODO: drop once fidget's octree merges its cells' Hermite data whole.
    reproject::reproject(&mut mesh, shape.shape(), cell(region, depth), job.threads);

    let meshed = mesh.triangles.len();
    if tolerance > 0.0 {
        (job.progress)(Stage::Simplifying);
        let Some(simplified) = simplify::simplify(&mesh, tolerance, job.threads, job.cancel) else {
            return stopped();
        };
        mesh = simplified;
    }

    Ok(Some((mesh, meshed)))
}

// --- Memory ---

/// Cancels an export that outgrows the memory free when it started, from a
/// thread of its own, until dropped; the octree depth that fits depends
/// on the shape's area more than on its size.
struct Watchdog {
    /// Dropped to stop the thread
    stop: Option<mpsc::Sender<()>>,
    thread: Option<JoinHandle<()>>,
    tripped: Arc<AtomicBool>,
}

impl Watchdog {
    /// `None` where the memory cannot be read
    fn start(cancel: &CancelToken) -> Option<Watchdog> {
        let limit = resident()? + free()? * MEMORY_SHARE;
        let (stop, stopped) = mpsc::channel();
        let tripped = Arc::new(AtomicBool::new(false));
        let (cancel, trip) = (cancel.clone(), tripped.clone());
        let thread = std::thread::spawn(move || {
            while let Err(RecvTimeoutError::Timeout) =
                stopped.recv_timeout(Duration::from_millis(100))
            {
                if resident().is_some_and(|r| r > limit) {
                    trip.store(true, Ordering::Relaxed);
                    cancel.cancel();
                    return;
                }
            }
        });
        Some(Watchdog {
            stop: Some(stop),
            thread: Some(thread),
            tripped,
        })
    }

    fn tripped(&self) -> bool {
        self.tripped.load(Ordering::Relaxed)
    }
}

impl Drop for Watchdog {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The memory the system can give, on Linux
fn free() -> Option<f64> {
    let info = std::fs::read_to_string("/proc/meminfo").ok()?;
    let line = info.lines().find(|l| l.starts_with("MemAvailable:"))?;
    let kb: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb * 1024.0)
}

/// The memory the process holds, on Linux
fn resident() -> Option<f64> {
    let statm = std::fs::read_to_string("/proc/self/statm").ok()?;
    let pages: f64 = statm.split_whitespace().nth(1)?.parse().ok()?;
    // SAFETY: sysconf only reads its argument.
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    Some(pages * page as f64)
}

// --- Threads ---

/// A pool of `threads` threads for exports, or one per core; on Linux
/// their priority is lowered below that of the preview's frames, which go
/// first while an export runs.
pub fn pool(threads: Option<usize>) -> Result<ThreadPool, String> {
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads.unwrap_or(0))
        .thread_name(|i| format!("keycap-export-{i}"))
        .start_handler(|_| lower_priority(10))
        .build()
        .map_err(|error| format!("cannot start the export's threads: {error}"))?;
    Ok(ThreadPool::Custom(pool))
}

/// Gives the calling thread the nice value `nice`, on Linux.
#[cfg(target_os = "linux")]
pub fn lower_priority(nice: i32) {
    // On Linux the nice value is per thread, and `who` 0 is the calling one.
    // SAFETY: setpriority only reads its arguments.
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, 0, nice);
    }
}

#[cfg(not(target_os = "linux"))]
pub fn lower_priority(_nice: i32) {}
