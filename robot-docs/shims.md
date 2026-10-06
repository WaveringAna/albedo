# shims: cargo

the model's jobs (`run()`, `job.pipe()`, and remote kernels' alike) find
shims first on PATH, each under `$ALBEDO_HOME/shims/<needs>/` and prepended
only when the program it needs is on the job's PATH (`albedo_shims.prepend`):
`shims/mbx/cargo` when mbx is. the kernel writes them where it runs (only
`.py` files travel to a remote kernel), and every call a job makes goes
through them, however deep in a script it is.

## cargo

`shims/mbx/cargo` runs mbx (jdx's mr-boxington) in its shim mode, so every
checkout shares compiled work through mbx's cache. `ALBEDO_NO_MBX=1`, or mbx
gone from PATH, runs the next cargo. mbx's own `mbx setup` is not used: it
edits the user's rust-analyzer config, and its shim exits 127 when mbx is
missing.

what the shim changes for mbx's process, all measured on native/render (a
second checkout: 32 s with 55 links bypassed, 2.1 s with 201 hits after):

- `SDKROOT` is unset. mbx names the macOS linker with
  `xcrun --sdk "$SDKROOT" --show-sdk-version`, and xcrun rejects a path such as
  a nix shell's store SDK, which leaves the linker unnamed and every native
  link uncached: build scripts, proc macros, binaries, tests, and so every
  crate depending on a proc macro or a cc-built `-sys` crate. `DEVELOPER_DIR`
  stays, so the same SDK is linked.

never set for cargo here: `CARGO_INCREMENTAL`, `RUSTC_WRAPPER`, `MBX_CACHE_DIR`
(one cache is the point), a `--target` equal to the host, or `-C link-arg`.
what stays per checkout: crates whose build-script output or source names the
checkout or target path and their dependents (aws-lc-sys's memcmp probe leaves
a path-bearing `.dSYM` in `OUT_DIR` under `-g`; tikv-jemalloc-sys runs
autotools there unless `JEMALLOC_OVERRIDE` names a built library), and a
workspace crate being edited. a new toolchain or dev shell is a new key, as it
should be.

mbx replaces a checkout's `target/` with a symlink into its cache. an ignore
rule with a trailing slash (`target/`) matches directories only, so jj would
track that symlink: albedo's own rule is `/native/render/target`.
