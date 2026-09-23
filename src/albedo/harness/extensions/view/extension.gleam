import albedo/harness/extension

/// Optional: it needs albedo-render, built by native/render/install.sh.
pub fn extension() -> extension.Extension {
  extension.python_module(
    "view",
    "See code as syntax-highlighted images for a final review pass.",
    "view",
    "await view_code(path, start_line=1, end_line=None, columns=79) shows you those lines as syntax-highlighted images with the cell's result; its text names the lines each image shows and the call that continues past them. Before you report code work as done, make a final review pass with it: view each region you wrote or changed and read it as a reviewer who did not write it. Check that it reads like the code around it (naming, comment density, idiom, error handling); that nothing is repeated which an existing helper or one shared function should carry, searching with files.find before keeping new code that looks familiar; that no dead code, debug output, or comment restating the code remains; and that nesting and line length stay easy to follow. The images show what numbered text hides: shape, depth, alignment, and repetition across a screen. Fix what you find, then view the fixed lines again. View the changed ranges, not whole files, and skip the pass when no code changed. Use files.read, not images, for the exact text to edit.",
    ["python", "bash", "files"],
  )
}
