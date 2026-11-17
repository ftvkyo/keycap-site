// SPDX-License-Identifier: MPL-2.0

//! Frames on the CPU, the colouring shared with the GPU, and the PPM files
//! they are written to.

use std::io::Write;
use std::path::Path;

use fidget::jit::JitShape;
use fidget::raster::pixel::{DistancePixel, RawDistancePixel};
use fidget::raster::{ColorImage, effects, pixel, voxel};
use fidget::render::{CancelToken, ImageSize, ThreadPool, VoxelSize};
use fidget::types::Grad;
use rayon::prelude::*;

use crate::camera::{View2, View3};
use crate::protocol::{BoundsChoice, View};
use crate::scene::{self, Compiled, Orientation, Scene};
use crate::{shade, ssao};

pub type Rgb = [u8; 3];

const THREADS: Option<&ThreadPool> = Some(&ThreadPool::Global);

/// Whether the shapes differ in colour or role, so that each is rendered
/// alone; otherwise their union stands in for them, in the first one's
/// colour.
pub fn shapes_differ(scene: &Scene) -> bool {
    let colors = scene.colors();
    colors.iter().any(|&c| Some(c) != colors.first().copied()) || scene.has_roles()
}

/// The colour of the shape at `index` of `colors`, as `Scene::colors` has
/// them; a frame of the union has every pixel at index 0.
pub fn color_at(colors: &[[f32; 3]], index: usize) -> [f32; 3] {
    colors.get(index).copied().unwrap_or(scene::DEFAULT_COLOR)
}

pub fn to_rgb(c: [f32; 3]) -> Rgb {
    c.map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8)
}

/// Fills a `width` by `height` image with `f(x, y)`, on every core.
pub fn per_pixel(
    width: u32,
    height: u32,
    f: impl Fn(usize, usize) -> Rgb + Send + Sync,
) -> Vec<Rgb> {
    let mut image = ColorImage::new(ImageSize::new(width, height));
    image.apply_effect(f, THREADS);
    image.take().0
}

// --- 3D ---

/// A 3D frame: its pixels, and the depth of each for probing.
pub struct Frame3 {
    pub pixels: Vec<Rgb>,
    pub depth: Vec<u32>,
}

/// Renders a 3D view of the shapes cut to the region of `bounds` on the
/// CPU, or `None` once `cancel` fires.
pub fn render3(
    scene: &Scene,
    bounds: BoundsChoice,
    view: &View3,
    kind: View,
    background: [f32; 3],
    cancel: &CancelToken,
) -> Result<Option<Frame3>, String> {
    let compiled = scene.compiled(Orientation::Solid(bounds))?;
    let config = voxel::RenderConfig {
        image_size: VoxelSize::new(view.width, view.height, view.depth),
        world_to_model: view.world_to_model,
    };
    let eval = voxel::EvalConfig {
        tile_sizes: None,
        threads: THREADS,
        cancel: cancel.clone(),
    };
    let mut images = vec![];
    for shape in shapes(&compiled, kind != View::Heightmap && shapes_differ(scene))? {
        match voxel::render(scene::bound(shape.clone())?, &config, &eval) {
            Some(image) => images.push(image),
            None => return Ok(None),
        }
    }
    let Some((mut image, owner)) = merge_images(images) else {
        return Ok(None);
    };

    repair_normals(&mut image, &compiled.union, &config);
    if view.z_scale != 1.0 {
        for i in 0..image.len() {
            image[i].normal[2] /= view.z_scale;
        }
    }
    let depth: Vec<u32> = image.iter().map(|p| p.depth).collect();
    let background = to_rgb(background);
    let pixels = match kind {
        View::Heightmap => heightmap(view, &depth, background),
        _ => {
            let image = effects::denoise_normals(&image, THREADS);
            let openness = ssao::openness(&image);
            let normals: Vec<[f32; 3]> = image.iter().map(|p| p.normal).collect();
            let geometry = shade::Geometry {
                width: view.width as usize,
                height: view.height as usize,
                depth: &depth,
                normals: &normals,
                owner: &owner,
                openness: &openness,
                z_scale: view.z_scale,
            };
            shade::frame(&geometry, &scene.colors(), background)
        }
    };
    Ok(Some(Frame3 { pixels, depth }))
}

