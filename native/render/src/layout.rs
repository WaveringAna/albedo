//! Source lines laid out on a fixed grid: tabs expanded to stops, wide
//! characters given two cells, and long lines wrapped at the column limit.

use crate::highlight::Colors;
use arborium_theme::theme::Color;
use unicode_width::UnicodeWidthChar;

/// One glyph at a grid column; a wide glyph also covers the next column.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Glyph {
    pub column: usize,
    pub ch: char,
    pub color: Color,
}

/// One row of the image: a source line, or the continuation of a wrapped one.
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub line: usize,
    pub continued: bool,
    pub glyphs: Vec<Glyph>,
}

/// The 1-based lines of `source` with the byte offset each starts at.
/// A final newline ends the last line rather than starting an empty one.
pub fn lines(source: &str) -> Vec<(usize, &str)> {
    let mut offset = 0;
    let mut lines = Vec::new();
    for line in source.split_inclusive('\n') {
        let text = line.strip_suffix('\n').unwrap_or(line);
        lines.push((offset, text.strip_suffix('\r').unwrap_or(text)));
        offset += line.len();
    }
    lines
}

pub fn rows(
    lines: &[(usize, &str)],
    first: usize,
    colors: &Colors,
    columns: usize,
    tab_width: usize,
) -> Vec<Row> {
    let mut rows = Vec::new();
    let mut cursor = colors.cursor(lines.first().map_or(0, |(offset, _)| *offset));
    for (index, (offset, text)) in lines.iter().enumerate() {
        let line = first + index;
        let mut row = Row {
            line,
            continued: false,
            glyphs: Vec::new(),
        };
        let mut column = 0;
        for (at, ch) in text.char_indices() {
            let color = cursor.at(offset + at);
            let (ch, width) = match ch {
                '\t' => (' ', tab_width - column % tab_width),
                ch if ch.is_control() => ('\u{FFFD}', 1),
                // Combining marks have no cell of their own; they are dropped.
                ch => match ch.width() {
                    Some(0) => continue,
                    width => (ch, width.unwrap_or(1)),
                },
            };
            if column + width > columns && column > 0 {
                rows.push(std::mem::replace(
                    &mut row,
                    Row {
                        line,
                        continued: true,
                        glyphs: Vec::new(),
                    },
                ));
                column = 0;
            }
            if ch != ' ' {
                row.glyphs.push(Glyph { column, ch, color });
            }
            column += width.min(columns);
        }
        rows.push(row);
    }
    rows
}

/// Consecutive rows that fit one image, as evenly sized as the fewest pages
/// allow, so a range just over one page is not a full page and a sliver.
/// A page ends at a line boundary unless one line is taller than a page.
pub fn pages(rows: &[Row], max_rows: usize) -> Vec<std::ops::Range<usize>> {
    let count = rows.len().div_ceil(max_rows).max(1);
    let size = rows.len().div_ceil(count).max(1);
    let mut pages = Vec::new();
    let mut start = 0;
    while start < rows.len() {
        let mut end = (start + size).min(rows.len());
        if end < rows.len() && rows[end].continued {
            let boundary = (start + 1..end).rev().find(|&index| !rows[index].continued);
            end = boundary.unwrap_or(end);
        }
        pages.push(start..end);
        start = end;
    }
    pages
}

#[cfg(test)]
mod tests {
    use super::*;
    use arborium_theme::theme::builtin;

    fn plain(source: &str, columns: usize) -> Vec<Row> {
        let colors = Colors::new(source, None, &builtin::github_light());
        rows(&lines(source), 1, &colors, columns, 4)
    }

    fn text(row: &Row) -> String {
        let mut text = String::new();
        for glyph in &row.glyphs {
            while text.chars().count() < glyph.column {
                text.push(' ');
            }
            text.push(glyph.ch);
        }
        text
    }

    #[test]
    fn lines_keep_offsets_and_drop_line_endings() {
        assert_eq!(
            lines("a\r\nbc\n\nd"),
            vec![(0, "a"), (3, "bc"), (6, ""), (7, "d")]
        );
        assert_eq!(lines("a\n"), vec![(0, "a")]);
        assert!(lines("").is_empty());
    }

    #[test]
    fn tabs_stop_at_multiples_of_the_tab_width() {
        let rows = plain("a\tb\n\tc", 79);
        assert_eq!(text(&rows[0]), "a   b");
        assert_eq!(text(&rows[1]), "    c");
    }

    #[test]
    fn long_lines_wrap_and_wide_characters_never_split() {
        let rows = plain("abcdefg\n漢字漢", 3);
        let wrapped: Vec<_> = rows
            .iter()
            .map(|row| (row.line, row.continued, text(row)))
            .collect();
        assert_eq!(
            wrapped,
            vec![
                (1, false, "abc".into()),
                (1, true, "def".into()),
                (1, true, "g".into()),
                (2, false, "漢".into()),
                (2, true, "字".into()),
                (2, true, "漢".into()),
            ]
        );
        assert_eq!(rows[3].glyphs[0].column, 0);
    }

    #[test]
    fn control_characters_are_visible_and_empty_lines_keep_a_row() {
        let rows = plain("a\u{1b}b\n\nc\u{301}", 79);
        assert_eq!(text(&rows[0]), "a\u{FFFD}b");
        assert_eq!(rows[1].glyphs, vec![]);
        assert_eq!(text(&rows[2]), "c");
    }

    #[test]
    fn pages_break_between_lines_unless_one_line_fills_a_page() {
        let rows = plain("aa\nbbbbbb\ncc\ndddddddddd", 2);
        // rows: a(1) b b b(2) c(3) d d d d d(4)
        assert_eq!(pages(&rows, 3), vec![0..1, 1..4, 4..5, 5..8, 8..10]);
    }

    #[test]
    fn a_range_just_over_one_page_splits_evenly() {
        let rows = plain(&"x\n".repeat(81), 79);
        assert_eq!(pages(&rows, 80), vec![0..41, 41..81]);
        assert_eq!(pages(&rows[..80], 80), vec![0..80]);
    }
}
