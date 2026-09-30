//! An image scaled down so neither edge passes a provider's limit, for
//! screenshots and photos albedo did not render itself. The aspect ratio is
//! kept; a JPEG stays a JPEG, anything else becomes a PNG.

use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{ImageFormat, ImageReader};
use std::io::Cursor;

pub struct Fitted {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub extension: &'static str,
}

pub fn fit(bytes: &[u8], edge: u32) -> Result<Fitted, String> {
    let reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let format = reader.format().ok_or("not a PNG, JPEG, or WebP image")?;
    let image = reader
        .decode()
        .map_err(|e| format!("cannot decode the image: {e}"))?;
    let (width, height) = scaled(image.width(), image.height(), edge);
    let resized = image.resize_exact(width, height, FilterType::Lanczos3);
    let mut out = Cursor::new(Vec::new());
    let extension = match format {
        ImageFormat::Jpeg => {
            JpegEncoder::new_with_quality(&mut out, 90)
                .encode_image(&resized.to_rgb8())
                .map_err(|e| e.to_string())?;
            "jpg"
        }
        _ => {
            resized
                .write_to(&mut out, ImageFormat::Png)
                .map_err(|e| e.to_string())?;
            "png"
        }
    };
    Ok(Fitted {
        bytes: out.into_inner(),
        width,
        height,
        extension,
    })
}

/// The size `width` × `height` shrinks to so its longer edge is `edge`; an
/// image already inside keeps its size.
fn scaled(width: u32, height: u32, edge: u32) -> (u32, u32) {
    let longer = width.max(height);
    if longer <= edge {
        return (width, height);
    }
    let shrink =
        |side: u32| ((side as u64 * edge as u64 + longer as u64 / 2) / longer as u64).max(1) as u32;
    (shrink(width), shrink(height))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_longer_edge_lands_on_the_limit() {
        assert_eq!(scaled(2304, 1212, 2000), (2000, 1052));
        assert_eq!(scaled(1000, 8000, 2000), (250, 2000));
        assert_eq!(scaled(1200, 800, 2000), (1200, 800));
        assert_eq!(scaled(9000, 1, 2000), (2000, 1));
    }
}