/// A height map of `depth`, nearer pixels lighter.
pub fn heightmap(view: &View3, depth: &[u32], background: Rgb) -> Vec<Rgb> {
    let full = view.depth as f32;
    per_pixel(view.width, view.height, |x, y| {
        let d = depth[y * view.width as usize + x];
        if d == 0 {
            background
        } else {
            [(d as f32 / full * 255.0) as u8; 3]
        }
    })
}

/// Evaluates the normals that came out NaN again, a voxel nearer the
/// camera.
///
/// Exact distance fields written by hand often hold a `sqrt` of 0 on and
/// just inside their surfaces (a box's faces, as Inigo Quilez writes it),
/// whose derivative is NaN; such a face would shade black.  Just outside,
/// the root is of something positive.  The prelude's fields choose around
/// their roots and need none of this.
fn repair_normals(image: &mut voxel::Image, shape: &JitShape, config: &voxel::RenderConfig) {
    let broken: Vec<usize> = (0..image.len())
        .filter(|&i| image[i].depth > 0 && !image[i].normal.iter().all(|n| n.is_finite()))
        .collect();
    if broken.is_empty() {
        return;
    }
    let width = config.image_size.width() as usize;
    let at = |i: usize, axis: usize| {
        let p = [i % width, i / width].map(|v| v as f32);
        let mut g = [0.0; 3];
        g[axis] = 1.0;
        let v = if axis == 2 {
            image[i].depth as f32
        } else {
            p[axis]
        };
        Grad::new(v, g[0], g[1], g[2])
    };
    let tape = shape.grad_slice_tape(Default::default());
    let transform = config.mat();
    let normals: Vec<Option<[f32; 3]>> = broken
        .par_chunks(4096)
        .flat_map_iter(|chunk| {
            let [x, y, z] =
                [0, 1, 2].map(|axis| chunk.iter().map(|&i| at(i, axis)).collect::<Vec<_>>());
            let mut eval = JitShape::new_grad_slice_eval();
            match eval.eval_with_transform(&tape, &x, &y, &z, &transform) {
                Ok(out) => out.iter().map(|g| Some([g.dx, g.dy, g.dz])).collect(),
                Err(_) => vec![None; chunk.len()],
            }
        })
        .collect();
    for (&i, normal) in broken.iter().zip(normals) {
        if let Some(normal) = normal {
            image[i].normal = normal;
        }
    }
}

/// The shapes to render: each alone when `each`, which colours call for,
/// otherwise their union.
fn shapes(compiled: &Compiled, each: bool) -> Result<&[JitShape], String> {
    if each {
        compiled.each()
    } else {
        Ok(std::slice::from_ref(&compiled.union))
    }
}

/// The union of per-shape frames, each pixel owned by the shape nearest
/// the camera.
fn merge_images(images: Vec<voxel::Image>) -> Option<(voxel::Image, Vec<usize>)> {
    let mut images = images.into_iter();
    let mut merged = images.next()?;
    let mut owner = vec![0; merged.len()];
    for (index, image) in images.enumerate() {
        for (i, pixel) in image.iter().enumerate() {
            if pixel.depth > merged[i].depth {
                merged[i] = *pixel;
                owner[i] = index + 1;
            }
        }
    }
    Some((merged, owner))
}

// --- 2D ---

/// The distances of a 2D frame and the shape owning each pixel, its index
/// in the scene, or 0 throughout for a frame of the union.
pub struct Field {
    pub distance: Vec<RawDistancePixel>,
    pub owner: Vec<usize>,
    /// Per pixel, how far the nearest surface of any shape is and that
    /// shape's index, so that an outline shows inside another shape
    pub edge: Vec<(f32, usize)>,
}

