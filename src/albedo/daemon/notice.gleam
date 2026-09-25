//// System notices injected into the transcript that direct the model without
//// appearing as user bubbles in the client view.

import gleam/string

pub const open = "<system-notice>"
pub const close = "</system-notice>"

pub fn wrap(text: String) -> String {
  open <> "\n" <> text <> "\n" <> close
}

pub fn is_notice(text: String) -> Bool {
  string.starts_with(text, open)
}
