import albedo/openai_api/types
import gleam/result
import gleam/string

/// Decode canonical base64 and derive MIME and dimensions from bounded headers.
/// This verifies transport metadata, not the complete compressed image stream.
pub fn validate(
  mime_type: String,
  data: String,
  width: Int,
  height: Int,
  bytes: Int,
) -> Result(types.Image, String) {
  use image <- result.try(
    types.image(mime_type, data, width, height, bytes)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use inspected <- result.try(
    inspect(data)
    |> result.replace_error("invalid image payload or header"),
  )
  case inspected == #(mime_type, width, height, bytes) {
    True -> Ok(image)
    False -> Error("image metadata does not match its payload")
  }
}

@external(erlang, "albedo_image", "inspect")
fn inspect(data: String) -> Result(#(String, Int, Int, Int), Nil)