/// Renders a 2D slice's distances on the CPU, or `None` once `cancel`
/// fires.
pub fn field2(
    scene: &Scene,
    view: &View2,
    kind: View,
    width: u32,
    height: u32,
    cancel: &CancelToken,
) -> Result<Option<Field>, String> {
    let compiled = scene.compiled(view.orientation())?;
    let config = pixel::RenderConfig {
        image_size: ImageSize::new(width, height),
        world_to_model: view.world_to_model,
        pixel_perfect: kind == View::Sdf,
        z: view.offset as f32,
    };
    let eval = pixel::EvalConfig {
        tile_sizes: None,
        threads: THREADS,
        cancel: cancel.clone(),
    };
    let mut each = vec![];
    for shape in shapes(&compiled, shapes_differ(scene))? {
        match pixel::render(scene::bound(shape.clone())?, &config, &eval) {
            Some(image) => each.push(image.take().0),
            None => return Ok(None),
        }
    }
    Ok(Some(merge_fields(each)))
}

/// The union of per-shape distances, each pixel owned by the shape
/// nearest inside it.
pub fn merge_fields(each: Vec<Vec<RawDistancePixel>>) -> Field {
    // Fill pixels carry no distance, only a side.
    let key = |p: RawDistancePixel| match p.unpack() {
        DistancePixel::Value(v) if v.is_nan() => f32::MAX,
        DistancePixel::Value(v) => v,
        DistancePixel::Fill { inside: true, .. } => -f32::MAX,
        DistancePixel::Fill { inside: false, .. } => f32::MAX,
    };
    let away = |p: RawDistancePixel| match p.unpack() {
        DistancePixel::Value(v) if !v.is_nan() => v.abs(),
        _ => f32::MAX,
    };
    let mut each = each.into_iter();
    let mut distance = each.next().unwrap_or_default();
    let mut owner = vec![0; distance.len()];
    let mut edge: Vec<(f32, usize)> = distance.iter().map(|&p| (away(p), 0)).collect();
    for (index, other) in each.enumerate() {
        for (i, p) in other.into_iter().enumerate() {
            if key(p) < key(distance[i]) {
                distance[i] = p;
                owner[i] = index + 1;
            }
            if away(p) < edge[i].0 {
                edge[i] = (away(p), index + 1);
            }
        }
    }
    Field {
        distance,
        owner,
        edge,
    }
}

/// Colours a 2D frame: `sdf` with halfspace's colour map, its variant for
/// coloured shapes when the script gives any, distances scaled by
/// `view.unit` so that a slice looks alike at any size; `mono` white (or
/// the shape's colour) inside and black outside.  When the script draws
/// shapes to score or engrave, each shape's outline is in its role's
/// colour, as 2D export writes it.
pub fn colour2(
    scene: &Scene,
    field: &Field,
    view: &View2,
    kind: View,
    width: u32,
    height: u32,
) -> Vec<Rgb> {
    let colors = scene.colors();
    let colored = scene.has_colors();
    let roles = scene.has_roles().then(|| {
        let roles = scene.drawn.iter().map(|d| d.role.rgb());
        roles.collect::<Vec<Rgb>>()
    });
    let unit = view.unit as f32;
    // About two pixels wide
    let line = view.scale as f32;
    per_pixel(width, height, |x, y| {
        let i = y * width as usize + x;
        let p = field.distance[i];
        if let Some(roles) = &roles
            && field.edge[i].0 <= line
        {
            return roles[field.edge[i].1];
        }
        let color = colored.then(|| color_at(&colors, field.owner[i]));
        match kind {
            View::Mono => {
                if p.inside() {
                    to_rgb(color_at(&colors, field.owner[i]))
                } else {
                    [0; 3]
                }
            }
            _ => {
                let d = match p.unpack() {
                    DistancePixel::Value(v) => v / unit,
                    DistancePixel::Fill { inside, .. } => {
                        if inside {
                            -1.0
                        } else {
                            1.0
                        }
                    }
                };
                to_rgb(match color {
                    Some(color) => halfspace::colored(d, color),
                    None => halfspace::orange_to_blue(d),
                })
            }
        }
    })
}

