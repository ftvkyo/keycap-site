// SPDX-License-Identifier: MPL-2.0

//! Resin prints: the shape's layers sampled from its field on a printer's
//! display, no mesh between, each pixel as grey as the share of it the
//! shape covers, and written as they come into an SL1 archive.
//!
//! The model's footprint sits in the middle of the display and its lowest
//! layer on the plate.  Supports are the printer software's business: a
//! model that needs them goes there as an STL.

use std::io::{self, Write};
use std::ops::Range;
use std::path::Path;

use fidget::jit::{JitFunction, JitShape};
use fidget::raster::pixel::{self, DistancePixel, RawDistancePixel};
use fidget::render::{CancelToken, ImageSize};
use fidget::shape::BoundShape;
use nalgebra::Matrix3;
use rayon::prelude::*;
use serde::Deserialize;

use crate::bounds::{Box3, Fitted};
use crate::mesh::{Job, Stage};
use crate::{render, scene, sl1};

/// The printers known by name, and their profiles
const PRINTERS: &[(&str, &str)] = &[
    ("prusa-sl1s", include_str!("../printers/prusa-sl1s.toml")),
    (
        "creality-halot-sky",
        include_str!("../printers/creality-halot-sky.toml"),
    ),
    (
        "creality-halot-mage-pro",
        include_str!("../printers/creality-halot-mage-pro.toml"),
    ),
];

/// Rows of a layer sampled at once, as tall as the JIT's largest tile.
const BAND: usize = 128;

type Shape = BoundShape<'static, JitFunction, f32>;

// --- Printers ---

/// A resin printer, as its profile describes it; lengths in mm, times in
/// seconds.
#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Printer {
    /// What the printer calls itself: the SL1 and SL1S print only their
    /// own prints, and UVtools converts for the Creality whose CL- code it
    /// names
    pub model: String,
    pub display: Display,
    /// The tallest print
    pub height: f64,
    pub layer_height: f64,
    pub exposure: f64,
    pub bottom_exposure: f64,
    /// The layers exposed longer, to hold to the plate
    pub bottom_layers: u32,
    /// Lines of PrusaSlicer's printer notes, where UVtools reads lifts,
    /// waits and the format to convert to
    #[serde(default)]
    pub notes: Vec<String>,
}

/// The display as PrusaSlicer describes it: its x and y are the plate's.
#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Display {
    /// Along x, then y
    pub pixels: [u32; 2],
    pub size: [f64; 2],
    #[serde(default)]
    pub orientation: Orientation,
    /// Whether the image is mirrored along x, and along y
    #[serde(default)]
    pub mirror: [bool; 2],
}

/// How a layer's image lies on the display: its rows along y, or along x.
#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Default, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Orientation {
    #[default]
    Landscape,
    Portrait,
}

impl Printer {
    /// The printer known as `name`, or the one the TOML file `name`
    /// describes.
    pub fn load(name: &str) -> Result<Printer, String> {
        let text = if name.ends_with(".toml") {
            std::fs::read_to_string(name).map_err(|error| format!("cannot read {name}: {error}"))?
        } else {
            let known = PRINTERS.iter().find(|(known, _)| *known == name);
            let Some((_, profile)) = known else {
                let names: Vec<&str> = PRINTERS.iter().map(|(name, _)| *name).collect();
                return Err(format!(
                    "no printer {name}; known are {}, or a .toml file describes one",
                    names.join(", ")
                ));
            };
            (*profile).to_owned()
        };
        let printer: Printer =
            toml::from_str(&text).map_err(|error| format!("bad printer {name}: {error}"))?;
        let display = &printer.display;
        let positive = [
            printer.height,
            printer.layer_height,
            printer.exposure,
            printer.bottom_exposure,
            display.size[0],
            display.size[1],
        ];
        if !positive.iter().all(|v| v.is_finite() && *v > 0.0) || display.pixels.contains(&0) {
            return Err(format!(
                "bad printer {name}: sizes, pixels and times must be positive"
            ));
        }
        Ok(printer)
    }
}

