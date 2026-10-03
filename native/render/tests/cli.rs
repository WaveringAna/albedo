//! The binary end to end: a file in, PNG pages and a text report out, or an
//! image in and the same image fitted to an edge out.

use std::path::{Path, PathBuf};
use std::process::Command;

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("albedo-render-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    fn file(&self, name: &str, content: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        std::fs::write(&path, content).unwrap();
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn render(file: &Path, out: &Path, args: &[&str]) -> (bool, String, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_albedo-render"))
        .arg(file)
        .arg("--out")
        .arg(out)
        .args(args)
        .output()
        .unwrap();
    let text = |bytes: Vec<u8>| String::from_utf8(bytes).unwrap();
    (
        output.status.success(),
        text(output.stdout),
        text(output.stderr),
    )
}

fn png_size(path: &Path) -> (u32, u32) {
    size(&std::fs::read(path).unwrap())
}

fn size(bytes: &[u8]) -> (u32, u32) {
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
    let field = |at: usize| u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
    (field(16), field(20))
}

#[test]
fn a_range_becomes_pages_and_a_report() {
    let scratch = Scratch::new("pages");
    let source: String = (1..=300)
        .map(|n| format!("let value_{n} = {n};\n"))
        .collect();
    let file = scratch.file("sample.rs", source.as_bytes());
    let (ok, report, _) = render(
        &file,
        &scratch.0,
        &[
            "--start",
            "11",
            "--end",
            "400",
            "--max-rows",
            "50",
            "--max-images",
            "2",
        ],
    );
    assert!(ok);
    let lines: Vec<&str> = report.lines().collect();
    assert_eq!(lines[0], "language rust");
    let image_lines: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|line| line.starts_with("image "))
        .collect();
    assert!(!image_lines.is_empty());
    assert!(image_lines.len() <= 2, "exceeded the requested image cap");
    let image_count = image_lines.len();
    let mut next_row = 11;
    for line in image_lines {
        // Paths may contain spaces; the final three fields are the row range and dimensions.
        let mut fields = line.rsplitn(4, ' ');
        let dimensions = fields.next().unwrap();
        let last: usize = fields.next().unwrap().parse().unwrap();
        let first: usize = fields.next().unwrap().parse().unwrap();
        let path = fields.next().unwrap().strip_prefix("image ").unwrap();
        assert_eq!(first, next_row, "pages lost or repeated rows");
        assert!(last >= first && last <= 300);
        assert!(last - first + 1 <= 50, "exceeded the requested row cap");
        let (width, height) = png_size(Path::new(path));
        assert!(width > 0 && height > 0);
        assert_eq!(dimensions, format!("{width}x{height}"));
        next_row = last + 1;
    }
    assert_eq!(lines.last().unwrap(), &format!("remaining {next_row} 300"));
    assert_eq!(lines.len(), image_count + 2);
}

#[test]
fn keywords_are_colored_and_unknown_files_render_plain() {
    let scratch = Scratch::new("colors");
    let rust = scratch.file("a.rs", b"fn main() {}\n");
    let text = scratch.file("a.unknown", b"fn main() {}\n");
    let (_, report, _) = render(&rust, &scratch.0, &["--start", "1", "--end", "1"]);
    assert_eq!(report.lines().next(), Some("language rust"));
    let colored = std::fs::read(scratch.0.join("view-1.png")).unwrap();
    let (_, report, _) = render(&text, &scratch.0, &["--start", "1", "--end", "1"]);
    assert_eq!(
        report.lines().next(),
        Some("language plain unknown file type")
    );
    let plain = std::fs::read(scratch.0.join("view-1.png")).unwrap();
    assert_ne!(colored, plain);
    let (_, report, _) = render(
        &text,
        &scratch.0,
        &["--start", "1", "--end", "1", "--language", "cobol"],
    );
    assert_eq!(
        report.lines().next(),
        Some("language plain no grammar for cobol")
    );
}

#[test]
fn bad_requests_fail_with_a_reason() {
    let scratch = Scratch::new("errors");
    let file = scratch.file("a.py", b"x = 1\n");
    let binary = scratch.file("a.bin", b"\x00\x01\x02");
    for (target, args, reason) in [
        (
            &file,
            vec!["--start", "5", "--end", "6"],
            "has 1 lines; --start 5 is past the end",
        ),
        (
            &file,
            vec!["--start", "3", "--end", "2"],
            "--end 2 is before --start 3",
        ),
        (
            &file,
            vec!["--start", "1"],
            "--start and --end are required",
        ),
        (
            &file,
            vec!["--start", "1", "--end", "1", "--columns", "5"],
            "--columns must be an integer from 20 to 400",
        ),
        (&binary, vec!["--start", "1", "--end", "1"], "looks binary"),
    ] {
        let (ok, report, error) = render(target, &scratch.0, &args);
        assert!(!ok, "{args:?} succeeded");
        assert_eq!(report, "");
        assert!(error.contains(reason), "{error:?} lacks {reason:?}");
    }
}

#[test]
fn without_line_numbers_the_gutter_keeps_only_wrap_marks() {
    let scratch = Scratch::new("gutter");
    let file = scratch.file("a.diff", b"@@ -1 +1 @@\n-old\n+new\n");
    let page = scratch.0.join("view-1.png");
    render(&file, &scratch.0, &["--start", "1", "--end", "3"]);
    let numbered = std::fs::read(&page).unwrap();
    let (ok, report, _) = render(
        &file,
        &scratch.0,
        &["--start", "1", "--end", "3", "--no-line-numbers"],
    );
    assert!(ok);
    assert_eq!(report.lines().next(), Some("language diff"));
    let bare = std::fs::read(&page).unwrap();
    // One digit or one wrap mark: the same width, without the numbers.
    assert_eq!(size(&bare), size(&numbered));
    assert_ne!(bare, numbered);
}

#[test]
fn a_page_fits_inside_an_edge_and_keeps_its_aspect() {
    let scratch = Scratch::new("fit");
    let source: String = (1..=60).map(|n| format!("line {n}\n")).collect();
    let file = scratch.file("sample.txt", source.as_bytes());
    let pages = scratch.0.join("pages");
    std::fs::create_dir_all(&pages).unwrap();
    assert!(render(&file, &pages, &["--start", "1", "--end", "60"]).0);
    let page = pages.join("view-1.png");
    let (width, height) = png_size(&page);
    let (ok, report, _) = render(&page, &scratch.0, &["--fit", "400"]);
    assert!(ok);
    let fitted = scratch.0.join("fit.png");
    let (w, h) = png_size(&fitted);
    assert_eq!(report, format!("image {} {w}x{h}\n", fitted.display()));
    assert_eq!(w.max(h), 400);
    let expected = width as f64 / height as f64;
    assert!((w as f64 / h as f64 - expected).abs() < 0.02);
    let (ok, _, error) = render(&file, &scratch.0, &["--fit", "400"]);
    assert!(!ok && error.contains("PNG, JPEG, or WebP"));
}
