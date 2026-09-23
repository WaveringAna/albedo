import albedo/harness/extension

/// Optional: it needs albedo-render, built by native/render/install.sh.
pub fn extension() -> extension.Extension {
  extension.python_module(
    "view",
    "See changes and code as syntax-highlighted images for a final review pass.",
    "view",
    "await view_diff(path=\".\", staged=False) shows your uncommitted changes (git diff) as syntax-highlighted images, and await view_code(path, start_line=1, end_line=None, columns=79) shows a range of one file; both return the images with the cell's result, and their text names what each image shows and the call that continues past it. An image holds up to 80 display rows, and a wrapped line, marked with an arrow, takes several. Before you report code work as done, make a final review pass: start with view_diff to see every change, then use view_code for context a hunk leaves out and for new files git does not track yet; to view a definition, get its line from files.find first. Read it all as a reviewer who did not write it. Check that it reads like the code around it (naming, comment density, idiom, error handling); that nothing is repeated which an existing helper or one shared function should carry, searching with files.find before keeping new code that looks familiar; that no dead code, debug output, or comment restating the code remains; and that nesting and line length stay easy to follow. The images show what numbered text hides: shape, depth, alignment, and repetition across a screen. Fix what you find, then view the fixed lines again. Skip the pass when no code changed, and use files.read, not images, for the exact text to edit.",
    ["python", "bash", "files"],
  )
}
