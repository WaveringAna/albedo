import albedo/harness/extension
import gleam/bytes_tree
import gleam/http/response
import mist

fn named(name: String, plugins: List(extension.Plugin)) -> extension.Extension {
  extension.Extension(name, "", [], plugins, fn(_) { Ok(Nil) })
}

fn teapot() -> extension.Service {
  extension.Service(fn(_, _, _) {
    response.new(418) |> response.set_body(mist.Bytes(bytes_tree.new()))
  })
}

pub fn only_an_enabled_extension_with_a_service_mounts_test() {
  let selected = [
    named("proxy", [extension.ServicePlugin(teapot())]),
    named("plain", []),
  ]
  let assert Ok(_) = extension.service(selected, "proxy")
  let assert Error(Nil) = extension.service(selected, "plain")
  let assert Error(Nil) = extension.service(selected, "absent")
}
