//! albedo-render: a highlighted range of a source file as PNG pages.
//!
//! albedo-render FILE --start N --end N --out DIR [--columns 79]
//!     [--tab-width 4] [--language NAME] [--max-rows 80] [--max-images 4]
//!     [--no-line-numbers]
//!
//! Writes DIR/view-1.png onward and prints one line per fact, for the caller
//! to parse from text output:
//!
//!   language rust            (or: language plain [reason])
//!   image DIR/view-1.png FIRST LAST WIDTHxHEIGHT
//!   remaining FIRST LAST     (lines left for another call, if any)
//!
//! A line split across pages appears in both. Errors go to stderr, exit 1.
//!
//! albedo-render --snapcompact[-dir] PATH --out DIR --advance N --pitch N
//!     --width N: dense pixel-font frames, one `image PATH WxH` stdout line
//!     per frame. Unknown glyphs render as '?'.
//!
//! albedo-render --fit EDGE IMAGE --out DIR: IMAGE (PNG, JPEG, or WebP)
//!     scaled so neither edge passes EDGE, written to DIR/fit.png (or
//!     fit.jpg for a JPEG), with one `image PATH WxH` stdout line.

mod fit;
mod grid;
mod highlight;
mod layout;
mod raster;

use highlight::{Colors, Language};
use std::path::PathBuf;
use std::process::ExitCode;

const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;

struct Request {
    file: PathBuf,
    start: usize,
    end: usize,
    out: PathBuf,
    columns: usize,
    tab_width: usize,
    language: Option<String>,
    max_rows: usize,
    max_images: usize,
    line_numbers: bool,
    snapcompact: bool,
    snapcompact_dir: bool,
    advance: usize,
    pitch: usize,
    frame_width: usize,
    fit: Option<u32>,
}

fn main() -> ExitCode {
    let parsed = parse(std::env::args().skip(1));
    match parsed.and_then(|request| {
        if let Some(edge) = request.fit {
            run_fit(&request, edge)
        } else if request.snapcompact && request.snapcompact_dir {
            run_snapcompact_dir(&request)
        } else if request.snapcompact {
            run_snapcompact(&request)
        } else {
            run(&request)
        }
    }) {
        Ok(report) => {
            print!("{report}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("albedo-render: {message}");
            ExitCode::FAILURE
        }
    }
}

fn parse(mut args: impl Iterator<Item = String>) -> Result<Request, String> {
    let mut file = None;
    let mut request = Request {
        file: PathBuf::new(),
        start: 0,
        end: 0,
        out: PathBuf::new(),
        columns: 79,
        tab_width: 4,
        language: None,
        max_rows: 80,
        max_images: 4,
        line_numbers: true,
        snapcompact: false,
        snapcompact_dir: false,
        advance: 11,
        pitch: 16,
        frame_width: 1568,
        fit: None,
    };
    let mut out = None;
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or(format!("{arg} needs a value"));
        let mut number = |low: usize, high: usize| -> Result<usize, String> {
            let text = value()?;
            match text.parse::<usize>() {
                Ok(n) if (low..=high).contains(&n) => Ok(n),
                _ => Err(format!(
                    "{arg} must be an integer from {low} to {high}, not {text:?}"
                )),
            }
        };
        match arg.as_str() {
            "--start" => request.start = number(1, usize::MAX)?,
            "--end" => request.end = number(1, usize::MAX)?,
            "--columns" => request.columns = number(20, 400)?,
            "--tab-width" => request.tab_width = number(1, 16)?,
            "--max-rows" => request.max_rows = number(1, 1000)?,
            "--max-images" => request.max_images = number(1, 64)?,
            "--language" => request.language = Some(value()?),
            "--no-line-numbers" => request.line_numbers = false,
            "--snapcompact" => request.snapcompact = true,
            "--snapcompact-dir" => {
                request.snapcompact = true;
                request.snapcompact_dir = true;
            }
            "--advance" => request.advance = number(6, 24)?,
            "--pitch" => request.pitch = number(10, 64)?,
            "--width" => request.frame_width = number(256, 4096)?,
            "--fit" => request.fit = Some(number(16, 16384)? as u32),
            "--out" => out = Some(PathBuf::from(value()?)),
            flag if flag.starts_with("--") => return Err(format!("unknown option {flag}")),
            _ if file.is_none() => file = Some(PathBuf::from(arg)),
            _ => return Err(format!("unexpected argument {arg:?}")),
        }
    }
    request.file = file.ok_or("a file to render is required")?;
    request.out = out.ok_or("--out DIR is required")?;
    if request.fit.is_some() || request.snapcompact {
        if !request.snapcompact_dir && !request.file.is_file() {
            return Err(format!("{}: not a file", request.file.display()));
        }
        return Ok(request);
    }
    if request.start == 0 || request.end == 0 {
        return Err("--start and --end are required".into());
    }
    if request.end < request.start {
        return Err(format!(
            "--end {} is before --start {}",
            request.end, request.start
        ));
    }
    Ok(request)
}

