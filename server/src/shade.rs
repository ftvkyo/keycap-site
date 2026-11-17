// SPDX-License-Identifier: MPL-2.0

//! The shaded view's lighting, the same for frames from the CPU and from
//! the GPU: each gives a pixel's normal, colour and ambient occlusion, and
//! the pixel is lit here.
//!
//! The lights stay with the camera, as a photographer's do: a key light
//! above and to the left, a fill light from the right, light from the sky
//! above the view, darker below, and a little light on the silhouettes.
//! Light adds up in linear space; the result is encoded as sRGB and
//! dithered, so that smooth surfaces do not band.

use rayon::prelude::*;

use crate::render::{self, Rgb};

/// What a pixel of a 3D frame shows.
pub struct Surface {
    /// The surface's unit normal: x right, y down the image, z towards the
    /// viewer
    pub normal: [f32; 3],
    /// How open the surface is to the sky, 1 in the open and 0 deep in a
    /// crevice
    pub openness: f32,
    /// The shape's sRGB colour, 0 to 1
    pub color: [f32; 3],
}

/// Towards the key light: up, left and in front.
const KEY: [f32; 3] = [-0.55, -0.55, 0.63];
const KEY_LIGHT: f32 = 1.1;

/// Towards the fill light: right and a little below.
const FILL: [f32; 3] = [0.8, 0.2, 0.56];
const FILL_LIGHT: f32 = 0.12;

/// Light from the sky above the view and from the ground below it.
const SKY: f32 = 0.12;
const GROUND: f32 = 0.02;

const RIM_LIGHT: f32 = 0.1;

/// A highlight of the key light, as on matte plastic.
const SPECULAR: f32 = 0.08;
const SHININESS: f32 = 40.0;

/// The openness SSAO finds on open surfaces, and in crevices.
const OPEN: f32 = 0.9;
const OCCLUDED: f32 = 0.3;

/// Shapes reflect this much of their colour, so that white ones keep
/// their shading.
const ALBEDO: f32 = 0.7;

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn normalize(v: [f32; 3]) -> [f32; 3] {
    let length = dot(v, v).sqrt();
    v.map(|c| c / length)
}

/// The light leaving a surface towards the viewer, linear.
pub fn shade(surface: &Surface) -> [f32; 3] {
    let n = surface.normal;
    // SSAO sees a little occlusion on open surfaces, where the depths it
    // samples step from voxel to voxel, in rings; only more counts.
    let open = ((surface.openness - OCCLUDED) / (OPEN - OCCLUDED)).clamp(0.0, 1.0);
    let key = normalize(KEY);
    let ambient = (GROUND + (SKY - GROUND) * (0.5 - 0.5 * n[1])) * open;
    // Occlusion darkens direct light less than ambient light.
    let direct = (KEY_LIGHT * dot(n, key).max(0.0) + FILL_LIGHT * dot(n, normalize(FILL)).max(0.0))
        * (0.4 + 0.6 * open);
    let rim = RIM_LIGHT * (1.0 - n[2].clamp(0.0, 1.0)).powi(3) * open;
    let half = normalize([key[0], key[1], key[2] + 1.0]);
    let specular = SPECULAR * dot(n, half).max(0.0).powf(SHININESS) * open;
    let light = ambient + direct + rim;
    surface
        .color
        .map(|c| srgb_to_linear(c) * ALBEDO * light + specular)
}

fn srgb_to_linear(c: f32) -> f32 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn linear_to_srgb(c: f32) -> f32 {
    if c <= 0.0031308 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

/// `linear` as 8-bit sRGB for the pixel at (`x`, `y`), dithered with
/// noise of a triangular distribution an 8-bit step wide either way, the
/// same for the same pixel in every frame.
pub fn encode(linear: [f32; 3], x: usize, y: usize) -> Rgb {
    let mut seed = (x as u32).wrapping_mul(0x9E37_79B9) ^ (y as u32).wrapping_mul(0x85EB_CA6B);
    let mut noise = || {
        seed ^= seed >> 15;
        seed = seed.wrapping_mul(0x2C1B_3C6D);
        seed ^= seed >> 12;
        seed = seed.wrapping_mul(0x297A_2D39);
        seed ^= seed >> 15;
        seed as f32 / u32::MAX as f32
    };
    linear.map(|c| {
        let dither = noise() + noise() - 1.0;
        (linear_to_srgb(c.clamp(0.0, 1.0)) * 255.0 + dither)
            .round()
            .clamp(0.0, 255.0) as u8
    })
}

// --- Frames ---

/// A 3D frame as rendered, before it is lit.
pub struct Geometry<'a> {
    pub width: usize,
    pub height: usize,
    /// Each pixel's depth in voxels, towards the viewer; 0 where empty
    pub depth: &'a [u32],
    /// Each pixel's normal, any length, 0 where unknown
    pub normals: &'a [[f32; 3]],
    /// The index in the scene's colours of the shape each pixel shows
    pub owner: &'a [usize],
    /// Each pixel's openness, as `Surface` has it
    pub openness: &'a [f32],
    /// How many pixels' width a voxel's depth spans
    pub z_scale: f32,
}

