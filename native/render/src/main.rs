//! albedo-render: a highlighted range of a source file as PNG pages.
//!
//! albedo-render FILE --start N --end N --out DIR [--columns 79]
//!     [--tab-width 4] [--language NAME] [--max-rows 80] [--max-images 4]
//!
//! Writes DIR/view-1.png onward and prints one line per fact, for the caller
//! to parse from text output:
//!
//!   language rust            (or: language plain [reason])
//!   image DIR/view-1.png FIRST LAST WIDTHxHEIGHT
//!   remaining FIRST LAST     (lines left for another call, if any)
//!
//! A line split across pages appears in both. Errors go to stderr, exit 1.

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
}

fn main() -> ExitCode {
    match parse(std::env::args().skip(1)).and_then(|request| run(&request)) {
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
            "--out" => out = Some(PathBuf::from(value()?)),
            flag if flag.starts_with("--") => return Err(format!("unknown option {flag}")),
            _ if file.is_none() => file = Some(PathBuf::from(arg)),
            _ => return Err(format!("unexpected argument {arg:?}")),
        }
    }
    request.file = file.ok_or("a file to render is required")?;
    request.out = out.ok_or("--out DIR is required")?;
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
    let gutter = end.to_string().len();
    for (index, range) in pages.iter().take(request.max_images).enumerate() {
        let page = &rows[range.clone()];
        let path = request.out.join(format!("view-{}.png", index + 1));
        let png = painter.png(&raster::Page {
            rows: page,
            gutter,
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