/// One subprocess for all frames: the bundled BDF is parsed once and each
/// NN.txt in the input dir renders, in name order, to snap-N.png.
fn run_snapcompact_dir(request: &Request) -> Result<String, String> {
    if !request.file.is_dir() {
        return Err(format!("{}: not a directory", request.file.display()));
    }
    let mut names: Vec<PathBuf> = std::fs::read_dir(&request.file)
        .map_err(|e| format!("{}: {e}", request.file.display()))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().is_some_and(|e| e == "txt"))
        .collect();
    names.sort();
    if names.is_empty() {
        return Err(format!("{}: no .txt chunks", request.file.display()));
    }
    let mut report = String::new();
    for (index, path) in names.iter().enumerate() {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let frame = grid::render(&text, request.advance, request.pitch, request.frame_width)?;
        let out = request.out.join(format!("snap-{}.png", index + 1));
        std::fs::write(&out, &frame.png).map_err(|e| format!("{}: {e}", out.display()))?;
        report.push_str(&format!(
            "image {} {}x{}\n",
            out.display(),
            frame.width,
            frame.height
        ));
    }
    Ok(report)
}

fn run_fit(request: &Request, edge: u32) -> Result<String, String> {
    let bytes =
        std::fs::read(&request.file).map_err(|e| format!("{}: {e}", request.file.display()))?;
    let fitted = fit::fit(&bytes, edge)?;
    let path = request.out.join(format!("fit.{}", fitted.extension));
    std::fs::write(&path, &fitted.bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!(
        "image {} {}x{}\n",
        path.display(),
        fitted.width,
        fitted.height
    ))
}

fn run_snapcompact(request: &Request) -> Result<String, String> {
    let text = std::fs::read_to_string(&request.file)
        .map_err(|e| format!("{}: {e}", request.file.display()))?;
    let frame = grid::render(&text, request.advance, request.pitch, request.frame_width)?;
    let path = request.out.join("snap-1.png");
    std::fs::write(&path, &frame.png).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!(
        "image {} {}x{}\n",
        path.display(),
        frame.width,
        frame.height
    ))
}

fn run(request: &Request) -> Result<String, String> {
    let shown = request.file.display();
    let size = std::fs::metadata(&request.file)
        .map_err(|e| format!("{shown}: {e}"))?
        .len();
    if size > MAX_FILE_BYTES {
        return Err(format!(
            "{shown} is {size} bytes; at most {MAX_FILE_BYTES} can be rendered"
        ));
    }
    let bytes = std::fs::read(&request.file).map_err(|e| format!("{shown}: {e}"))?;
    if bytes[..bytes.len().min(8192)].contains(&0) {
        return Err(format!("{shown} looks binary (it contains NUL bytes)"));
    }
    let source = String::from_utf8_lossy(&bytes);
    let lines = layout::lines(&source);
    if request.start > lines.len() {
        return Err(format!(
            "{shown} has {} lines; --start {} is past the end",
            lines.len(),
            request.start
        ));
    }
    let end = request.end.min(lines.len());

    let language = request
        .language
        .clone()
        .or_else(|| arborium::detect_language(&request.file.to_string_lossy()).map(String::from));
    let colors = Colors::new(
        &source,
        language.as_deref(),
        &arborium_theme::theme::builtin::github_light(),
    );
    let selected = &lines[request.start - 1..end];
    let rows = layout::rows(
        selected,
        request.start,
        &colors,
        request.columns,
        request.tab_width,
    );
    let pages = layout::pages(&rows, request.max_rows);

    let mut report = match &colors.language {
        Language::Highlighted(name) => format!("language {name}\n"),
        Language::Unsupported(name) => format!("language plain no grammar for {name}\n"),
        Language::Failed(message) => format!("language plain {message}\n"),
        Language::Unknown => "language plain unknown file type\n".to_string(),
    };
    let mut painter = raster::Painter::new();
    let gutter = match request.line_numbers {
        true => end.to_string().len(),
        false => 1,
    };
    for (index, range) in pages.iter().take(request.max_images).enumerate() {
        let page = &rows[range.clone()];
        let path = request.out.join(format!("view-{}.png", index + 1));
        let png = painter.png(&raster::Page {
            rows: page,
            gutter,
            numbers: request.line_numbers,
            columns: request.columns,
            foreground: colors.foreground,
            background: colors.background,
        });
        std::fs::write(&path, &png).map_err(|e| format!("{}: {e}", path.display()))?;
        let (width, height) = dimensions(&png);
        let first = page.first().map_or(request.start, |row| row.line);
        let last = page.last().map_or(end, |row| row.line);
        report += &format!("image {} {first} {last} {width}x{height}\n", path.display());
    }
    if let Some(rest) = pages.get(request.max_images) {
        report += &format!("remaining {} {end}\n", rows[rest.start].line);
    }
    Ok(report)
}

/// Width and height from the IHDR chunk the encoder just wrote.
fn dimensions(png: &[u8]) -> (u32, u32) {
    let field = |at: usize| u32::from_be_bytes(png[at..at + 4].try_into().unwrap());
    (field(16), field(20))
}