/// The pixels of `geometry`, lit, its shapes in `colors`, empty pixels in
/// `background`.
pub fn frame(geometry: &Geometry, colors: &[[f32; 3]], background: Rgb) -> Vec<Rgb> {
    let normals: Vec<[f32; 3]> = (0..geometry.depth.len())
        .into_par_iter()
        .map(|i| smooth_normal(geometry, i))
        .collect();
    render::per_pixel(geometry.width as u32, geometry.height as u32, |x, y| {
        let i = y * geometry.width + x;
        if geometry.depth[i] == 0 {
            return background;
        }
        let surface = Surface {
            normal: normals[i],
            openness: geometry.openness[i],
            color: render::color_at(colors, geometry.owner[i]),
        };
        encode(shade(&surface), x, y)
    })
}

/// Neighbours this far away, in pixels, smooth a pixel's normal.
const SMOOTHING: isize = 2;

/// The normal at pixel `i`, averaged with its neighbours' on the same
/// smooth surface.
///
/// A frame's normals come from the voxels the surface passes through, not
/// from the surface itself; the error jumps from one voxel's depth to the
/// next, and draws rings on smooth surfaces under a light.  Neighbours lie
/// on the same surface when they are near the plane of the pixel's normal
/// and their normals differ little, so that edges stay sharp.
fn smooth_normal(geometry: &Geometry, i: usize) -> [f32; 3] {
    let unit = |n: [f32; 3]| {
        let length = dot(n, n).sqrt();
        (length > 0.0 && length.is_finite()).then(|| n.map(|c| c / length))
    };
    let Some(n) = unit(geometry.normals[i]) else {
        return [0.0, 0.0, 1.0];
    };
    let (x, y) = ((i % geometry.width) as isize, (i / geometry.width) as isize);
    let depth = geometry.depth[i] as f32;
    let mut sum = [0.0; 3];
    for dy in -SMOOTHING..=SMOOTHING {
        for dx in -SMOOTHING..=SMOOTHING {
            let (nx, ny) = (x + dx, y + dy);
            if nx < 0 || ny < 0 || nx >= geometry.width as isize || ny >= geometry.height as isize {
                continue;
            }
            let j = ny as usize * geometry.width + nx as usize;
            let Some(m) = unit(geometry.normals[j]).filter(|_| geometry.depth[j] > 0) else {
                continue;
            };
            // The depth the pixel's plane has there, in voxels
            let plane =
                depth - (n[0] * dx as f32 + n[1] * dy as f32) / (n[2].max(0.1) * geometry.z_scale);
            if (geometry.depth[j] as f32 - plane).abs() > 2.0 || dot(n, m) < 0.9 {
                continue;
            }
            let weight = 1.0 / (1.0 + (dx * dx + dy * dy) as f32);
            for k in 0..3 {
                sum[k] += m[k] * weight;
            }
        }
    }
    unit(sum).unwrap_or(n)
}

#[cfg(test)]
mod test {
    use super::*;

    fn lit(normal: [f32; 3]) -> f32 {
        shade(&Surface {
            normal: normalize(normal),
            openness: 1.0,
            color: [1.0; 3],
        })[0]
    }

    #[test]
    fn faces_towards_the_key_light_are_brighter() {
        let toward = lit(KEY);
        assert!(toward > lit([0.0, 0.0, 1.0]));
        assert!(lit([0.0, 0.0, 1.0]) > lit([0.0, 1.0, 0.3]));
        // White stays below white, but for its highlight.
        assert!(lit([0.0, 0.0, 1.0]) < 1.0);
    }

    #[test]
    fn occlusion_darkens() {
        let surface = |openness| Surface {
            normal: [0.0, 0.0, 1.0],
            openness,
            color: [0.5; 3],
        };
        assert!(shade(&surface(0.2))[0] < shade(&surface(1.0))[0]);
    }

    #[test]
    fn dithering_averages_to_the_value() {
        // Between two 8-bit steps, pixels take either.
        let value = srgb_to_linear(100.5 / 255.0);
        let pixels: Vec<u8> = (0..64)
            .flat_map(|x| (0..64).map(move |y| encode([value; 3], x, y)[0]))
            .collect();
        let mean = pixels.iter().map(|&p| f64::from(p)).sum::<f64>() / pixels.len() as f64;
        assert!((mean - 100.5).abs() < 0.1, "{mean}");
        assert!(pixels.iter().all(|p| (99..=102).contains(p)));
    }
}
