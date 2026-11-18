// SPDX-License-Identifier: MPL-2.0

//! Frames on the GPU through `fidget::wgpu`, once a hardware adapter is
//! found.  Pipelines, buffers and the shapes' tapes stay on the GPU from
//! frame to frame, so a camera move only uploads a matrix.
//!
//! Drivers reset a GPU whose work runs for about two seconds (amdgpu's
//! lockup timeout, Windows' TDR), and the device is lost with everything on
//! it.  Shapes whose intervals tell nothing, NaN for one, leave the GPU to
//! evaluate every voxel, which takes that long for a large frame.  So 3D
//! frames go in tiles, each its own submission, as large as the time tiles
//! took before allows within a budget well under that; shapes too slow for
//! even the smallest tile are left to the CPU.
//!
//! Every wait has a watchdog, as a GPU that hangs, or whose reset the
//! driver never reports, would block it forever.  A frame after which the
//! device is gone, which can look like an empty one, or that the watchdog
//! ends, is left to the CPU, and so is the scene's every later frame.  A
//! lost device is set up again for the next scene; a hung one is given up.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use fidget::context::{Context as Graph, Tree};
use fidget::raster::pixel::RawDistancePixel;
use fidget::raster::voxel::{self as cpu_voxel, GeometryPixel};
use fidget::render::{CancelToken, ImageSize, VoxelSize};
use fidget::vm::VmShape;
use fidget::wgpu::buf::ReadBuffer;
use fidget::wgpu::pixel::render::PixelBufferTag;
use fidget::wgpu::voxel::merge::MergeVoxelBufferTag;
use fidget::wgpu::voxel::ssao::SsaoBlurredBufferTag;
use fidget::wgpu::voxel::{PackedVoxel, merge, render, ssao};
use fidget::wgpu::{Context as _, RenderShape, pixel, wgpu};
use nalgebra::Translation3;

use crate::camera::{View2, View3};
use crate::protocol::{BoundsChoice, Render, View};
use crate::render::{self as cpu, Field, Frame3, merge_fields, shapes_differ};
use crate::scene::{Orientation, Scene};
use crate::{shade, ssao as seeded};

/// How long one submission may run unless `--gpu-budget` says otherwise:
/// a fifth of the shortest reset timeout, since tiles differ in cost.
pub const BUDGET: Duration = Duration::from_millis(400);

/// How long a wait lasts before the GPU counts as hung: far past any
/// tile's budget, and past the driver's own timeout, so that a GPU busy
/// with others' work is not taken for one
const WATCHDOG: Duration = Duration::from_secs(10);

/// The smallest tile side, which new shapes are first tried at
const MIN_TILE: u32 = 32;

pub struct Gpu {
    state: State,
    /// How long one submission may run
    budget: Duration,
    /// The scene whose frame the device was last lost on, which stays on
    /// the CPU rather than reset the GPU again
    lost_on: Option<u64>,
}

enum State {
    Untried,
    Unavailable(String),
    Ready(Box<Device>),
}

pub struct Device {
    gpu: fidget::wgpu::Gpu,
    voxel: (render::Context, render::Workspace),
    merge: (merge::Context, merge::Workspace),
    ssao: (ssao::Context, ssao::Workspace),
    pixel: (pixel::render::Context, pixel::render::Workspace),
    buffers3: Option<Buffers3>,
    buffers2: Option<Buffers2>,
    shapes: Option<Shapes>,
    /// How long one submission may run
    budget: Duration,
    /// Set when the device is lost
    lost: Arc<AtomicBool>,
    /// The last error wgpu reported outside a call that returns it
    error: Arc<Mutex<Option<String>>>,
    /// Set when the watchdog ends a wait: the device still has work
    hung: bool,
    /// Whether a tile has been rendered, which compiles the pipelines
    warm: bool,
}

