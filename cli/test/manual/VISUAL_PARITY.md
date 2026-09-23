# visual parity capture (manual, opt-in)

This is not a UI test suite or a golden-image CI gate. It launches the real TypeScript CLI and the real Go CLI in isolated PTYs, records raw terminal bytes, decodes each with project-local `@xterm/headless`, and renders PNGs using the same fixed font, palette, dimensions, and timing. The fixture HTTP daemon binds **127.0.0.1 only** and rejects unknown routes. Per-run temporary `ALBEDO_HOME` is removed after capture. No real daemon, profile, provider, browser, or clipboard is accessed. The TS preload blocks external HTTP(S); Codex token exchange is fake-only. Go Codex token exchange MUST NOT be exercised through the shipped CLI: use the separate manual real-model driver with an injected fake exchange function.

Requires `uv`, Node, installed `cli/node_modules` (including `@xterm/headless`), and an installed monospace font. `uv` provides Pillow through this script's PEP 723 metadata; do **not** run through the agent kernel environment. On macOS it defaults to SFNSMono/Hiragino. On Linux it uses DejaVuSansMono/Noto CJK where installed. Set `ALBEDO_VISUAL_FONT` and `ALBEDO_VISUAL_CJK_FONT` explicitly if necessary; paths are recorded beside each capture.

Capture TS and immutable Go-before under the same label:

```sh
uv run --no-project --script cli/test/manual/visual_parity.py --binary ts --side ts --label markdown-80x24 --scenario markdown --cols 80 --rows 24 --snap initial:1.0 --expect 'initial:heading' --expect-request GET:/sessions/deadbeef12345678/stream --timeout 1.5
uv run --no-project --script cli/test/manual/visual_parity.py --binary /tmp/albedo-visual-parity/albedo-before --side before --label markdown-80x24 --scenario markdown --cols 80 --rows 24 --snap initial:1.0 --expect 'initial:heading' --timeout 1.5
```

Once parent supplies one final Go build, capture `--side after --binary /tmp/albedo-visual-parity/albedo-final` with the *same* scenario, variant, action sequence, snapshot labels and timings. Go binaries are copied into content-addressed `/tmp/albedo-visual-parity/binaries/` before launch. Do not use a mutable worktree Go binary as before. Relevant keys: `--action 1.0:/model --action 1.3:enter --snap picker:1.8 --expect 'picker:session model' --expect-request GET:/models/openai`. Supported symbolic keys include `enter,esc,up,down,left,right,pgup,pgdn,shift-enter,alt-enter,ctrl-j,ctrl-k,ctrl-home,ctrl-end,backspace,tab,ctrl-c`. `--expect-exit 0 --expect-reset` requires a real normal quit/cancel and terminal mode restoration, not a screenshot terminated by the harness. During Codex auth avoid overlapping captures because the local fake callback server uses port 1455.

Outputs are `/tmp/albedo-visual-parity/atlas/<label>/<side>-<snapshot>.png`, `.json` (xterm cells + cursor), `.pty` (snapshot raw), plus `<side>.pty` (full run) and `<side>.actions.json` (actions, assertions, safe env, fixture requests, immutable binary hash, source hash). A failed assertion still leaves artifacts but the command exits nonzero. Auth fake browser attempts are logged to `<side>.browser-blocked.log` with no actual browser opened. Cursor-visibility decisions follow actual PTY escape sequences.

Generate provenance-checked index and grouped contact sheets:

```sh
python3 cli/test/manual/visual_index.py --final-binary /tmp/albedo-visual-parity/albedo-final
uv run --no-project --script cli/test/manual/visual_contact.py --group chat/transcript --size 80x24
```

`atlas/coverage.json` marks stale/missing captures, compares matching scenarios, fixture variants, terminal sizes, actions and snapshot times, verifies TS production source and renderer/harness hashes, and requires every `after` binary SHA to match the explicit final target. `atlas/INDEX.md` links individual screenshots; `contact-*.png` holds four paired states per sheet. See `/tmp/albedo-visual-parity/interaction-inventory.md` for source-backed routes, keys, states, and current gaps. Manual Go injection drivers must use side `driver`, never `after`.
