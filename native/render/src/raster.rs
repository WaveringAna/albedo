//! Rows of glyphs drawn onto an RGB canvas and encoded as PNG.

use crate::layout::Row;
use arborium_theme::theme::Color;
use fontdue::{Font, FontSettings, Metrics};
use std::collections::HashMap;

const FONT: &[u8] = include_bytes!("../fonts/JetBrainsMonoNL-Medium.ttf");
/// Large enough to stay legible after a provider scales an 80-row page down.
const FONT_PX: f32 = 16.0;
const PADDING: usize = 12;

pub struct Painter {
    font: Font,
    cache: HashMap<char, (Metrics, Vec<u8>)>,
    cell: usize,
    row: usize,
    baseline: usize,
}

pub struct Page<'a> {
    pub rows: &'a [Row],
    /// Cells left of the code, so every page of one view aligns.
    pub gutter: usize,
    /// False for text whose own line numbers are not the source's, like a diff.
    pub numbers: bool,
    pub columns: usize,
    pub foreground: Color,
    pub background: Color,
}

impl Painter {
    pub fn new() -> Painter {
        let font = Font::from_bytes(FONT, FontSettings::default()).expect("bundled font parses");
        let line = font
            .horizontal_line_metrics(FONT_PX)
            .expect("bundled font is horizontal");
        let cell = font.metrics('M', FONT_PX).advance_width.ceil() as usize;
        let row = (FONT_PX * 1.4).ceil() as usize;
        let glyph = line.ascent - line.descent;
        let baseline = ((row as f32 - glyph) / 2.0 + line.ascent).round() as usize;
        Painter {
            font,
            cache: HashMap::new(),
            cell,
            row,
            baseline,
        }
    }

    pub fn png(&mut self, page: &Page) -> Vec<u8> {
        let (width, height, pixels) = self.paint(page);
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Balanced);
        let mut writer = encoder.write_header().expect("header fits in memory");
        writer
            .write_image_data(&pixels)
            .expect("pixels match the header");
        drop(writer);
        out
    }

    fn paint(&mut self, page: &Page) -> (usize, usize, Vec<u8>) {
        // the gutter, a gap holding the separator, then the code.
        let code_x = PADDING + (page.gutter + 2) * self.cell;
        let width = code_x + page.columns * self.cell + PADDING;
        let height = 2 * PADDING + page.rows.len().max(1) * self.row;
        let mut canvas = Canvas {
            width,
            pixels: vec![0; width * height * 3],
        };
        canvas.fill(0, 0, width, height, page.background);
        let number = mix(page.foreground, page.background, 0.5);
        let rule = mix(page.foreground, page.background, 0.85);
        let x = PADDING + (page.gutter + 1) * self.cell;
        canvas.fill(x, PADDING, 1, height - 2 * PADDING, rule);
        for (index, row) in page.rows.iter().enumerate() {
            let top = PADDING + index * self.row;
            // A wrapped line's later rows say so, since they start at column 0.
            let label = match (row.continued, page.numbers) {
                (true, _) => "↪".to_string(),
                (false, true) => row.line.to_string(),
                (false, false) => String::new(),
            };
            let first = page.gutter.saturating_sub(label.chars().count());
            for (offset, ch) in label.chars().enumerate() {
                let x = PADDING + (first + offset) * self.cell;
                self.glyph(&mut canvas, x, top, ch, number);
            }
            for glyph in &row.glyphs {
                self.glyph(
                    &mut canvas,
                    code_x + glyph.column * self.cell,
                    top,
                    glyph.ch,
                    glyph.color,
                );
            }
        }
        (width, height, canvas.pixels)
    }

    fn glyph(&mut self, canvas: &mut Canvas, x: usize, top: usize, ch: char, color: Color) {
        let font = &self.font;
        let (metrics, coverage) = self
            .cache
            .entry(ch)
            .or_insert_with(|| font.rasterize(ch, FONT_PX));
        let left = x as i32 + metrics.xmin;
        let top = (top + self.baseline) as i32 - metrics.height as i32 - metrics.ymin;
        for row in 0..metrics.height {
            for column in 0..metrics.width {
                let alpha = coverage[row * metrics.width + column];
                if alpha > 0 {
                    canvas.blend(left + column as i32, top + row as i32, color, alpha);
                }
            }
        }
    }
}

struct Canvas {
    width: usize,
    pixels: Vec<u8>,
}

impl Canvas {
    fn fill(&mut self, x: usize, y: usize, width: usize, height: usize, color: Color) {
        for row in y..y + height {
            for column in x..x + width {
                let at = (row * self.width + column) * 3;
                self.pixels[at..at + 3].copy_from_slice(&[color.r, color.g, color.b]);
            }
        }
    }

    /// Glyphs may overhang their cell; anything off the canvas is dropped.
    fn blend(&mut self, x: i32, y: i32, color: Color, alpha: u8) {
        let height = self.pixels.len() / 3 / self.width;
        if x < 0 || y < 0 || x as usize >= self.width || y as usize >= height {
            return;
        }
        let at = (y as usize * self.width + x as usize) * 3;
        let alpha = alpha as u32;
        for (channel, value) in [color.r, color.g, color.b].into_iter().enumerate() {
            let under = self.pixels[at + channel] as u32;
            self.pixels[at + channel] =
                ((value as u32 * alpha + under * (255 - alpha)) / 255) as u8;
        }
    }
}

/// `color` moved `amount` of the way toward `toward`.
fn mix(color: Color, toward: Color, amount: f32) -> Color {
    let channel = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * amount).round() as u8;
    Color::new(
        channel(color.r, toward.r),
        channel(color.g, toward.g),
        channel(color.b, toward.b),
    )
}