/// One tile's buffers, a whole frame's when it is one tile
struct Buffers3 {
    size: VoxelSize,
    render: render::Buffers,
    merge: merge::Buffers,
    ssao: ssao::Buffers,
    voxels: ReadBuffer<MergeVoxelBufferTag>,
    occlusion: ReadBuffer<SsaoBlurredBufferTag>,
}

struct Buffers2 {
    size: ImageSize,
    pixel: pixel::render::Buffers,
    read: ReadBuffer<PixelBufferTag>,
}

/// One scene's shapes in one orientation, as tapes on the GPU
struct Shapes {
    scene: u64,
    orientation: Orientation,
    /// The union, or each shape when their colours differ
    tapes: Vec<RenderShape>,
    /// How long their tiles take, once measured
    cost: Option<Cost>,
}

impl Gpu {
    pub fn new(budget: Duration) -> Self {
        Gpu {
            state: State::Untried,
            budget,
            lost_on: None,
        }
    }

    /// Runs `f` on the device for a frame of `scene`, setting the device up
    /// on first use.  An error says why the frame is left to the CPU.
    pub fn run<T>(
        &mut self,
        scene: u64,
        f: impl FnOnce(&mut Device) -> Result<T, String>,
    ) -> Result<T, String> {
        if self.lost_on == Some(scene) {
            return Err("the GPU failed on this scene".into());
        }
        if let State::Untried = self.state {
            self.state = match Device::new(self.budget) {
                Ok(device) => State::Ready(Box::new(device)),
                Err(error) => {
                    eprintln!("keycap-server: no GPU, rendering on the CPU: {error}");
                    State::Unavailable("no GPU".into())
                }
            };
        }
        let device = match &mut self.state {
            State::Ready(device) => device,
            State::Unavailable(why) => return Err(why.clone()),
            State::Untried => unreachable!("the device was just tried"),
        };
        let done = catch_unwind(AssertUnwindSafe(|| {
            let done = f(device);
            (done, device.alive())
        }));
        let why = match done {
            Ok((Ok(done), Ok(()))) => return Ok(done),
            // Shapes the GPU cannot take; the device is as it was.
            Ok((Err(why), Ok(()))) => return Err(why),
            Ok((done, Err(lost))) => done.err().unwrap_or(lost),
            Err(_) => "wgpu panicked".into(),
        };
        eprintln!("keycap-server: the GPU failed, rendering on the CPU: {why}");
        self.lost_on = Some(scene);
        self.state = match std::mem::replace(&mut self.state, State::Untried) {
            // Dropping a device that still has work waits for it.
            State::Ready(device) if device.hung => {
                std::mem::forget(device);
                State::Unavailable("the GPU hung".into())
            }
            _ => State::Untried,
        };
        Err(why)
    }
}

fn vm(tree: &Tree) -> Result<VmShape, String> {
    let mut graph = Graph::new();
    let node = graph.import(tree);
    let shape = VmShape::new(&graph, node).map_err(|error| error.to_string())?;
    // The GPU's interpreter has no memory slots, so a tape that spills
    // registers into them evaluates to nonsense, and has hung the device.
    if shape.inner().data().slot_count() > usize::from(u8::MAX) {
        return Err("the shape needs more registers than the GPU has".into());
    }
    Ok(shape)
}

