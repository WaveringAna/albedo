//// History images fitted to a provider's edge by appending to the transcript.
////
//// New images over the limit are refused when attached, so what needs fitting
//// is history an earlier, looser provider accepted. Each such image is scaled
//// once, in albedo-render, and the copy is appended as an image fit row (see
//// transcript.ImageFit): loading the history swaps it in for every earlier
//// occurrence, so the transcript alone says what each request carried.
////
//// TODO: a fit is permanent, so a switch back to a looser provider keeps the
//// copy. Fitting per edge would record the edge on the row and apply a fit
//// only while the provider needs it, which also needs the limit each request
//// ran under in the transcript.

import albedo/daemon/image
import albedo/daemon/note
import albedo/daemon/transcript
import albedo/openai_api/types
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

@external(erlang, "albedo_render", "fit")
fn render_fit(
  data: String,
  edge: Int,
) -> Result(#(String, String, Int, Int, Int), String)

/// A fit for every distinct image in `inputs` over `limits`, oldest first.
pub fn needed(
  limits: types.ImageLimits,
  inputs: List(types.Input),
) -> Result(List(transcript.ImageFit), String) {
  inputs
  |> list.flat_map(images)
  |> list.filter(fn(image) {
    option.is_some(types.image_refusal(limits, image))
  })
  |> list.try_fold([], fn(fits, original) {
    let source = source(original)
    case list.any(fits, fn(fit: transcript.ImageFit) { fit.source == source }) {
      True -> Ok(fits)
      False -> {
        use data <- result.try(
          payload(original)
          |> result.replace_error(failed(
            limits.max_edge,
            "its payload is missing",
          )),
        )
        use image <- result.map(
          render_fit(data, limits.max_edge)
          |> result.try(fn(fitted) {
            let #(mime, data, width, height, bytes) = fitted
            image.validate(mime, data, width, height, bytes)
          })
          |> result.map_error(failed(limits.max_edge, _)),
        )
        [
          transcript.ImageFit(
            note(original, image, limits.max_edge),
            source,
            image,
          ),
          ..fits
        ]
      }
    }
  })
  |> result.map(list.reverse)
}

/// `input` with every image `fit` stands in for swapped for its copy.
pub fn apply(input: types.Input, fit: transcript.ImageFit) -> types.Input {
  let swap = fn(image) {
    case source(image) == fit.source {
      True -> fit.image
      False -> image
    }
  }
  case input {
    types.UserImage(text, image) -> types.UserImage(text, swap(image))
    types.ToolOutput(id, text, images) ->
      types.ToolOutput(id, text, list.map(images, swap))
    _ -> input
  }
}

fn images(input: types.Input) -> List(types.Image) {
  case input {
    types.UserImage(_, image) -> [image]
    types.ToolOutput(_, _, images) -> images
    _ -> []
  }
}

/// The hash albedo_images.erl stores `image`'s payload under.
fn source(image: types.Image) -> String {
  case types.image_data(image) {
    types.StoredData(hash, _, _) -> hash
    types.InlineData(data) -> hash(data)
  }
}

fn payload(image: types.Image) -> Result(String, Nil) {
  case types.image_data(image) {
    types.InlineData(data) -> Ok(data)
    types.StoredData(_, _, read) -> read()
  }
}

fn hash(data: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(data))
  |> bit_array.base16_encode
  |> string.lowercase
}

fn failed(edge: Int, reason: String) -> String {
  "an image in this session is over this model's "
  <> int.to_string(edge)
  <> "px edge limit and could not be fitted: "
  <> reason
}

fn note(original: types.Image, fitted: types.Image, edge: Int) -> String {
  let size = fn(image) {
    let #(_, width, height, _) = types.image_meta(image)
    int.to_string(width) <> "x" <> int.to_string(height)
  }
  note.wrap(
    "image scaled",
    "An earlier image was scaled from "
      <> size(original)
      <> " to "
      <> size(fitted)
      <> " to fit this model's "
      <> int.to_string(edge)
      <> "px edge limit; the transcript keeps the original.",
  )
}
