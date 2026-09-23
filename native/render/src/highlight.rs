//! Syntax colors for a whole file, looked up by byte offset.

use arborium::Highlighter;
use arborium_highlight::{FlatToken, spans_to_flat_tokens};
use arborium_theme::highlights;
use arborium_theme::theme::{Color, Theme};

/// Which grammar colored the file, or why none did.
pub enum Language {
    Highlighted(String),
    /// Named after the file, but not one of the grammars compiled in.
    Unsupported(String),
    /// The grammar exists but could not highlight this file.
    Failed(String),
    Unknown,
}

pub struct Colors {
    tokens: Vec<(FlatToken, Color)>,
    pub foreground: Color,
    pub background: Color,
    pub language: Language,
}

impl Colors {
    /// Highlights all of `source`, so a range starting inside a comment or a
    /// string is colored as it would be in the whole file.
    pub fn new(source: &str, language: Option<&str>, theme: &Theme) -> Colors {
        let foreground = theme.foreground.unwrap_or(Color::new(0, 0, 0));
        let background = theme.background.unwrap_or(Color::new(255, 255, 255));
        let plain = |language| Colors {
            tokens: Vec::new(),
            foreground,
            background,
            language,
        };
        let Some(name) = language else {
            return plain(Language::Unknown);
        };
        let spans = match Highlighter::new().highlight_spans(name, source) {
            Ok(spans) => spans,
            Err(arborium::Error::UnsupportedLanguage { .. }) => {
                return plain(Language::Unsupported(name.to_string()));
            }
            Err(error) => return plain(Language::Failed(error.to_string())),
        };
        let tokens = spans_to_flat_tokens(source, spans)
            .into_iter()
            .filter_map(|token| tag_color(theme, token.tag).map(|color| (token, color)))
            .collect();
        Colors {
            tokens,
            foreground,
            background,
            language: Language::Highlighted(name.to_string()),
        }
    }

    /// The token covering each byte from `from` on, for a caller walking forward.
    pub fn cursor(&self, from: usize) -> Cursor<'_> {
        let index = self
            .tokens
            .partition_point(|(token, _)| (token.end as usize) <= from);
        Cursor {
            colors: self,
            index,
        }
    }
}

pub struct Cursor<'a> {
    colors: &'a Colors,
    index: usize,
}

impl Cursor<'_> {
    /// The color at byte `offset`; offsets must not decrease between calls.
    pub fn at(&mut self, offset: usize) -> Color {
        let tokens = &self.colors.tokens;
        while self.index < tokens.len() && (tokens[self.index].0.end as usize) <= offset {
            self.index += 1;
        }
        match tokens.get(self.index) {
            Some((token, color)) if token.start as usize <= offset => *color,
            _ => self.colors.foreground,
        }
    }
}

/// A child tag with no color of its own takes its parent's, as the theme's CSS would.
fn tag_color(theme: &Theme, tag: &str) -> Option<Color> {
    let index = (0..highlights::COUNT).find(|&index| highlights::tag(index) == Some(tag))?;
    theme.style(index).and_then(|style| style.fg).or_else(|| {
        let parent = highlights::HIGHLIGHTS[index].parent_tag;
        (!parent.is_empty())
            .then(|| tag_color(theme, parent))
            .flatten()
    })
}