impl Device {
    fn new(budget: Duration) -> Result<Self, String> {
        let instance = wgpu::Instance::default();
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        }))
        .map_err(|error| error.to_string())?;
        let info = adapter.get_info();
        // fidget's JIT beats a GPU emulated on the CPU.
        if info.device_type == wgpu::DeviceType::Cpu {
            return Err(format!("{} is a software renderer", info.name));
        }
        let (device, queue) = pollster::block_on(adapter.request_device(&Default::default()))
            .map_err(|error| error.to_string())?;
        eprintln!(
            "keycap-server: rendering on {} ({:?})",
            info.name, info.backend
        );
        let lost = Arc::new(AtomicBool::new(false));
        device.set_device_lost_callback({
            let lost = lost.clone();
            move |_, _| lost.store(true, Ordering::Relaxed)
        });
        // Kept for `alive`, instead of wgpu's default of panicking
        let error = Arc::new(Mutex::new(None));
        device.on_uncaptured_error(Arc::new({
            let error = error.clone();
            move |e: wgpu::Error| {
                if let Ok(mut slot) = error.lock() {
                    *slot = Some(e.to_string());
                }
            }
        }));
        let gpu = fidget::wgpu::Gpu::new(device, queue);
        fn pair<C: fidget::wgpu::Context>(gpu: &fidget::wgpu::Gpu) -> (C, C::Workspace) {
            let context = C::new(gpu);
            let workspace = context.workspace();
            (context, workspace)
        }
        Ok(Device {
            voxel: pair(&gpu),
            merge: pair(&gpu),
            ssao: pair(&gpu),
            pixel: pair(&gpu),
            gpu,
            buffers3: None,
            buffers2: None,
            shapes: None,
            budget,
            lost,
            error,
            hung: false,
            warm: false,
        })
    }

    /// Waits for the work sent so far, or fails once the watchdog fires.
    fn wait(&mut self) -> Result<(), String> {
        let poll = wgpu::PollType::Wait {
            submission_index: None,
            timeout: Some(WATCHDOG.max(self.budget * 4)),
        };
        match self.gpu.device.poll(poll) {
            Ok(_) => Ok(()),
            Err(wgpu::PollError::Timeout) => {
                self.hung = true;
                Err("the GPU hung".into())
            }
            Err(error) => Err(error.to_string()),
        }
    }

    /// Whether the device survived the work sent to it.  A GPU reset
    /// mid-frame can leave the frame read back empty, without an error;
    /// the reset context refuses the next submission, which this sends.
    fn alive(&mut self) -> Result<(), String> {
        if self.hung {
            return Err("the GPU hung".into());
        }
        self.gpu.queue.submit([]);
        self.wait()?;
        if let Some(error) = self.error.lock().ok().and_then(|mut e| e.take()) {
            return Err(error);
        }
        if self.lost.load(Ordering::Relaxed) {
            return Err("the GPU's device was lost".into());
        }
        Ok(())
    }

    /// Uploads `scene`'s shapes in `orientation` unless they are there
    /// already.
    fn upload(&mut self, scene: &Scene, orientation: Orientation) -> Result<(), String> {
        if self
            .shapes
            .as_ref()
            .is_some_and(|s| s.scene == scene.id && s.orientation == orientation)
        {
            return Ok(());
        }
        self.shapes = None;
        let trees: Vec<Tree> = if shapes_differ(scene) {
            let trees = scene.drawn.iter().map(|d| &d.tree);
            trees.map(|tree| scene.orient(tree, orientation)).collect()
        } else {
            vec![scene.orient(&scene.union, orientation)]
        };
        let tapes = trees
            .iter()
            .map(|tree| {
                self.gpu
                    .build_render_shape(&vm(tree)?)
                    .map_err(|error| error.to_string())
            })
            .collect::<Result<Vec<_>, String>>()?;
        self.shapes = Some(Shapes {
            scene: scene.id,
            orientation,
            tapes,
            cost: None,
        });
        Ok(())
    }

    fn buffers3(&mut self, size: VoxelSize) -> Result<(), String> {
        if self.buffers3.as_ref().is_some_and(|b| b.size == size) {
            return Ok(());
        }
        // Frees the old buffers before the new ones take their memory.
        self.buffers3 = None;
        let merge = self.merge.0.buffers(size).map_err(|e| e.to_string())?;
        let ssao = self
            .ssao
            .0
            .buffers(size.into())
            .map_err(|e| e.to_string())?;
        self.buffers3 = Some(Buffers3 {
            size,
            render: self.voxel.0.buffers(size).map_err(|e| e.to_string())?,
            voxels: self.gpu.read_buffer_for(merge.output()),
            occlusion: self.gpu.read_buffer_for(ssao.blurred_occlusion()),
            merge,
            ssao,
        });
        Ok(())
    }

    /// Renders a 3D view of the shapes cut to the region of `bounds`, in
    /// `request`'s view and background, or `None` once `cancel` fires.  The
    /// GPU finds the surfaces, and their occlusion when the frame is one
    /// tile, unless it is to be `reproducible`; they are lit as the CPU's
    /// are.
    pub fn render3(
        &mut self,
        scene: &Scene,
        bounds: BoundsChoice,
        view: &View3,
        request: &Render,
        cancel: &CancelToken,
    ) -> Result<Option<Frame3>, String> {
        let (kind, reproducible) = (request.view, request.reproducible);
        let background = cpu::to_rgb(request.background);
        self.upload(scene, Orientation::Solid(bounds))?;
        let (width, height) = (view.width, view.height);
        let cost = match self.shapes.as_ref().and_then(|s| s.cost) {
            Some(cost) => cost,
            None => {
                let cost = self.measure(view)?;
                if let Some(shapes) = self.shapes.as_mut() {
                    shapes.cost = Some(cost);
                }
                cost
            }
        };
        let smallest = cost.of(volume([MIN_TILE; 2], view.depth));
        if smallest > self.budget.as_secs_f64() {
            return Err(format!(
                "too slow for the GPU: {:.0} ms a tile",
                smallest * 1e3
            ));
        }
        let side = cost.side(self.budget, view);
        let [w, h] = [side.min(width), side.min(height)];
        let mut slowest = Duration::ZERO;
        let voxels = if [w, h] == [width, height] {
            let (voxels, took) = self.tile3(view, [0, 0], [w, h])?;
            slowest = took;
            voxels
        } else {
            let mut voxels = vec![EMPTY; (width * height) as usize];
            for y in (0..height).step_by(h as usize) {
                for x in (0..width).step_by(w as usize) {
                    if cancel.is_cancelled() {
                        return Ok(None);
                    }
                    let (tile, took) = self.tile3(view, [x, y], [w, h])?;
                    slowest = slowest.max(took);
                    // Tiles at the right and bottom edges reach past them.
                    for row in 0..h.min(height - y) {
                        let from = (row * w) as usize;
                        let to = ((y + row) * width + x) as usize;
                        let n = w.min(width - x) as usize;
                        voxels[to..to + n].copy_from_slice(&tile[from..from + n]);
                    }
                }
            }
            voxels
        };
        if let Some(shapes) = self.shapes.as_mut() {
            shapes.cost = Some(cost.refit(slowest, volume([w, h], view.depth)));
        }

        let depth: Vec<u32> = voxels.iter().map(|v| v.z).collect();
        if kind == View::Heightmap {
            let pixels = cpu::heightmap(view, &depth, background);
            return Ok(Some(Frame3 { pixels, depth }));
        }
        // The frame is still in the merge buffer when it is one tile.
        let openness = if [w, h] == [width, height] && !reproducible {
            self.ssao3()?
        } else {
            seeded::openness(&geometry(&voxels, view))
        };
        let normals: Vec<[f32; 3]> = voxels.iter().map(normal).collect();
        let owner: Vec<usize> = voxels.iter().map(|v| usize::from(v.index)).collect();
        let geometry = shade::Geometry {
            width: width as usize,
            height: height as usize,
            depth: &depth,
            normals: &normals,
            owner: &owner,
            openness: &openness,
            z_scale: view.z_scale,
        };
        let pixels = shade::frame(&geometry, &scene.colors(), background);
        Ok(Some(Frame3 { pixels, depth }))
    }

    /// How long tiles of new shapes take: tiles from the middle of the
    /// frame, where the shapes likely are, each twice the last's side,
    /// while the next is expected to stay within the budget and is smaller
    /// than the frame, or until the whole frame would at the same time per
    /// voxel as the last.
    fn measure(&mut self, view: &View3) -> Result<Cost, String> {
        let (width, height) = (view.width, view.height);
        let budget = self.budget.as_secs_f64();
        let mut first = None;
        let mut side = MIN_TILE;
        let middle = |[w, h]: [u32; 2]| [(width - w) / 2, (height - h) / 2];
        if !self.warm {
            let size = [MIN_TILE.min(width), MIN_TILE.min(height)];
            self.tile3(view, middle(size), size)?;
            self.warm = true;
        }
        loop {
            let [w, h] = [side.min(width), side.min(height)];
            let took = self.tile3(view, middle([w, h]), [w, h])?.1;
            let tile = (volume([w, h], view.depth), took.as_secs_f64());
            let linear = Cost::linear(tile);
            if linear.of(volume([width, height], view.depth)) <= budget {
                return Ok(linear);
            }
            let (cost, limit) = match first {
                Some(first) => (Cost::through(first, tile), budget),
                // One tile cannot tell latency from time per voxel; taken
                // as all the latter, the next takes four times as long, so
                // twice the budget still keeps it well within the timeout.
                None => (linear, 2.0 * budget),
            };
            first.get_or_insert(tile);
            side *= 2;
            let next = volume([side.min(width), side.min(height)], view.depth);
            if side >= width.max(height) || cost.of(next) > limit {
                return Ok(cost);
            }
        }
    }

    /// The tile of `size` pixels at `origin` of `view`'s frame, merged, as
    /// one submission per shape, and the time it took; it stays in the
    /// merge buffer.
    fn tile3(
        &mut self,
        view: &View3,
        origin: [u32; 2],
        size: [u32; 2],
    ) -> Result<(Vec<PackedVoxel>, Duration), String> {
        let tile = VoxelSize::new(size[0], size[1], view.depth);
        self.buffers3(tile)?;
        let start = Instant::now();
        let (Some(b), Some(shapes)) = (self.buffers3.as_mut(), self.shapes.as_ref()) else {
            return Err("GPU buffers are missing".into());
        };
        // The tile's voxels to the frame's, then on as the frame's go
        let frame = VoxelSize::new(view.width, view.height, view.depth).screen_to_world();
        let shift = Translation3::new(origin[0] as f32, origin[1] as f32, 0.0).to_homogeneous();
        let to_tile = tile
            .screen_to_world()
            .try_inverse()
            .ok_or("the tile has no size")?;
        let settings = render::Settings {
            world_to_model: view.world_to_model * frame * shift * to_tile,
            ..Default::default()
        };
        let merging = merge::Settings {
            denoise: true,
            z_scale: view.z_scale,
        };
        b.merge.reset();
        for tape in &shapes.tapes {
            self.voxel
                .0
                .submit(tape, settings, &mut self.voxel.1, &mut b.render)
                .map_err(|e| e.to_string())?;
            self.merge
                .0
                .submit(&b.render, merging, &mut self.merge.1, &mut b.merge)
                .map_err(|e| e.to_string())?;
        }
        self.gpu
            .copy(b.merge.output(), &mut b.voxels)
            .map_err(|e| e.to_string())?;
        self.wait()?;
        let b = self.buffers3.as_mut().ok_or("GPU buffers are missing")?;
        let voxels = self.gpu.map(&mut b.voxels).to_vec();
        Ok((voxels, start.elapsed()))
    }

    /// The openness of the merged tile, which is a whole frame, from
    /// samples the device drew once: the same for every frame of a run,
    /// but not from one run to the next.
    fn ssao3(&mut self) -> Result<Vec<f32>, String> {
        let b = self.buffers3.as_mut().ok_or("GPU buffers are missing")?;
        self.ssao
            .0
            .submit(&b.merge, (), &mut self.ssao.1, &mut b.ssao)
            .map_err(|e| e.to_string())?;
        self.gpu
            .copy(b.ssao.blurred_occlusion(), &mut b.occlusion)
            .map_err(|e| e.to_string())?;
        self.wait()?;
        let b = self.buffers3.as_mut().ok_or("GPU buffers are missing")?;
        Ok(self.gpu.map(&mut b.occlusion).to_vec())
    }

    /// Renders a 2D slice's distances.
    pub fn field2(
        &mut self,
        scene: &Scene,
        view: &View2,
        kind: View,
        width: u32,
        height: u32,
    ) -> Result<Field, String> {
        let size = ImageSize::new(width, height);
        self.upload(scene, view.orientation())?;
        if self.buffers2.as_ref().is_none_or(|b| b.size != size) {
            self.buffers2 = None;
            let mut pixel = self.pixel.0.buffers(size).map_err(|e| e.to_string())?;
            let read = self.gpu.read_buffer_for(pixel.output());
            self.buffers2 = Some(Buffers2 { size, pixel, read });
        }
        let settings = pixel::render::Settings {
            world_to_model: view.world_to_model,
            pixel_perfect: kind == View::Sdf,
            z: view.offset as f32,
            ..Default::default()
        };
        let mut each: Vec<Vec<RawDistancePixel>> = vec![];
        let count = self.shapes.as_ref().map_or(0, |s| s.tapes.len());
        for i in 0..count {
            let (Some(b), Some(shapes)) = (self.buffers2.as_mut(), self.shapes.as_ref()) else {
                return Err("GPU buffers are missing".into());
            };
            self.pixel
                .0
                .submit(&shapes.tapes[i], settings, &mut self.pixel.1, &mut b.pixel)
                .map_err(|e| e.to_string())?;
            self.gpu
                .copy(b.pixel.output(), &mut b.read)
                .map_err(|e| e.to_string())?;
            self.wait()?;
            let b = self.buffers2.as_mut().ok_or("GPU buffers are missing")?;
            each.push(self.gpu.map_image(&mut b.read).image().take().0);
        }
        Ok(merge_fields(each))
    }
}

