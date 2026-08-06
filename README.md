# rune-language-zig

Rune language package for Zig: the `zig` toolchain, `zls`, `extension_zig`,
the tree-sitter grammar and `lldb-dap`, shipped as one signed tarball
published to the `zig` package id.

```
make                       # build pkg/ + zig.tar.gz for the host os/arch
make test                  # verify the built tarball
make dist-staging-darwin-arm64
make dist-prod-darwin-arm64
```

Releases are built on a machine running the target OS; only the arch may be
cross-built (`TARGET_ARCH=amd64`).

## Payload layout

```
pkg/
  config.yaml
  zig/{.zig, lib/**}         # compiler (hidden) + its 225MB lib (std, libc, compiler-rt)
  bin/{zig, zls, extension_zig, lldb-dap}   # zig is the zig-shim.sh wrapper
  lib/{tree-sitter.so, highlights.scm, indents.scm, folds.scm, locals.scm}
  lib/liblldb.*              # absent on darwin-amd64
```

Three non-obvious invariants, all consequences of how the installer publishes a
package: it symlinks the version dir at `$RUNE_DATADIR/lib/<pkg-id>` and
**byte-copies every non-hidden executable** it finds, by base name, into the shared
`$RUNE_DATADIR/bin`.

1. **The real compiler is hidden (`pkg/zig/.zig`); PATH gets a shim.** zig
   locates its `lib/` by walking up from its own executable path, so it must
   run from inside the package dir next to `lib/`. A non-hidden compiler
   anywhere in the package would be flat-copied into `$RUNE_DATADIR/bin` as a
   severed, non-functional copy — hidden files are skipped, so only the
   `zig-shim.sh` wrapper (staged as `pkg/bin/zig`) reaches `PATH`. It execs
   the hidden binary from either of its two install locations. The `lib/`
   payload is stripped of exec bits at build time for the same reason.
2. **No `ZIG_LIB_DIR` (or any zig env var beyond the cache dir).** `gui.env`
   leaks into every zig invocation inside Rune, so the var would pin
   user-provided toolchains (e.g. a dev compiler for ziglings) to this
   package's 0.16 std lib, failing with errors like
   `failed to check cache: ... lib/compiler/... FileNotFound`. zls needs
   nothing either: it resolves the lib dir by spawning `zig env`, which
   answers correctly through the shim.
3. **`lldb-dap` is invoked by package-local path**
   (`$RUNE_DATADIR/lib/$RUNE_PKG_ID/bin/lldb-dap`), not through the shared bin.
   rune-language-rust ships the same binary name, so the shared copy is
   whichever package installed last and is deleted when either is uninstalled.
   Its rpath (`@loader_path/../lib`) also only resolves inside the package dir,
   where `bin/` and `lib/` are siblings. Keep `LLVM_VERSION` in sync with
   rune-language-rust so the colliding copy stays byte-identical.

`scripts/test.sh` pins invariants 1-3 against the built tarball, including a
real `zig build` through the shim from a simulated `$RUNE_DATADIR`.

## Versioning

This package supersedes the grammar-only `zig` package published from
rune-language-template (`v0.0.9-1-g58ab44c`), so the first release tag must sort
above it: start at `v0.0.10`.