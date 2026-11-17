// SPDX-License-Identifier: MPL-2.0

//! `text`: a string's outline in a font, sized and laid out as OpenSCAD
//! 2021.01's `text()` does, so that ported designs keep their dimensions.
//!
//! OpenSCAD draws outlines at an em of `size / 0.72`, and places glyphs by
//! metrics it scales by 1/1.024 less than that: advances, spacing and
//! alignment come out 2.3% tighter than the font's design.  Both are kept.

mod libfive;

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use fidget::context::Tree;
use harfrust::{Buffer, Direction, ShapeOptions, ShaperFont};
use i_overlay::core::fill_rule::FillRule;
use kurbo::BezPath;
use rhai::Map;
use skrifa::font::glyph::outline::{DrawOptions, PathSink};
use skrifa::{DrawMemory, Font, GlyphId};
use usvg::fontdb;

use crate::outline::{self, Contour};

/// The default font's file, when the build names one.
const DEFAULT_FONT: Option<&str> = option_env!("KEYCAP_SERVER_FONT");

/// The family looked up when the build names no default font: OpenSCAD's.
const DEFAULT_FAMILY: &str = "Liberation Sans";

/// OpenSCAD's em, in sizes
const EM: f64 = 1.0 / 0.72;

/// OpenSCAD's placement metrics, in ems
const METRIC: f64 = EM / 1.024;

/// Curves become lines no further than this from them, in sizes.
const TOLERANCE: f64 = 1e-3;

/// The fonts a script names: files, installed families and the built-in
/// libfive font.
#[derive(Default)]
pub struct Fonts {
    /// The installed fonts, read on the first lookup by name
    system: OnceLock<fontdb::Database>,
}

