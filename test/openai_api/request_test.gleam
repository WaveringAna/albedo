// Provider request replay preserves foreign fields while rejecting cross-protocol input and malformed image metadata.
import albedo/openai_api as openai
import albedo/openai_api/request
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/string_tree

fn body(protocol: types.Protocol, request: types.Request) -> String {
  let assert Ok(body) = request.encode(protocol, request)
  string_tree.to_string(body)
}

pub fn replay_preserves_unknown_fields_and_refuses_other_protocol_test() -> Result(
  string_tree.StringTree,
  types.Error,
) {
  let assert Ok(item) =
    json.parse(
      "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"future\":{\"x\":1}}",
      types.replay_decoder(types.Responses),
    )
  let request = openai.request("model", [types.Replay(item)])
  let encoded = body(types.Responses, request)
  assert json.parse(
      encoded,
      decode.at(["input"], decode.list(decode.at(["future", "x"], decode.int))),
    )
    == Ok([1])
  let assert Error(types.InvalidRequest(_)) =
    request.encode(types.ChatCompletions, request)
}

pub fn validates_image_metadata_bounds_test() -> Result(
  types.Image,
  types.Error,
) {
  let assert Error(types.InvalidRequest(_)) =
    types.image("image/gif", "aGVsbG8=", 2, 3, 5)
  let assert Error(types.InvalidRequest(_)) =
    types.image("image/png", "aGVsbG8=", 10_000, 5000, 5)
  let assert Error(types.InvalidRequest(_)) =
    types.image("image/png", "aGVsbG8=", 2, 3, types.max_image_bytes + 1)
}

// Persisting a valid image must not reinterpret its padded base64 length as
// the decoded file length. Stored payloads remain lazy during validation.
pub fn inline_and_stored_images_have_the_same_size_contract_test() -> Nil {
  list.each(
    [
      types.max_image_bytes - 1,
      types.max_image_bytes,
      types.max_image_bytes + 1,
    ],
    fn(bytes) {
      let encoded_size = 4 * { { bytes + 2 } / 3 }
      let data = string.repeat("A", encoded_size)
      let inline = types.image("image/png", data, 2, 3, bytes)
      let stored =
        types.stored_image(
          "image/png",
          "hash",
          encoded_size,
          fn() { panic as "metadata validation read a stored payload" },
          2,
          3,
          bytes,
        )
      assert result.map(inline, types.image_meta)
        == result.map(stored, types.image_meta)
      assert result.is_ok(inline) == { bytes <= types.max_image_bytes }
    },
  )
}
