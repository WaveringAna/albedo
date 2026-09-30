//! Dense 1-bit pixel-font text frames on a fixed grid, bundled X11 8x13.

use std::collections::HashMap;
use std::sync::OnceLock;

const FONT: &[u8] = include_bytes!("../fonts/8x13.bdf");
const MARGIN: usize = 0;

/// The 8x13 font box's 11px ascent; extra pitch leading sits below it.
const BASELINE: usize = 11;
const MAX_EDGE: usize = 8000;

pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub png: Vec<u8>,
}

struct Glyph {
    width: usize,
    height: usize,
    off_x: i32,
    off_y: i32,
    /// One packed bit row per glyph row; column c is bit (width-1-c).
    rows: Vec<u16>,
}

struct Bdf {
    glyphs: HashMap<u32, Glyph>,
}

fn bdf() -> &'static Bdf {
    static BDF: OnceLock<Bdf> = OnceLock::new();
    BDF.get_or_init(|| parse_bdf(FONT).expect("bundled 8x13.bdf parses"))
}

fn parse_bdf(bytes: &[u8]) -> Result<Bdf, String> {
    let text = std::str::from_utf8(bytes).map_err(|e| e.to_string())?;
    let mut glyphs = HashMap::new();
    let mut encoding: Option<u32> = None;
    let mut box_: Option<(usize, usize, i32, i32)> = None;
    let mut bitmap: Option<Vec<u16>> = None;
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        match fields.next() {
            Some("ENCODING") => {
                encoding = fields
                    .next()
                    .and_then(|n| n.parse::<i64>().ok())
                    .and_then(|n| {
                        if (0..=0x10FFFF).contains(&n) {
                            Some(n as u32)
                        } else {
                            None
                        }
                    });
            }
            Some("BBX") => {
                let mut number = || fields.next().and_then(|n| n.parse::<i64>().ok());
                box_ = match (number(), number(), number(), number()) {
                    (Some(w), Some(h), Some(x), Some(y)) if w > 0 && h > 0 => {
                        Some((w as usize, h as usize, x as i32, y as i32))
                    }
                    _ => None,
                };
            }
            Some("BITMAP") => {
                let (w, h, x, y) = box_.ok_or("BITMAP without a BBX")?;
                bitmap = Some(Vec::with_capacity(h));
                let _ = (w, x, y);
            }
            Some("ENDCHAR") => {
                if let (Some(code), Some((w, h, x, y)), Some(rows)) =
                    (encoding, box_, bitmap.take())
                {
                    if rows.len() == h {
                        glyphs.insert(
                            code,
                            Glyph {
                                width: w,
                                height: h,
                                off_x: x,
                                off_y: y,
                                rows,
                            },
                        );
                    }
                }
                encoding = None;
                box_ = None;
            }
            Some(hex) if bitmap.is_some() && !hex.is_empty() => {
                if let Some(row) = bitmap.as_mut() {
                    row.push(parse_hex_row(hex));
                }
            }
            _ => {}
        }
    }
    if glyphs.is_empty() {
        return Err("no glyphs in the bundled font".into());
    }
    Ok(Bdf { glyphs })
}

/// Hex bitmap bytes packed big-endian into one bit row (fonts here are
/// <= 16 wide). Column c of a glyph of BBX width w is bit
/// `(w + 7) / 8 * 8 - 1 - c` of the row.
fn parse_hex_row(hex: &str) -> u16 {
    let mut row = 0u16;
    for i in 0..hex.len() / 2 {
        match u16::from_str_radix(&hex[2 * i..2 * i + 2], 16) {
            Ok(byte) => row = (row << 8) | byte,
            Err(_) => return row,
        }
    }
    row
}

pub fn render(text: &str, advance: usize, pitch: usize, width: usize) -> Result<Frame, String> {
    let (width, height, pixels) = paint(text, advance, pitch, width)?;
    encode(width, height, pixels)
}