// --- Layers ---

/// Where a print's layers lie: the image each is, as the printer shows it,
/// the model's footprint on it, and the heights they are sampled at.
pub struct Plan {
    /// The image's width and height
    size: [usize; 2],
    /// The image's columns and rows the footprint covers
    footprint: [Range<usize>; 2],
    /// From a point of the image, in pixels from its top left, to the
    /// model's (x, y)
    to_model: Matrix3<f64>,
    /// The side of a square of a pixel's area, which a pixel's grey takes
    /// to cross
    pitch: f64,
    /// The volume a pixel of a layer holds
    voxel: f64,
    /// Where the lowest layer starts
    bottom: f64,
    pub layer_height: f64,
    pub layers: usize,
}

impl Plan {
    /// The layers of the shapes within `region`, those `fitted` bounds
    /// reach, on `printer`.
    pub fn new(printer: &Printer, region: &Box3, fitted: Option<&Fitted>) -> Result<Plan, String> {
        let display = &printer.display;
        let mut model = *region;
        if let Some(fitted) = fitted {
            for i in 0..3 {
                model.lower[i] = model.lower[i].max(fitted.lower[i].unwrap_or(f64::MIN));
                model.upper[i] = model.upper[i].min(fitted.upper[i].unwrap_or(f64::MAX));
            }
        }
        let extent = model.size();
        if extent.iter().any(|&e| e <= 0.0) {
            return Err("nothing to print: the shapes lie outside the bounds".into());
        }
        if extent[0] > display.size[0] || extent[1] > display.size[1] {
            return Err(format!(
                "the model is {:.2} by {:.2} mm, larger than the printer's display, {} by {}",
                extent[0], extent[1], display.size[0], display.size[1]
            ));
        }
        if extent[2] > printer.height {
            return Err(format!(
                "the model is {:.2} mm tall; the printer prints {} at most",
                extent[2], printer.height
            ));
        }

        // As PrusaSlicer draws a layer, from its top left: a portrait
        // display's columns run along y and its rows along x, and the
        // mirroring of columns flips with it.
        let portrait = display.orientation == Orientation::Portrait;
        let mut size = [0; 2];
        let mut to_model = Matrix3::zeros();
        to_model[(2, 2)] = 1.0;
        let mut footprint = [0..0, 0..0];
        let centre = model.center();
        let pitch = [0, 1].map(|axis| display.size[axis] / f64::from(display.pixels[axis]));
        for axis in 0..2 {
            let image_axis = usize::from(portrait) ^ axis;
            let backwards = match image_axis {
                0 => portrait != display.mirror[0],
                _ => !display.mirror[1],
            };
            let pixels = display.pixels[axis] as usize;
            let step = if backwards { -pitch[axis] } else { pitch[axis] };
            size[image_axis] = pixels;
            to_model[(axis, image_axis)] = step;
            to_model[(axis, 2)] = centre[axis] - step * pixels as f64 / 2.0;
            // Centred, the footprint reaches as far each way from the
            // middle of the image.
            let half = extent[axis] / pitch[axis] / 2.0;
            let middle = pixels as f64 / 2.0;
            footprint[image_axis] = ((middle - half).floor().max(0.0) as usize)
                ..((middle + half).ceil() as usize).min(pixels);
        }
        let height = printer.layer_height;
        Ok(Plan {
            size,
            footprint,
            to_model,
            pitch: (pitch[0] * pitch[1]).sqrt(),
            voxel: pitch[0] * pitch[1] * height,
            bottom: model.lower[2],
            layer_height: height,
            layers: (extent[2] / height).ceil() as usize,
        })
    }

    /// Layer `k`, sampled half way up it.  `None` once cancelled.
    fn layer(&self, shape: &Shape, k: usize, cancel: &CancelToken) -> io::Result<Option<Layer>> {
        let z = self.bottom + (k as f64 + 0.5) * self.layer_height;
        self.encode(|rows| self.band(shape, z, rows, cancel))
    }

