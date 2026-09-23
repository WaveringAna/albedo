# upstream ui

terminal rendering, transcript layout, input, markdown, live python-code views,
and the original ink patch were adapted from niri at the client boundary,
not replaced with a new visual design.

source: https://tangled.org/okami.mom/niri

## go port

the cli was ported from the typescript/ink reference to native go using the
charm stack (`bubbletea`, `lipgloss`, `bubbles`). the port preserves the
transcript layout, interactive keybindings, slash-command popovers, diff rendering,
and virtual scrolling while providing a standalone executable with bounded
memory and streaming event processing.
