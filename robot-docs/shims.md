# shims: nix and cargo

the model's jobs (`run()`, `job.pipe()`, and remote kernels' alike) find two
shims first on PATH, each under `$ALBEDO_HOME/shims/<needs>/` and prepended
only when the program it needs is on the job's PATH (`albedo_shims.prepend`):
`shims/nix/nix` when nix is, `shims/mbx/cargo` when mbx is. the kernel writes
them where it runs (only `.py` files travel to a remote kernel), and every
nix call a job makes goes through the shim, however deep in a script it is.
Before lookup, `prepend` removes inherited `*/shims/nix` and `*/shims/mbx`
directories, then installs only this kernel's shims for real tools on PATH.
Nested daemon jobs must not resolve one shim generation through another.
there is no nix API for the model to learn: it types `nix develop -c cargo
test` or `nix build .#x` and the shim makes that safe and fast.

## nix

### why

a jj workspace other than the colocated one has `.jj/` but no `.git`, so nix
reads `.` as a plain `path:` flake and copies the whole directory into the
store on every evaluation: build output, `target/`, `.jj` and all (140 MB per
eval measured on a small checkout, ~850 MB for a full albedo one). a git
checkout or worktree is fine: nix's git fetcher copies tracked files only.

### the program

`shims/nix/nix` is sh: with `ALBEDO_SHIMS_PYTHON` and `ALBEDO_SHIMS_LIB` set
(by `prepend`, the kernel's python and its `priv/python`) it runs
`albedo_nix.py` with `python -E -s`, else, and with `ALBEDO_PLAIN_NIX=1`, the
next nix on PATH. `albedo_nix.py` is stdlib only and never imported by the
kernel. what it does with a command line:

1. reads it with nix's own flag table, `nix __dump-cli` (50 ms, cached in
   `$ALBEDO_HOME/cache/nix-cli/` per nix binary), so every flag's arity is
   known. commands it cannot read (a flag or command not in the table) go to
   nix unchanged, which refuses them itself. `ALIASES` covers nix's renamed
   commands the table lists only under their new name (`nix shell` is
   `env shell`, `profile install` is `profile add`, `dev-shell` is `develop`).
2. `nix develop [installable] -c program ...` with only output flags (`QUIET`)
   runs the program in the cached dev shell (below), with the shims kept first
   on PATH. any other develop flag (`-i`, `--phase`, ...) goes to step 3.
3. every word that names a local flake of a jj workspace without `.git` is
   replaced by the workspace's commit ref, following the subcommand's argument
   labels in the table (`installables`, `installable`, `flake-url`, `package`,
   `dependency`), plus `--inputs-from` and `flake update --flake`. a command
   that names none defaults to `.` as nix does (not `nix eval`, not with
   `--expr`/`--file`/`--stdin`/`--all`). `nix fmt` and `nix formatter run|build`
   become `nix run|build <ref>#formatter.<system>` with `PRJ_ROOT` set to the
   flake's directory, as nix fmt sets it. the rewritten command is printed to
   stderr after `albedo:`, then exec'd.
4. anything else is exec'd unchanged.

### refs and lock files

`flake_ref`: `jj log -r @` snapshots the working copy, so commit `@` holds every
edit, and `jj git root` names the git store. the ref is
`git+file://<store>?rev=<commit>` (`&dir=` for a flake below the workspace
root); a colocated `.git` is named by its work tree (nix reads it in place;
naming the `.git` directory makes nix clone it into its cache), a bare store as
itself. jj keeps every commit under `refs/jj/keep/*`, so nix finds it. git
checkouts and directories outside version control are never rewritten.

nix writes a lock file it had to create or update into the repository a
`git+file` ref names: for a colocated store that is the main checkout's work
tree (measured: `nix build <ref>` created `main/flake.lock`). so a rewritten
command gets `--output-lock-file <workspace flake>/flake.lock`, which writes
where nix would have in a git checkout. that flag covers every flake the
command locks (`--inputs-from . nixpkgs#hello` wrote nixpkgs' empty lock over
the workspace's), so a command that locks any other flake gets
`--no-write-lock-file` instead. `--commit-lock-file` would commit in the main
checkout and is refused. nix rewrites the output lock file even when it is
unchanged; nix-formatted locks keep their content.

### dev shells

`nix print-dev-env --profile <cache>/<key> <ref>` writes the same script
`nix develop` sources; the shim sources it with the shell's own bash (the
`shell` variable from the profile's JSON: macOS's /bin/bash 3.2 cannot run it),
which runs the shellHook (its output goes to stderr), removes `$NIX_BUILD_TOP`,
and dumps `env -0`. what is kept is the difference from the job's environment
(`delta`): variables set, prefixes put before a list the shell kept (PATH,
XDG_DATA_DIRS) and variables unset. `TMPDIR`, `NIX_BUILD_TOP` and the like
(`VOLATILE`) are dropped. `applied` lays it over each later job's environment.
a build prints `albedo: building the dev shell for <dir>` first; a cached run
prints nothing of its own.

the cache is `$ALBEDO_HOME/cache/nix-develop/<key>.json`, and the profile
`<key>` beside it is a garbage-collector root for the shell's closure. the key
hashes the system, the attribute, the flake's place in its checkout, and the
content of every tracked `SHELL_FILES` file (`*.nix`, `flake.lock`,
`rust-toolchain`, `rust-toolchain.toml`; `jj file list --ignore-working-copy`
or `git ls-files`, a walk outside version control). so an unchanged flake
costs one `jj file list` and no nix call (60 ms), and every checkout of the
same repository at the same shell files shares one entry. a build that wrote
the lock file is stored under the key after it too. the 32 most recently used
entries are kept; a flake elsewhere (`nixpkgs#hello`) is keyed by its name and
kept a day. shims building the same key at once wait on one `flock`.

limits: a dev shell made of other files (built from Cargo.lock or
pyproject.toml) is not rebuilt when only those change; a shellHook with side
effects (starting a service) runs once per build, not per command; a stale jj
workspace (`jj workspace update-stale`) fails with jj's message. `nix-shell`
and `nix-build` are other binaries and are not shimmed.

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
- inside a nix shell (`ALBEDO_NIX_ENV`, which the dev-shell capture sets), `CC`
  and `CXX` are unset when they resolve to the same file as `cc` and `c++` on
  PATH (the nix cc-wrapper's `cc` is a symlink to its `clang`), so a build
  script's C compiles through mbx and stays portable: an explicit `CC` makes
  mbx leave that C alone (`cc-compiler-override`), and a dev build's objects
  then record the checkout's paths (synthetic workspace, second checkout: 31
  hits and 3 misses with `CXX` set, 34 and 0 without). a shell whose `CC` is
  another compiler (gcc, a cross compiler) keeps it. and `HOST_CFLAGS`/`HOST_CXXFLAGS` gain
  `-DALBEDO_NIX_ENV_<digest>`. the digest is of the shell's compiler-wrapper
  variables (`NIX_CFLAGS*`, `NIX_LDFLAGS*`, `NIX_CC*`,
  `NIX_HARDENING_ENABLE`), which change C output but are in no mbx key:
  without it a changed shell was served another checkout's stale object.

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