    /// A layer with nothing on it.
    fn blank(&self) -> io::Result<Layer> {
        let width = self.footprint[0].len();
        let layer = self.encode(|rows| Some(vec![0; rows.len() * width]))?;
        Ok(layer.expect("a blank layer is never cancelled"))
    }

    /// The layer whose footprint `band` gives, a band of its rows at a
    /// time, as a greyscale PNG; `None` once `band` gives none.
    fn encode(
        &self,
        mut band: impl FnMut(Range<usize>) -> Option<Vec<u8>>,
    ) -> io::Result<Option<Layer>> {
        let [width, height] = self.size;
        let [columns, rows] = &self.footprint;
        let mut png = vec![];
        let mut encoder = png::Encoder::new(&mut png, width as u32, height as u32);
        encoder.set_color(png::ColorType::Grayscale);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        // Inside a layer, a row is mostly the one above it.
        encoder.set_filter(png::Filter::Up);
        let mut writer = encoder.write_header()?;
        let mut stream = writer.stream_writer()?;
        let mut row = vec![0; width];
        for _ in 0..rows.start {
            stream.write_all(&row)?;
        }
        let mut inside = 0;
        for start in rows.clone().step_by(BAND) {
            let Some(greys) = band(start..(start + BAND).min(rows.end)) else {
                return Ok(None);
            };
            for line in greys.chunks_exact(columns.len()) {
                row[columns.clone()].copy_from_slice(line);
                inside += line.iter().map(|&g| u64::from(g)).sum::<u64>();
                stream.write_all(&row)?;
            }
        }
        row.fill(0);
        for _ in rows.end..height {
            stream.write_all(&row)?;
        }
        stream.finish()?;
        writer.finish()?;
        Ok(Some(Layer {
            png,
            inside: inside as f64 / 255.0,
        }))
    }

    /// The greys of the footprint's columns on `rows` at `z`, row by row,
    /// or `None` once cancelled.
    fn band(
        &self,
        shape: &Shape,
        z: f64,
        rows: Range<usize>,
        cancel: &CancelToken,
    ) -> Option<Vec<u8>> {
        let columns = &self.footprint[0];
        let size = ImageSize::new(columns.len() as u32, rows.len() as u32);
        // fidget evaluates pixel (i, j) at the screen point (i, j), which
        // this takes to the centre of the image's pixel (i, j) of the band.
        #[rustfmt::skip]
        let to_image = Matrix3::new(
            1.0, 0.0, columns.start as f64 + 0.5,
            0.0, 1.0, rows.start as f64 + 0.5,
            0.0, 0.0, 1.0,
        );
        let world_to_screen = size
            .screen_to_world()
            .cast::<f64>()
            .try_inverse()
            .expect("a band has pixels");
        let config = pixel::RenderConfig {
            image_size: size,
            world_to_model: (self.to_model * to_image * world_to_screen).cast(),
            pixel_perfect: false,
            z: z as f32,
        };
        // The layers share the threads, a layer to each.
        let eval = pixel::EvalConfig {
            tile_sizes: None,
            threads: None,
            cancel: cancel.clone(),
        };
        let image = pixel::render(shape.clone(), &config, &eval)?;
        Some(image.take().0.into_iter().map(|p| self.grey(p)).collect())
    }

    /// The share of a pixel the shape covers, from the distance at its
    /// centre to the shape's edge, which is exact where the field is a
    /// distance and an edge straight across the pixel.
    fn grey(&self, pixel: RawDistancePixel) -> u8 {
        let covered = match pixel.unpack() {
            DistancePixel::Fill { inside, .. } => f64::from(u8::from(inside)),
            DistancePixel::Value(d) => (0.5 - f64::from(d) / self.pitch).clamp(0.0, 1.0),
        };
        // NaN, where the field has none, casts to 0, outside.
        (covered * 255.0).round() as u8
    }
}