impl Fonts {
    /// The installed fonts, shared with SVG text.
    pub fn system(&self) -> &fontdb::Database {
        self.system.get_or_init(|| {
            let mut db = fontdb::Database::new();
            db.load_system_fonts();
            db
        })
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Halign {
    Left,
    Center,
    Right,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Valign {
    Baseline,
    Top,
    Center,
    Bottom,
}

/// `text`'s options, as its map gives them
pub struct Options {
    size: f64,
    font: Option<String>,
    halign: Halign,
    valign: Valign,
    spacing: f64,
}

impl Options {
    pub fn new(map: Option<Map>) -> Result<Self, String> {
        let mut options = Options {
            size: 10.0,
            font: None,
            halign: Halign::Left,
            valign: Valign::Baseline,
            spacing: 1.0,
        };
        for (key, value) in map.into_iter().flatten() {
            let number = || {
                value
                    .as_float()
                    .or_else(|_| value.as_int().map(|i| i as f64))
                    .map_err(|_| format!("text: {key} must be a number"))
            };
            let string = || {
                value
                    .clone()
                    .into_string()
                    .map_err(|_| format!("text: {key} must be a string"))
            };
            match key.as_str() {
                "size" => options.size = number()?,
                "spacing" => options.spacing = number()?,
                "font" => options.font = Some(string()?),
                "halign" => {
                    options.halign = match string()?.as_str() {
                        "left" => Halign::Left,
                        "center" => Halign::Center,
                        "right" => Halign::Right,
                        other => {
                            return Err(format!(
                                "text: halign is left, center or right, not {other:?}"
                            ));
                        }
                    }
                }
                "valign" => {
                    options.valign = match string()?.as_str() {
                        "baseline" => Valign::Baseline,
                        "top" => Valign::Top,
                        "center" => Valign::Center,
                        "bottom" => Valign::Bottom,
                        other => {
                            return Err(format!(
                                "text: valign is baseline, top, center or bottom, not {other:?}"
                            ));
                        }
                    }
                }
                other => {
                    return Err(format!(
                        "text: no option {other:?}; the options are size, font, halign, valign and spacing"
                    ));
                }
            }
        }
        if !(options.size.is_finite() && options.size > 0.0) {
            return Err(format!("text: size must be positive, not {}", options.size));
        }
        if !options.spacing.is_finite() {
            return Err("text: spacing must be a number".into());
        }
        Ok(options)
    }
}

/// A line of text laid out: glyph outlines in place, and where the
/// alignment puts them
struct Laid {
    contours: Vec<Contour>,
    /// The advances' total, before alignment
    width: f64,
    /// The highest and lowest points of the glyphs' boxes
    ascend: f64,
    descend: f64,
}

/// The outline of `string` with `options`, and the font file it read if a
/// script named it; a relative font file is found from `base`.
pub fn text(
    fonts: &Fonts,
    string: &str,
    options: &Options,
    base: &Path,
) -> Result<(Tree, Option<PathBuf>), String> {
    if options.font.as_deref() == Some("libfive") {
        return Ok((libfive::text(string, options), None));
    }
    let (font, file) = load(fonts, options.font.as_deref(), base)?;
    let laid = lay_out(&font, string, options)?;
    let dx = match options.halign {
        Halign::Left => 0.0,
        Halign::Center => -laid.width / 2.0,
        Halign::Right => -laid.width,
    };
    let dy = valign(options.valign, laid.ascend, laid.descend);
    let moved: Vec<Contour> = laid
        .contours
        .iter()
        .map(|c| c.iter().map(|p| [p[0] + dx, p[1] + dy]).collect())
        .collect();
    let contours = outline::clean(&moved, FillRule::NonZero);
    Ok((outline::field(&contours), file))
}

/// OpenSCAD's vertical offset for an alignment.
fn valign(valign: Valign, ascend: f64, descend: f64) -> f64 {
    match valign {
        Valign::Baseline => 0.0,
        Valign::Top => -ascend,
        Valign::Center => (descend - ascend) / 2.0,
        Valign::Bottom => descend,
    }
}

// --- Fonts ---

/// The font `name` names: a file if it looks like a path, the default font
/// if there is no name, an installed font otherwise.  Also the file, when
/// it is one a script named.
fn load(fonts: &Fonts, name: Option<&str>, base: &Path) -> Result<(Font, Option<PathBuf>), String> {
    let is_file = |n: &str| {
        let lower = n.to_ascii_lowercase();
        n.contains('/')
            || [".ttf", ".otf", ".ttc", ".otc"]
                .iter()
                .any(|e| lower.ends_with(e))
    };
    match name {
        Some(name) if is_file(name) => {
            let path = base.join(name);
            let path = path.canonicalize().unwrap_or(path);
            let font = read(&path)?;
            Ok((font, Some(path)))
        }
        Some(name) => Ok((installed(fonts, name)?, None)),
        None => {
            if let Some(path) = DEFAULT_FONT.map(Path::new).filter(|p| p.is_file()) {
                return Ok((read(path)?, None));
            }
            installed(fonts, DEFAULT_FAMILY)
                .map(|font| (font, None))
                .map_err(|_| {
                    format!(
                        "text: no default font; {DEFAULT_FAMILY} is not installed, so give a font"
                    )
                })
        }
    }
}

fn read(path: &Path) -> Result<Font, String> {
    let data = std::fs::read(path)
        .map_err(|error| format!("text: cannot read the font {}: {error}", path.display()))?;
    Font::new(data, 0).ok_or_else(|| format!("text: {} is not a font", path.display()))
}

/// The installed font `name` names, as OpenSCAD names fonts through
/// fontconfig: a family, then `:`-separated properties such as `bold` or
/// `style=Light Italic`.
fn installed(fonts: &Fonts, name: &str) -> Result<Font, String> {
    let mut parts = name.split(':');
    let family = parts.next().unwrap_or_default().trim();
    let mut query = fontdb::Query {
        families: &[fontdb::Family::Name(family)],
        ..fontdb::Query::default()
    };
    for part in parts {
        let words = part.trim().strip_prefix("style=").unwrap_or(part);
        for word in words.split_whitespace() {
            style_word(&mut query, &word.to_ascii_lowercase());
        }
    }
    // The family's face nearest the style, as fontconfig picks it
    let db = fonts.system();
    let id = db
        .query(&query)
        .ok_or_else(|| format!("text: no installed font is {name:?}"))?;
    db.with_face_data(id, |data, index| Font::new(data.to_vec(), index))
        .flatten()
        .ok_or_else(|| format!("text: cannot read the font {name:?}"))
}

/// Applies one word of a fontconfig style to `query`; words it does not
/// know are left out, as fontconfig leaves out what it cannot match.
fn style_word(query: &mut fontdb::Query, word: &str) {
    use fontdb::{Stretch, Style, Weight};
    let weight = match word {
        "thin" | "hairline" => Some(Weight::THIN),
        "extralight" | "ultralight" => Some(Weight::EXTRA_LIGHT),
        "light" => Some(Weight::LIGHT),
        "regular" | "normal" | "book" => Some(Weight::NORMAL),
        "medium" => Some(Weight::MEDIUM),
        "semibold" | "demibold" => Some(Weight::SEMIBOLD),
        "bold" => Some(Weight::BOLD),
        "extrabold" | "ultrabold" => Some(Weight::EXTRA_BOLD),
        "black" | "heavy" => Some(Weight::BLACK),
        _ => None,
    };
    if let Some(weight) = weight {
        query.weight = weight;
    }
    match word {
        "italic" => query.style = Style::Italic,
        "oblique" => query.style = Style::Oblique,
        "ultracondensed" => query.stretch = Stretch::UltraCondensed,
        "extracondensed" => query.stretch = Stretch::ExtraCondensed,
        "condensed" => query.stretch = Stretch::Condensed,
        "semicondensed" => query.stretch = Stretch::SemiCondensed,
        "semiexpanded" | "semiextended" => query.stretch = Stretch::SemiExpanded,
        "expanded" | "extended" => query.stretch = Stretch::Expanded,
        "extraexpanded" | "extraextended" => query.stretch = Stretch::ExtraExpanded,
        "ultraexpanded" | "ultraextended" => query.stretch = Stretch::UltraExpanded,
        _ => {}
    }
}

// --- Layout ---

/// Shapes `string` left to right, as OpenSCAD's HarfBuzz does, and places
/// its glyphs' outlines.
fn lay_out(font: &Font, string: &str, options: &Options) -> Result<Laid, String> {
    let upem = f64::from(font.units_per_em());
    let outline_scale = options.size * EM / upem;
    let metric_scale = options.size * METRIC / upem;

    let shaper = ShaperFont::new(font);
    let mut buffer = Buffer::new();
    buffer.push_str(string);
    buffer.set_direction(Direction::LeftToRight);
    buffer.guess_segment_properties();
    harfrust::shape(&shaper, &mut buffer, ShapeOptions::new())
        .map_err(|error| format!("text: cannot shape {string:?}: {error:?}"))?;

    let outlines = font.outline_glyphs();
    let tolerance = TOLERANCE / EM * upem;
    let mut laid = Laid {
        contours: vec![],
        width: 0.0,
        ascend: 0.0,
        descend: 0.0,
    };
    let mut pen = 0.0;
    for (info, position) in buffer.glyph_infos().iter().zip(buffer.glyph_positions()) {
        let mut path = Glyph::default();
        if let Some(glyph) = outlines.get(GlyphId::new(info.glyph_id)) {
            glyph
                .draw(&DrawOptions::default(), DrawMemory::Scratch, &mut path)
                .map_err(|error| format!("text: cannot draw a glyph of {string:?}: {error:?}"))?;
        }
        // OpenSCAD aligns by the glyphs' control boxes, in its metrics.
        if let Some([_, lower, _, upper]) = path.cbox {
            laid.ascend = laid.ascend.max(upper * metric_scale);
            laid.descend = laid.descend.max(-lower * metric_scale);
        }
        let x = (pen + f64::from(position.x_offset)) * metric_scale;
        let y = f64::from(position.y_offset) * metric_scale;
        // A fill closes what a glyph leaves open.
        let (mut closed, open) = outline::flatten(&path.path, tolerance);
        closed.extend(open);
        laid.contours.extend(closed.into_iter().map(|c| {
            c.into_iter()
                .map(|p| [x + p[0] * outline_scale, y + p[1] * outline_scale])
                .collect()
        }));
        pen += f64::from(position.x_advance) * options.spacing;
    }
    laid.width = pen * metric_scale;
    Ok(laid)
}

/// A glyph's outline, and the box around its points, control points too
#[derive(Default)]
struct Glyph {
    path: BezPath,
    cbox: Option<[f64; 4]>,
}

impl Glyph {
    fn point(&mut self, x: f32, y: f32) -> kurbo::Point {
        let (x, y) = (f64::from(x), f64::from(y));
        let b = self.cbox.get_or_insert([x, y, x, y]);
        *b = [b[0].min(x), b[1].min(y), b[2].max(x), b[3].max(y)];
        kurbo::Point::new(x, y)
    }
}

impl PathSink for Glyph {
    fn move_to(&mut self, x: f32, y: f32) {
        let p = self.point(x, y);
        self.path.move_to(p);
    }

    fn line_to(&mut self, x: f32, y: f32) {
        let p = self.point(x, y);
        self.path.line_to(p);
    }

    fn quad_to(&mut self, cx0: f32, cy0: f32, x: f32, y: f32) {
        let c = self.point(cx0, cy0);
        let p = self.point(x, y);
        self.path.quad_to(c, p);
    }

    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        let c0 = self.point(cx0, cy0);
        let c1 = self.point(cx1, cy1);
        let p = self.point(x, y);
        self.path.curve_to(c0, c1, p);
    }

    fn close(&mut self) {
        self.path.close_path();
    }
}