/// How long a tile takes on the GPU: a latency, the tape's longest way
/// through the stages of the render, then a time per voxel once the tiles
/// of a stage outnumber the GPU's cores.  Shapes whose intervals tell
/// nothing take a long time per voxel, as every voxel is evaluated.
///
/// Tiles are (voxels, seconds).  A small tile, such as a frame while the
/// camera is dragged, takes mostly latency, so the line is fitted through
/// two tiles of sizes far apart, and keeps its latency only until there
/// are two.
#[derive(Clone, Copy, Debug)]
struct Cost {
    /// Seconds
    latency: f64,
    /// Seconds
    per_voxel: f64,
    /// The tile the line was last fitted to
    last: (f64, f64),
    /// The latest tile at least twice or at most half the size of `last`
    other: Option<(f64, f64)>,
}

impl Cost {
    /// The line through the origin and one tile, all of whose time is
    /// taken as per voxel
    fn linear(tile: (f64, f64)) -> Cost {
        Cost {
            latency: 0.0,
            per_voxel: tile.1 / tile.0,
            last: tile,
            other: None,
        }
    }

    /// The line through two tiles of different sizes, `b` the later.
    fn through(a: (f64, f64), b: (f64, f64)) -> Cost {
        let (small, large) = if a.0 < b.0 { (a, b) } else { (b, a) };
        let per_voxel = ((large.1 - small.1) / (large.0 - small.0)).max(0.0);
        Cost {
            latency: (small.1 - per_voxel * small.0).max(0.0),
            per_voxel,
            last: b,
            other: Some(a),
        }
    }

