// SPDX-License-Identifier: MPL-2.0

//! Screen-space ambient occlusion, as fidget's `effects::compute_ssao`
//! finds it, from samples drawn once from a fixed seed.
//!
//! fidget draws its kernel and noise afresh for every frame on the CPU,
//! and for every device on the GPU, so a frame's shading changed from run
//! to run; with a fixed seed the same scene renders to the same bytes,
//! which pictures built from scripts need.  A GPU frame takes its
//! occlusion from here too when it is to be reproducible, and when it is
//! rendered in tiles, which fidget's GPU SSAO cannot join.
//!
//! Ported from fidget's `effects::compute_ssao`, Copyright (C) Matt Keeter;
//! like its origin this file is under the Mozilla Public License, v. 2.0,
//! see <http://mozilla.org/MPL/2.0/>.

use std::sync::LazyLock;

use fidget::raster::{Image, effects, voxel};
use fidget::render::{ImageSize, ThreadPool};
use fidget::rng::mix;
use nalgebra::{Matrix3, Vector2, Vector3};
use rand::distr::Uniform;
use rand::rngs::StdRng;
use rand::{RngExt, SeedableRng};

const THREADS: Option<&ThreadPool> = Some(&ThreadPool::Global);

/// How far samples reach, in the frame's [-1, 1] cube
const RADIUS: f32 = 0.1;

struct Samples {
    /// Points in the unit hemisphere above a surface, most near its middle
    kernel: Vec<Vector3<f32>>,
    /// Unit vectors that turn the kernel about the normal, one per pixel by
    /// its hash, so that neighbours sample differently
    noise: Vec<Vector2<f32>>,
}

static SAMPLES: LazyLock<Samples> = LazyLock::new(|| {
    let mut rng = StdRng::seed_from_u64(0);
    let xy = Uniform::new_inclusive(-1.0f32, 1.0).expect("a valid range");
    let z = Uniform::new_inclusive(0.0f32, 1.0).expect("a valid range");
    let n = 64;
    let kernel = (0..n)
        .map(|i| {
            loop {
                let v = Vector3::new(rng.sample(xy), rng.sample(xy), rng.sample(z));
                if v.norm() < 1.0 && v.norm() > f32::EPSILON {
                    let scale = (i as f32 / (n as f32 - 1.0)).powi(2) * 0.9 + 0.1;
                    break v * scale / v.norm();
                }
            }
        })
        .collect();
    let noise = (0..16 * 16)
        .map(|_| {
            loop {
                let v = Vector2::new(rng.sample(xy), rng.sample(xy));
                if v.norm() < 1.0 && v.norm() > f32::EPSILON {
                    break v / v.norm();
                }
            }
        })
        .collect();
    Samples { kernel, noise }
});

/// Each pixel's openness, 1 in the open and 0 deep in a crevice, blurred;
/// NaN where the frame is empty.
pub fn openness(image: &voxel::Image) -> Vec<f32> {
    let size = image.size();
    let mut occlusion = Image::<f32>::new(ImageSize::new(size.width(), size.height()));
    occlusion.apply_effect(|x, y| pixel(image, x, y), THREADS);
    effects::blur_ssao(&occlusion, THREADS).as_slice().to_vec()
}

/// The openness at one pixel: the share of the kernel's samples, turned to
/// the pixel's normal, that lie in front of the depths there.
fn pixel(image: &voxel::Image, x: usize, y: usize) -> f32 {
    let voxel::GeometryPixel {
        normal: [nx, ny, nz],
        depth: d,
    } = image[(y, x)];
    if d == 0 {
        return f32::NAN;
    }
    let (width, height, depth) = (
        image.width() as f32,
        image.height() as f32,
        image.depth() as f32,
    );
    // Samples reach as far along each axis, whatever the frame's aspect.
    let smallest = width.min(height).min(depth);
    let scale = Vector3::new(smallest / width, smallest / height, smallest / depth);
    // From the pixel's middle, as from its corner one quadrant of a sphere
    // comes out darker than the others
    let p = Vector3::new(
        ((x as f32 + 0.5) / width - 0.5) * 2.0,
        ((y as f32 + 0.5) / height - 0.5) * 2.0,
        (d as f32 / depth - 0.5) * 2.0,
    );
    let n = Vector3::new(nx, ny, nz).normalize();
    let samples = &*SAMPLES;
    let turn = samples.noise[mix(y as u32, x as u32) as usize % samples.noise.len()];
    let turn = Vector3::new(turn.x, turn.y, 0.0);
    let tangent = (turn - n * turn.dot(&n)).normalize();
    let tbn = Matrix3::from_columns(&[tangent, n.cross(&tangent), n]);

    let mut occlusion = 0.0;
    for k in &samples.kernel {
        let sample = p + (tbn * k * RADIUS).component_mul(&scale);
        let px = (sample.x / 2.0 + 0.5) * width;
        let py = (sample.y / 2.0 + 0.5) * height;
        let there = if px > 0.0 && py > 0.0 && px < width && py < height {
            image[(py as usize, px as usize)].depth
        } else {
            0
        };
        let there = (there as f32 / depth - 0.5) * 2.0;
        let dz = sample.z - there;
        if dz < RADIUS {
            occlusion += (sample.z <= there) as usize as f32;
        } else if dz < RADIUS * 2.0 && sample.z <= there {
            occlusion += ((RADIUS - (dz - RADIUS)) / RADIUS).powi(2);
        }
    }
    1.0 - occlusion / samples.kernel.len() as f32
}
