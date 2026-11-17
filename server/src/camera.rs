// SPDX-License-Identifier: MPL-2.0

//! Where views look from: the transforms from fidget's screen space to the
//! model, for 3D views and for 2D slices.
//!
//! fidget renders a region of screen space onto the image: x and y span
//! the image, ±1 across its shorter side, y up, and z points out of the
//! screen, its voxels as deep as the pixels are wide.  A `world_to_model`
//! matrix places that region in the model.
//!
//! fidget samples each pixel at a corner; the views move the samples to
//! the pixels' centres, where `probe` looks too.

use nalgebra::{Matrix3, Matrix4, Rotation3, Translation2, Translation3, Vector3};

use crate::bounds::Box3;
use crate::protocol::{Axis, Camera, Slice};
use crate::scene::Orientation;

/// The share of the image's shorter side that the region fills at zoom 1.
const FILL: f64 = 0.9;

/// Views deeper than this many times the image's longer side squeeze their
/// depth, rather than render ever more voxels when zoomed in.
const MAX_DEPTH: f64 = 2.0;

pub struct View3 {
    pub world_to_model: Matrix4<f32>,
    pub width: u32,
    pub height: u32,
    pub depth: u32,
    /// How much the depth is squeezed: normals' z components are divided by
    /// it to undo the squeeze in shading
    pub z_scale: f32,
    /// World units per pixel at the focus
    pub scale: f64,
}

/// A 3D view of `region`: the camera looks from `azimuth` around Z (0 from
/// +X) and `elevation` above the XY plane at the region's centre, the
/// region's eight corners, projected, filling the image at zoom 1, so that
/// a flat part seen from above fills it as a cube does; a perspective
/// camera stands as far away as one with a 30-degree view angle that fits
/// the bounding sphere.
pub fn view3(region: &Box3, camera: &Camera, width: u32, height: u32) -> View3 {
    let center = Vector3::from(region.center());
    let radius = (Vector3::from(region.size()).norm() / 2.0).max(1e-6);
    let shorter = f64::from(width.min(height));
    let (w, h) = (f64::from(width) / shorter, f64::from(height) / shorter);

    let (azimuth, elevation) = (camera.azimuth.to_radians(), camera.elevation.to_radians());
    let back = Vector3::new(
        elevation.cos() * azimuth.cos(),
        elevation.cos() * azimuth.sin(),
        elevation.sin(),
    );
    // Z stays up; past the poles the view turns over, as a camera does.
    let right = Vector3::new(-azimuth.sin(), azimuth.cos(), 0.0)
        * if elevation.cos() < 0.0 { -1.0 } else { 1.0 };
    let up = back.cross(&right);

    // How far the region's corners reach right and up of its centre: by
    // symmetry, the half-size's projections, summed without sign.
    let half = Vector3::from(region.size()) / 2.0;
    let extent = |axis: &Vector3<f64>| half.zip_map(axis, |a, b| (a * b).abs()).sum();
    let fitted = (extent(&right) / w).max(extent(&up) / h).max(1e-6);
    // World units per screen unit, at the focus
    let s = fitted / (FILL * camera.zoom);
    let half_height = s * f64::from(height) / shorter;
    let focus = center + (right * camera.pan[0] + up * camera.pan[1]) * half_height;

    // With perspective, screen depth u maps to the depth s·u/(1 + q·u) in
    // front of the focus, which keeps rays straight.
    let q = if camera.orthographic {
        0.0
    } else {
        s / (radius / 15f64.to_radians().sin())
    };
    // Screen depths of the sphere's far and near sides, with some margin
    let reach = radius * 1.02;
    let near = reach / (s - q * reach);
    let far = -reach / (s + q * reach);
    let shift = -(near + far) / 2.0;
    let needed = (near - far) / 2.0 * shorter;
    // Whole tiles of 64 voxels, as fidget renders anyway, which also keeps
    // the GPU's buffers from one zoom step to the next.
    let depth =
        (needed.clamp(shorter, MAX_DEPTH * f64::from(width.max(height))) / 64.0).ceil() * 64.0;
    let z_scale = (needed / depth).max(1.0);

    // Screen space to camera space, homogeneous, then camera space to the
    // model
    #[rustfmt::skip]
    let to_camera = Matrix4::new(
        s,   0.0, 0.0,           0.0,
        0.0, s,   0.0,           0.0,
        0.0, 0.0, s * z_scale,   s * shift,
        0.0, 0.0, q * z_scale,   1.0 + q * shift,
    );
    #[rustfmt::skip]
    let to_model = Matrix4::new(
        right.x, up.x, back.x, focus.x,
        right.y, up.y, back.y, focus.y,
        right.z, up.z, back.z, focus.z,
        0.0,     0.0,  0.0,    1.0,
    );
    View3 {
        world_to_model: (to_model * to_camera * centres3(shorter)).cast(),
        width,
        height,
        depth: depth as u32,
        z_scale: z_scale as f32,
        scale: 2.0 * s / shorter,
    }
}