    /// Seconds for a tile of `voxels`
    fn of(&self, voxels: f64) -> f64 {
        self.latency + self.per_voxel * voxels
    }

    /// Fitted again to a tile of `voxels` that took `took`, the slowest of
    /// a frame, so the densest.
    fn refit(&self, took: Duration, voxels: f64) -> Cost {
        let tile = (voxels, took.as_secs_f64());
        let apart = |other: &(f64, f64)| other.0 >= 2.0 * voxels || 2.0 * other.0 <= voxels;
        match Some(self.last).filter(apart).or(self.other.filter(apart)) {
            Some(other) => Cost::through(other, tile),
            None => {
                let latency = self.latency.min(tile.1);
                Cost {
                    latency,
                    per_voxel: (tile.1 - latency) / voxels,
                    last: tile,
                    other: None,
                }
            }
        }
    }

    /// The side of the square tiles that take at most `budget`: the whole
    /// frame's longer side when it does, otherwise a power of two.
    fn side(&self, budget: Duration, view: &View3) -> u32 {
        let fits = |w, h| self.of(volume([w, h], view.depth)) <= budget.as_secs_f64();
        if fits(view.width, view.height) {
            return view.width.max(view.height);
        }
        let mut side = view.width.max(view.height).next_power_of_two() / 2;
        while side > MIN_TILE && !fits(side, side) {
            side /= 2;
        }
        side.max(MIN_TILE)
    }
}

