//// Github linguist's languages: what a file is written in, by its name, and
//// what linguist calls and colours that language. The table is
//// `priv/linguist/languages.yml`, read once by `albedo_languages.erl`.

import gleam/option.{type Option}

/// Linguist's kinds; its language bar counts only programming and markup.
pub type Kind {
  Programming
  Markup
  Data
  Prose
}

pub type Language {
  Language(
    name: String,
    kind: Kind,
    /// Linguist's own `#RRGGBB`, when it gives one.
    color: Option(String),
    /// The language this one counts towards in statistics, such as TSX
    /// towards TypeScript.
    group: Option(String),
  )
}

/// The language of a file, by its base name.
@external(erlang, "albedo_languages", "detect")
pub fn detect(file_name: String) -> Option(Language)

/// The language linguist calls `name`.
@external(erlang, "albedo_languages", "named")
pub fn named(name: String) -> Option(Language)

/// Whether github's language bar counts the language.
pub fn counted(language: Language) -> Bool {
  language.kind == Programming || language.kind == Markup
}
