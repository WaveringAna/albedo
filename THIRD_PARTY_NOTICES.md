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

## linguist

`priv/linguist/languages.yml` and `priv/linguist/popular.yml` are GitHub
linguist's language table and popular-language list
(https://github.com/github-linguist/linguist, `lib/linguist/`), shipped
unmodified. The folder browser reads them for file languages, their colours
and the language shares in `/fs/preview`.

linguist is distributed under the MIT License:

```
Copyright (c) 2017 GitHub, Inc.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
```

## madoromi

The web client's default colours, its seasons and its accent presets
(`web/src/lib/prefs.svelte.ts`, with fallbacks in `web/src/app.css` and
`web/index.html`) are hex values from madoromi by samhain
(https://github.com/the-moonwitch/madoromi, https://madoromi.moonwit.ch/,
https://bsky.app/profile/personhood.removal.surgery),
colours measured from Pilot's iroshizuku inks. madoromi is distributed under the
Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/); the values are used
unmodified and the settings pane credits it with a link.

## web client libraries

The browser client in `web/` bundles these libraries, each under its own
licence, which ships in its package: Svelte and Svelte Flow (xyflow), MIT;
Diffs from The Pierre Computer Company (`@pierre/diffs`, https://diffs.com),
Apache License 2.0; Shiki, MIT; KaTeX, MIT; Pele (https://pele.run, by
Obsidian), MIT; marked, MIT. The client's about pane lists them with links.

## Lucide

The canvas's key hints (`web/src/lib/Gesture.svelte`) draw four of Lucide's
icons, copied as SVG paths rather than installed: hand-grab, move, mouse and
mouse-pointer-click (https://lucide.dev). Lucide is distributed under the ISC
License:

```
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```
