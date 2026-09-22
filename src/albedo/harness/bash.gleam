import albedo/harness/extension as harness_extension

pub fn extension() -> harness_extension.Extension {
  harness_extension.python_module(
    "bash",
    "Run supervised shell commands from Python.",
    "bash",
    "bash(command) starts a background job. Await its handle for completion, or keep it in a variable. jobs contains session-owned handles. A job's output lives on its handle (job.tail()) and stays readable in full with output.read(job.id).",
    ["python"],
  )
}

pub fn plugin() -> harness_extension.Extension {
  extension()
}
