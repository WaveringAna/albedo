# Albedo-owned MCP stdio launcher: no shell, scoped cwd, silent stderr.
import os
import sys

_, cwd, command, *arguments = sys.argv
with open(os.devnull, "wb", buffering=0) as sink:
    os.dup2(sink.fileno(), 2)
if cwd:
    os.chdir(cwd)
    os.environ["PWD"] = cwd
os.execve(command, [command, *arguments], os.environ)
