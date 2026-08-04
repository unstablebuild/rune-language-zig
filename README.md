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
  zig/{zig, lib/**}          # compiler + its 225MB lib (std, libc, compiler-rt)
  bin/{zls, extension_zig, lldb-dap}
  lib/{tree-sitter.so, highlights.scm, indents.scm, folds.scm, locals.scm}
  lib/liblldb.*              # absent on darwin-amd64
```

Three non-obvious invariants, all consequences of how the installer publishes a
package: it symlinks the version dir at `$RUNE_DATADIR/lib/<pkg-id>` and
**byte-copies every executable** it finds, by base name, into the shared
`$RUNE_DATADIR/bin`.

1. **`zig` ships only under `pkg/zig/`, never `pkg/bin/`.** The installer's
   flat copy produces `$RUNE_DATADIR/bin/zig` for free, so a second copy would
   add 185MB for nothing.
2. **`ZIG_LIB_DIR` is mandatory** (`config.yaml`). zig finds its `lib/`
   relative to its own executable, and the shared-bin copy is severed from it:
   `zig env` then exits 1, which also costs zls its std-library analysis and
   build-on-save. The `lib/` payload is stripped of exec bits at build time so
   the flat copy does not publish data files onto `PATH`.
3. **`lldb-dap` is invoked by package-local path**
   (`$RUNE_DATADIR/lib/$RUNE_PKG_ID/bin/lldb-dap`), not through the shared bin.
   rune-language-rust ships the same binary name, so the shared copy is
   whichever package installed last and is deleted when either is uninstalled.
   Its rpath (`@loader_path/../lib`) also only resolves inside the package dir,
   where `bin/` and `lib/` are siblings. Keep `LLVM_VERSION` in sync with
   rune-language-rust so the colliding copy stays byte-identical.

`scripts/test.sh` pins invariants 1-3 against the built tarball.

## Versioning

This package supersedes the grammar-only `zig` package published from
rune-language-template (`v0.0.9-1-g58ab44c`), so the first release tag must sort
above it: start at `v0.0.10`.