/// The shift in screen space from a pixel's sample to its centre, half a
/// pixel right and up, for an image `shorter` pixels across its shorter
/// side.
fn centres3(shorter: f64) -> Matrix4<f64> {
    Translation3::new(1.0 / shorter, 1.0 / shorter, 0.0).to_homogeneous()
}

fn centres2(shorter: f64) -> Matrix3<f64> {
    Translation2::new(1.0 / shorter, 1.0 / shorter).to_homogeneous()
}

pub struct View2 {
    /// From screen space to the oriented model, its x and y the image's
    /// right and up
    pub world_to_model: Matrix3<f32>,
    pub axis: Axis,
    pub offset: f64,
    pub tilt: Option<Tilt>,
    /// World units per screen unit at zoom 1, the scale at which distances
    /// are coloured
    pub unit: f64,
    /// World units per pixel
    pub scale: f64,
}

/// A slice's plane turned about its own right and up.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Tilt {
    /// Degrees about the image's right, then about its turned up, by the
    /// right-hand rule
    pub angles: [f64; 2],
    /// The point the plane turns about, in the oriented model
    pub pivot: [f64; 3],
}

impl Tilt {
    /// The tilt of `slice`, about the centre of `region`, or `None` for a
    /// level one.
    pub fn of(slice: &Slice, region: &Box3) -> Option<Tilt> {
        let [i, j] = plane_axes(slice.axis);
        let center = region.center();
        (slice.tilt != [0.0, 0.0]).then_some(Tilt {
            angles: slice.tilt,
            pivot: [center[i], center[j], center[slice.axis.index()]],
        })
    }

    /// From the level plane to the turned one: its columns are the turned
    /// right, up and normal.
    pub fn rotation(&self) -> Rotation3<f64> {
        let [right, up] = self.angles.map(f64::to_radians);
        Rotation3::from_axis_angle(&Vector3::x_axis(), right)
            * Rotation3::from_axis_angle(&Vector3::y_axis(), up)
    }

    /// The oriented model's point that `p` of the level plane turns to.
    pub fn point(&self, p: [f64; 3]) -> [f64; 3] {
        let pivot = Vector3::from(self.pivot);
        (pivot + self.rotation() * (Vector3::from(p) - pivot)).into()
    }
}

/// The model axes along the image's right and up when slicing normal to
/// `axis`.
pub fn plane_axes(axis: Axis) -> [usize; 2] {
    match axis {
        Axis::X => [1, 2],
        Axis::Y => [0, 2],
        Axis::Z => [0, 1],
    }
}

/// How far `region` reaches along the right and up of the plane of
/// `slice`: the region's size along them, or, for a tilted plane, the
/// size of its projection onto them, so that no slice of it reaches past.
pub fn plane_size(region: &Box3, slice: &Slice) -> [f64; 2] {
    let [i, j] = plane_axes(slice.axis);
    let size = region.size();
    let size = Vector3::new(size[i], size[j], size[slice.axis.index()]);
    let Some(tilt) = Tilt::of(slice, region) else {
        return [size.x, size.y];
    };
    let rotation = tilt.rotation();
    [0, 1].map(|k| rotation.matrix().column(k).abs().dot(&size))
}

/// A slice of `region`, the region's projection along the slice's axis
/// filling the image at zoom 1, tilted or not, so that a slice keeps its
/// scale as it turns.
pub fn view2(region: &Box3, camera: &Camera, slice: &Slice, width: u32, height: u32) -> View2 {
    let [i, j] = plane_axes(slice.axis);
    let size = region.size();
    let center = region.center();
    let shorter = f64::from(width.min(height));
    let (w, h) = (f64::from(width) / shorter, f64::from(height) / shorter);

    let unit = ((size[i] / 2.0 / w).max(size[j] / 2.0 / h) / FILL).max(1e-9);
    let s = unit / camera.zoom;
    let half_height = s * h;
    let cx = center[i] + camera.pan[0] * half_height;
    let cy = center[j] + camera.pan[1] * half_height;
    #[rustfmt::skip]
    let world_to_model = Matrix3::new(
        s,   0.0, cx,
        0.0, s,   cy,
        0.0, 0.0, 1.0,
    );
    View2 {
        world_to_model: (world_to_model * centres2(shorter)).cast(),
        axis: slice.axis,
        offset: slice.offset,
        tilt: Tilt::of(slice, region),
        unit,
        scale: 2.0 * s / shorter,
    }
}

