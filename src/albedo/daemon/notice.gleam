//// System notices injected into the transcript that direct the model without
//// appearing as user bubbles in the client view.

import gleam/string

const open = "<system-notice>"

pub fn is_notice(text: String) -> Bool {
  string.starts_with(text, open)
}
