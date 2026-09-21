import albedo/harness/plugin

pub fn plugin() -> plugin.Plugin {
  plugin.Plugin(
    "bash",
    "bash(command) starts a background job. Await its handle for completion, or keep it in a variable. jobs contains session-owned handles. A job's output lives on its handle (job.tail()) and stays readable in full with output.read(job.id).",
    ["python"],
    [],
    ["bash"],
    fn(_) { Ok(Nil) },
    [],
  )
}