impl View2 {
    /// How the shapes are turned for this slice.
    pub fn orientation(&self) -> Orientation {
        match self.tilt {
            Some(tilt) => Orientation::Tilted(self.axis, tilt),
            None => Orientation::Slice(self.axis),
        }
    }

    /// The model point under pixel (`x`, `y`) of a `width` by `height` image.
    pub fn point(&self, x: f64, y: f64, width: u32, height: u32) -> [f64; 3] {
        let screen = fidget::render::ImageSize::new(width, height).screen_to_world();
        let p = (self.world_to_model.cast::<f64>() * screen.cast::<f64>())
            .transform_point(&nalgebra::Point2::new(x, y));
        let mut p = [p.x, p.y, self.offset];
        if let Some(tilt) = self.tilt {
            p = tilt.point(p);
        }
        let [i, j] = plane_axes(self.axis);
        let mut out = [0.0; 3];
        out[i] = p[0];
        out[j] = p[1];
        out[self.axis.index()] = p[2];
        out
    }
}

impl View3 {
    /// The model point at pixel (`x`, `y`) and voxel `depth`, as a frame's
    /// depth image has it.
    pub fn point(&self, x: f64, y: f64, depth: f64) -> [f64; 3] {
        let screen =
            fidget::render::VoxelSize::new(self.width, self.height, self.depth).screen_to_world();
        let p = (self.world_to_model.cast::<f64>() * screen.cast::<f64>())
            .transform_point(&nalgebra::Point3::new(x, y, depth));
        [p.x, p.y, p.z]
    }
}

#[cfg(test)]
mod test {
    use super::*;

    fn region() -> Box3 {
        Box3 {
            lower: [-1.0, -2.0, -3.0],
            upper: [3.0, 2.0, 1.0],
        }
    }

    #[test]
    fn looks_at_the_centre_with_z_up() {
        let camera = Camera {
            azimuth: 0.0,
            elevation: 0.0,
            ..Camera::default()
        };
        for orthographic in [true, false] {
            let camera = Camera {
                orthographic,
                ..camera
            };
            let view = view3(&region(), &camera, 300, 200);
            let depth = f64::from(view.depth) / 2.0;
            // The middle pixel looks along the axis through the centre; a
            // perspective view's depths do not map evenly onto it.
            let center = view.point(149.5, 99.5, depth);
            let on_axis = (center[1] - 0.0).abs() < 1e-3 && (center[2] + 1.0).abs() < 1e-3;
            assert!(on_axis, "{center:?}");
            if orthographic {
                assert!((center[0] - 1.0).abs() < 1e-3, "{center:?}");
            }
            // From +X, the image's right is +Y and its up is +Z.
            let right = view.point(249.5, 99.5, depth);
            let up = view.point(149.5, 49.5, depth);
            assert!(
                right[1] > center[1] && (right[2] - center[2]).abs() < 1e-3,
                "{right:?}"
            );
            assert!(
                up[2] > center[2] && (up[1] - center[1]).abs() < 1e-3,
                "{up:?}"
            );
        }
    }

    #[test]
    fn fits_the_projected_corners() {
        // From +X, the 4 × 4 region fills the shorter side.
        let camera = Camera {
            azimuth: 0.0,
            elevation: 0.0,
            ..Camera::default()
        };
        let view = view3(&region(), &camera, 300, 200);
        assert!((view.scale * 200.0 * FILL - 4.0).abs() < 1e-9);

        // A plate seen from above fills the image, wider than it is tall.
        let plate = Box3 {
            lower: [-30.0, -10.0, -1.0],
            upper: [30.0, 10.0, 1.0],
        };
        let camera = Camera {
            azimuth: -90.0,
            elevation: 89.9,
            ..Camera::default()
        };
        let view = view3(&plate, &camera, 300, 200);
        assert!(
            (view.scale * 300.0 * FILL - 60.0).abs() < 0.1,
            "{}",
            view.scale
        );
    }

    #[test]
    fn slices_span_their_plane() {
        let camera = Camera::default();
        let slice = Slice {
            axis: Axis::Y,
            offset: 0.5,
            tilt: [0.0, 0.0],
        };
        let view = view2(&region(), &camera, &slice, 200, 200);
        let center = view.point(99.5, 99.5, 200, 200);
        assert!(
            (0..3).all(|i| (center[i] - [1.0, 0.5, -1.0][i]).abs() < 1e-6),
            "{center:?}"
        );
        let corner = view.point(199.5, -0.5, 200, 200);
        // The wider of x and z fills 90% of the image.
        assert!((corner[0] - (1.0 + 2.0 / FILL)).abs() < 1e-6, "{corner:?}");
        assert!((corner[2] - (-1.0 + 2.0 / FILL)).abs() < 1e-6, "{corner:?}");
    }
}
