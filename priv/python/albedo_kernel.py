"""Start a kernel: albedo_cells runs as __main__.

A script is compiled from source each time it starts; a module loads its
cached bytecode. The kernel is long, so this keeps about 4 MB of compile
work out of every kernel's memory.
"""

import runpy

runpy.run_module("albedo_cells", run_name="__main__", alter_sys=True)
