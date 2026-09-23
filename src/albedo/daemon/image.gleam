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

/// An image whose MIME type and dimensions are read from its own header.
pub fn from_base64(data: String) -> Result(types.Image, String) {
  use #(mime_type, width, height, bytes) <- result.try(
    inspect(data)
    |> result.replace_error("not a PNG, JPEG, or WebP albedo can read"),
  )
  types.image(mime_type, data, width, height, bytes)
  |> result.map_error(fn(error) {
    case error {
      types.InvalidRequest(message) -> message
      other -> string.inspect(other)
    }
  })
}

@external(erlang, "albedo_image", "inspect")
fn inspect(data: String) -> Result(#(String, Int, Int, Int), Nil)