/// A layer as the printer shows it, and the pixels it fills, the grey ones
/// in part.
struct Layer {
    png: Vec<u8>,
    inside: f64,
}

// --- Export ---

/// What a print holds.
pub struct Printed {
    pub layers: usize,
    /// In mm³
    pub volume: f64,
}

/// Writes the print of `shape` on `printer`, laid out by `plan`, to
/// `output` as an SL1 archive, or returns `None` once cancelled; a
/// cancelled export leaves `output` as it was.
///
/// Layers are sampled a batch at a time, a layer to each thread, and
/// written in order, so that only a batch's images are held at once.
/// Empty layers below the model are left out, as are those above it.
pub fn print(
    shape: &JitShape,
    plan: &Plan,
    printer: &Printer,
    output: &Path,
    job: &Job,
) -> Result<Option<Printed>, String> {
    let shape = scene::bound(shape.clone())?;
    (job.progress)(Stage::Layers);
    let name = output
        .file_stem()
        .map_or("print".into(), |stem| stem.to_string_lossy());
    let batch = 2 * job.threads.thread_count();
    let mut printed = Printed {
        layers: 0,
        volume: 0.0,
    };
    let mut empty = false;
    let written = render::write_atomically(output, |file| {
        let mut archive = sl1::Archive::new(file, &name);
        let mut blank = None;
        // Empty layers since the last one written
        let mut gap = 0;
        for start in (0..plan.layers).step_by(batch) {
            let layers: Option<Vec<Layer>> = job.threads.run(|| {
                (start..(start + batch).min(plan.layers))
                    .into_par_iter()
                    .map(|k| plan.layer(&shape, k, job.cancel))
                    .collect::<io::Result<_>>()
            })?;
            let Some(layers) = layers else {
                return Err(io::ErrorKind::Interrupted.into());
            };
            for layer in layers {
                if layer.inside == 0.0 {
                    gap += usize::from(archive.layers() > 0);
                    continue;
                }
                if gap > 0 {
                    let blank = match &blank {
                        Some(blank) => blank,
                        None => blank.insert(plan.blank()?),
                    };
                    for _ in 0..gap {
                        archive.layer(&blank.png)?;
                    }
                    gap = 0;
                }
                archive.layer(&layer.png)?;
                printed.volume += layer.inside * plan.voxel;
            }
        }
        printed.layers = archive.layers();
        if printed.layers == 0 {
            empty = true;
            return Err(io::ErrorKind::InvalidInput.into());
        }
        archive.finish(printer, printed.volume)
    });
    match written {
        Ok(()) => Ok(Some(printed)),
        Err(_) if job.cancel.is_cancelled() => Ok(None),
        Err(_) if empty => Err("nothing to print: no layer has the shapes on it".into()),
        Err(error) => Err(error),
    }
}

/// Writes the layer through `z` to `output` as a PNG, the image the
/// printer shows, or returns `None` once cancelled; otherwise the height
/// the layer starts at.
pub fn layer(
    shape: &JitShape,
    plan: &Plan,
    z: f64,
    output: &Path,
    job: &Job,
) -> Result<Option<f64>, String> {
    let k = ((z - plan.bottom) / plan.layer_height).floor();
    if !(0.0..plan.layers as f64).contains(&k) {
        return Err(format!(
            "no layer at {z}: the print reaches from {} to {}",
            plan.bottom,
            plan.bottom + plan.layers as f64 * plan.layer_height
        ));
    }
    let shape = scene::bound(shape.clone())?;
    (job.progress)(Stage::Layers);
    let layer = plan
        .layer(&shape, k as usize, job.cancel)
        .map_err(|error| error.to_string())?;
    let Some(layer) = layer else {
        return Ok(None);
    };
    render::write_atomically(output, |file| file.write_all(&layer.png))?;
    Ok(Some(plan.bottom + k * plan.layer_height))
}