fn volume(size: [u32; 2], depth: u32) -> f64 {
    f64::from(size[0]) * f64::from(size[1]) * f64::from(depth)
}

const EMPTY: PackedVoxel = PackedVoxel {
    normal: [-128, -128],
    index: 0,
    z: 0,
};

/// Normals come packed as x and y in 127ths, z towards the viewer; -128
/// for both marks one that is unknown.
fn normal(voxel: &PackedVoxel) -> [f32; 3] {
    match voxel.normal {
        [-128, -128] => [0.0; 3],
        [x, y] => {
            let (x, y) = (f32::from(x) / 127.0, f32::from(y) / 127.0);
            [x, y, (1.0 - x * x - y * y).max(0.0).sqrt()]
        }
    }
}

/// Merged voxels as SSAO takes them
fn geometry(voxels: &[PackedVoxel], view: &View3) -> cpu_voxel::Image {
    let mut image = cpu_voxel::Image::new(VoxelSize::new(view.width, view.height, view.depth));
    for (i, voxel) in voxels.iter().enumerate() {
        image[i] = GeometryPixel {
            normal: normal(voxel),
            depth: voxel.z,
        };
    }
    image
}

#[cfg(test)]
mod test {
    use super::*;
    use nalgebra::Matrix4;

    fn view(width: u32, height: u32) -> View3 {
        View3 {
            world_to_model: Matrix4::identity(),
            width,
            height,
            depth: width.max(height),
            z_scale: 1.0,
            scale: 1.0,
        }
    }

