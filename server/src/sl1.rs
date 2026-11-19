// SPDX-License-Identifier: MPL-2.0

//! Prusa SL1 archives, as PrusaSlicer writes them for the SL1 and SL1S: a
//! zip of each layer's PNG, named after the job, and of the settings the
//! printer and UVtools read, in PrusaSlicer's keys.  UVtools converts them
//! to other printers' formats.

use std::io::{self, Write};

use crate::resin::{Orientation, Printer};
use crate::zip::Zip;

/// The printer finds its layers by name, in order, as five digits.
const MAX_LAYERS: usize = 100_000;

pub struct Archive<W: Write> {
    zip: Zip<W>,
    job: String,
    layers: usize,
}

impl<W: Write> Archive<W> {
    pub fn new(out: W, job: &str) -> Self {
        Archive {
            zip: Zip::new(out),
            job: job.to_owned(),
            layers: 0,
        }
    }

    /// Adds the next layer, a greyscale PNG.
    pub fn layer(&mut self, png: &[u8]) -> io::Result<()> {
        if self.layers == MAX_LAYERS {
            return Err(io::Error::other(format!(
                "an SL1 archive holds at most {MAX_LAYERS} layers"
            )));
        }
        self.zip
            .add(&format!("{}{:05}.png", self.job, self.layers), png)?;
        self.layers += 1;
        Ok(())
    }

    pub fn layers(&self) -> usize {
        self.layers
    }

    /// Writes the settings of a print of `volume` mm³ on `printer`, and
    /// closes the archive.
    pub fn finish(mut self, printer: &Printer, volume: f64) -> io::Result<()> {
        let display = &printer.display;
        let flag = |on: bool| if on { "1" } else { "0" };
        let config = [
            ("action", "print".to_owned()),
            ("jobDir", self.job.clone()),
            ("expTime", printer.exposure.to_string()),
            ("expTimeFirst", printer.bottom_exposure.to_string()),
            ("layerHeight", printer.layer_height.to_string()),
            ("numFade", printer.bottom_layers.to_string()),
            ("numFast", self.layers.to_string()),
            ("numSlow", "0".to_owned()),
            ("printerModel", printer.model.clone()),
            ("printerVariant", "default".to_owned()),
            // In ml
            ("usedMaterial", format!("{:.3}", volume / 1000.0)),
        ];
        let orientation = match display.orientation {
            Orientation::Landscape => "landscape",
            Orientation::Portrait => "portrait",
        };
        let slicer = [
            ("display_height", display.size[1].to_string()),
            ("display_mirror_x", flag(display.mirror[0]).to_owned()),
            ("display_mirror_y", flag(display.mirror[1]).to_owned()),
            ("display_orientation", orientation.to_owned()),
            ("display_pixels_x", display.pixels[0].to_string()),
            ("display_pixels_y", display.pixels[1].to_string()),
            ("display_width", display.size[0].to_string()),
            ("exposure_time", printer.exposure.to_string()),
            ("faded_layers", printer.bottom_layers.to_string()),
            // Anti-aliased, its greys as they are
            ("gamma_correction", "1".to_owned()),
            ("initial_exposure_time", printer.bottom_exposure.to_string()),
            ("initial_layer_height", printer.layer_height.to_string()),
            ("layer_height", printer.layer_height.to_string()),
            ("max_print_height", printer.height.to_string()),
            ("printer_model", printer.model.clone()),
            // The name UVtools gives the printer it converts for
            ("printer_settings_id", printer.model.clone()),
            // PrusaSlicer escapes the lines' breaks.
            ("printer_notes", printer.notes.join("\\n")),
        ];
        self.zip.add("config.ini", ini(&config).as_bytes())?;
        self.zip.add("prusaslicer.ini", ini(&slicer).as_bytes())?;
        self.zip.finish()?;
        Ok(())
    }
}

fn ini(entries: &[(&str, String)]) -> String {
    entries
        .iter()
        .map(|(key, value)| format!("{key} = {value}\n"))
        .collect()
}
