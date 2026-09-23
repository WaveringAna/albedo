# Third party notices

## prime-agent

The Python kernel's saved-state design follows prime-agent's REPL runtime
(`prime-agent-runtime/src/rlm/repl.py`): serialise each top-level name on its
own so one unserialisable object costs only itself, cap per variable and in
aggregate, write through a temporary file in the same directory, and record the
working directory alongside the values. Albedo's implementation
(`priv/python/albedo_kernel.py`, `save_state` and `load_state`) is its own code
and falls back to `pickle` where prime-agent requires `dill`.

prime-agent is distributed under the MIT License:

```
MIT License

Copyright (c) 2025 Mario Zechner
Copyright (c) 2026 Prime Intellect

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## JetBrains Mono

`native/render/fonts/JetBrainsMonoNL-Medium.ttf` is JetBrains Mono 2.304,
bundled unmodified into `albedo-render` to draw code for `files.view_code`.
Copyright 2020 The JetBrains Mono Project Authors
(https://github.com/JetBrains/JetBrainsMono). It is licensed under the SIL Open
Font License, Version 1.1, whose full text sits beside the font in
`native/render/fonts/JetBrainsMono-OFL.txt`.

## arborium

`albedo-render` links arborium (https://github.com/bearcove/arborium),
MIT OR Apache-2.0, and the tree-sitter grammars its enabled `lang-*` features
compile in, each under its own upstream license. They are fetched by Cargo,
not vendored here; `native/render/Cargo.lock` pins their versions.