    /// A GPU whose tiles take `latency`, then the rest of `full` for an
    /// 800x600 frame, in seconds
    fn gpu(latency: f64, full: f64) -> impl Fn(&View3) -> (f64, f64) {
        move |view| {
            let voxels = volume([view.width, view.height], view.depth);
            let share = voxels / volume([800, 600], 800);
            (voxels, latency + (full - latency) * share)
        }
    }

    #[test]
    fn a_frame_after_small_ones_is_one_tile() {
        let budget = Duration::from_millis(400);
        let (full, small) = (view(800, 600), view(200, 150));
        for (latency, seconds) in [(0.03, 0.09), (0.05, 0.25)] {
            let took = gpu(latency, seconds);
            let mut cost = Cost::linear(took(&view(MIN_TILE, MIN_TILE)));
            for view in [&full, &full].into_iter().chain([&small; 30]) {
                let (voxels, seconds) = took(view);
                cost = cost.refit(Duration::from_secs_f64(seconds), voxels);
            }
            assert_eq!(cost.side(budget, &full), 800);
            let predicted = cost.of(took(&full).0);
            assert!(
                (predicted - seconds).abs() < 0.01,
                "{predicted} s for {seconds} s"
            );
        }
    }

    #[test]
    fn sizes_too_close_keep_the_latency() {
        let cost = Cost::through((4000.0, 0.02), (8000.0, 0.03));
        let refit = cost.refit(Duration::from_secs_f64(0.04), 5000.0);
        assert_eq!(refit.latency, cost.latency);
        assert!(refit.other.is_none());
    }
}