/// halfspace's SDF colour map (`shaders/sdf.wgsl`), ported to the CPU.
///
/// Halfspace is Copyright (C) Matt Keeter; like its origin this module is
/// under the Mozilla Public License, v. 2.0, see
/// <http://mozilla.org/MPL/2.0/>.
mod halfspace {
    fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
        let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
        t * t * (3.0 - 2.0 * t)
    }

    fn mix(x: f32, y: f32, a: f32) -> f32 {
        x * (1.0 - a) + y * a
    }

    fn run(v: f32, f_abs: f32, dim: f32, bands: f32) -> f32 {
        let mut v = v * dim * bands;
        v = mix(v, 1.0, 1.0 - smoothstep(0.0, 0.015, f_abs));
        v = mix(v, 1.0, 1.0 - smoothstep(0.0, 0.005, f_abs));
        v.clamp(0.0, 1.0)
    }

    /// WGSL's `sign`, which is 0 at 0.
    fn sign(f: f32) -> f32 {
        if f > 0.0 {
            1.0
        } else if f < 0.0 {
            -1.0
        } else {
            0.0
        }
    }

    /// Orange outside, blue inside, white at the surface, NaN in red.
    pub fn orange_to_blue(f: f32) -> [f32; 3] {
        if f.is_nan() {
            return [1.0, 0.0, 0.0];
        }
        let s = sign(f);
        let dim = 1.0 - (-4.0 * f.abs()).exp();
        let bands = 0.8 + 0.2 * (140.0 * f).cos();
        [1.0 - 0.1 * s, 1.0 - 0.4 * s, 1.0 - 0.7 * s].map(|c| run(c, f.abs(), dim, bands))
    }

    fn stripe(f: f32) -> f32 {
        if f.is_nan() {
            return 1.0;
        }
        let dim = 1.0 - (-4.0 * f.abs()).exp();
        let bands = 0.8 + 0.2 * (140.0 * f).cos();
        let base = if f < 0.0 { 1.0 } else { 0.2 };
        run(base, f.abs(), dim, bands)
    }

    /// The variant for coloured shapes: the colour inside, grey outside.
    pub fn colored(f: f32, rgb: [f32; 3]) -> [f32; 3] {
        let stripes = stripe(f + 1.0 / 140.0);
        if f <= 0.0 {
            rgb.map(|c| c * stripes)
        } else {
            [stripes; 3]
        }
    }
}

// --- Output ---

/// Writes `path` through `write` into a temporary file renamed into place,
/// so that a reader never sees half a file.
pub fn write_atomically(
    path: &Path,
    write: impl FnOnce(&mut std::io::BufWriter<std::fs::File>) -> std::io::Result<()>,
) -> Result<(), String> {
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".tmp");
    let temporary = Path::new(&temporary);
    let written = std::fs::File::create(temporary).and_then(|file| {
        let mut file = std::io::BufWriter::new(file);
        write(&mut file)?;
        file.into_inner().map_err(|e| e.into_error())?;
        std::fs::rename(temporary, path)
    });
    written.map_err(|error| {
        let _ = std::fs::remove_file(temporary);
        format!("cannot write {}: {error}", path.display())
    })
}

/// Writes a frame as a binary PPM.
pub fn write_ppm(path: &Path, width: u32, height: u32, pixels: &[Rgb]) -> Result<(), String> {
    write_atomically(path, |file| {
        write!(file, "P6\n{width} {height}\n255\n")?;
        file.write_all(pixels.as_flattened())
    })
}