fn paint(
    text: &str,
    advance: usize,
    pitch: usize,
    width: usize,
) -> Result<(usize, usize, Vec<u8>), String> {
    if !(6..=24).contains(&advance) {
        return Err(format!("advance must be 6 to 24, not {advance}"));
    }
    if !(10..=64).contains(&pitch) {
        return Err(format!("pitch must be 10 to 64, not {pitch}"));
    }
    if !(256..=4096).contains(&width) || width < 2 * MARGIN + advance {
        return Err(format!("width must be 256 to 4096, not {width}"));
    }
    let columns = (width - 2 * MARGIN) / advance;
    let font = &bdf().glyphs;
    let question = font.get(&u32::from(b'?')).ok_or("the font lacks '?'")?;

    let mut rows: Vec<Vec<char>> = Vec::new();
    for line in text.split('\n') {
        let chars: Vec<char> = line.chars().collect();
        if chars.is_empty() {
            rows.push(Vec::new());
            continue;
        }
        for chunk in chars.chunks(columns) {
            rows.push(chunk.to_vec());
        }
    }
    if rows.is_empty() {
        rows.push(Vec::new());
    }
    let height = 2 * MARGIN + rows.len() * pitch;
    if height > MAX_EDGE {
        return Err(format!(
            "{height}px exceeds the {MAX_EDGE}px image edge; chunk the text into smaller frames"
        ));
    }
    let mut pixels = vec![255u8; width * height];
    for (index, row) in rows.iter().enumerate() {
        let top = MARGIN + index * pitch;
        for (column, ch) in row.iter().enumerate() {
            let cell = MARGIN + column * advance;
            // U+2588 marks a newline: fill the whole cell box with ink.
            if *ch as u32 == 0x2588 {
                for py in top..top + pitch {
                    for px in cell..cell + advance {
                        if px < width && py < height {
                            pixels[py * width + px] = 0;
                        }
                    }
                }
                continue;
            }
            let glyph = font.get(&(*ch as u32)).unwrap_or(question);
            let x = cell as isize + glyph.off_x as isize;
            let baseline = (top + BASELINE) as isize;
            let glyph_top = baseline - (glyph.height as isize + glyph.off_y as isize);
            let byte_bits = 8 * ((glyph.width + 7) / 8);
            for (r, bits) in glyph.rows.iter().enumerate() {
                for c in 0..glyph.width {
                    if bits & (1 << (byte_bits - 1 - c)) != 0 {
                        let px = x + c as isize;
                        let py = glyph_top + r as isize;
                        if px >= 0 && py >= 0 && (px as usize) < width && (py as usize) < height {
                            pixels[py as usize * width + px as usize] = 0;
                        }
                    }
                }
            }
        }
    }

    Ok((width, height, pixels))
}

fn encode(width: usize, height: usize, pixels: Vec<u8>) -> Result<Frame, String> {
    // One bit per pixel, MSB first: ink is the 0 bit, white the 1 bit.
    let stride = (width + 7) / 8;
    let mut bits = vec![0xFFu8; stride * height];
    for (y, row) in pixels.chunks(width).enumerate() {
        for (x, ink) in row.iter().enumerate() {
            if *ink < 128 {
                bits[y * stride + x / 8] &= !(0x80 >> (x % 8));
            }
        }
    }
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
    encoder.set_color(png::ColorType::Grayscale);
    encoder.set_depth(png::BitDepth::One);
    encoder.set_compression(png::Compression::High);
    let mut writer = encoder.write_header().expect("header fits in memory");
    writer
        .write_image_data(&bits)
        .expect("pixels match the header");
    drop(writer);
    Ok(Frame {
        width: width as u32,
        height: height as u32,
        png: out,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ink(text: &str) -> usize {
        let (_, _, pixels) = paint(text, 11, 16, 1568).unwrap();
        pixels.iter().filter(|&&p| p < 128).count()
    }

    #[test]
    fn glyphs_leave_ink() {
        assert!(ink("hello world") > 50, "text must leave ink");
        assert_eq!(ink(""), 0);
        assert!(ink("A") > 5, "one glyph leaves ink");
    }

    #[test]
    fn full_block_fills_its_whole_cell() {
        let (width, height, pixels) = paint("\u{2588}", 11, 16, 1568).unwrap();
        assert_eq!((width, height), (1568, 16));
        let ink = pixels.iter().filter(|&&p| p < 128).count();
        assert_eq!(ink, 11 * 16, "the block fills exactly one cell box");
    }

    #[test]
    fn every_ascii_glyph_leaves_ink() {
        let text: String = (0x21u32..=0x7e)
            .map(|c| char::from_u32(c).unwrap())
            .collect();
        assert!(ink(&text) > 1000, "the printable ASCII range is covered");
    }
}
