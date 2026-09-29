# rune-language-zig

Rune language package for Zig: the `zig` toolchain, `zls`, `extension_zig`,
the tree-sitter grammar and `lldb-dap`, shipped as one signed tarball
published to the `zig` package id.

To install Zig support in Rune, run this command in the Rune console:

```text
pkg install zig
```

The release instructions below are for Rune maintainers.

## Release runbook

1. **Prepare the build host.** Build macOS (`darwin`) artifacts on macOS and
   Linux artifacts on Linux; only the architecture can be cross-built. Install
   Go, a C compiler, `wget`, `bluectl`, and tar (GNU `gtar` on macOS). Linux
   cross-architecture builds need the target GNU compiler
   (`aarch64-linux-gnu-gcc` or `x86_64-linux-gnu-gcc`). macOS releases need the
   configured Developer ID signing identity and a notarytool profile
   (`make notary-credentials` to set it up).
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out a clean, tagged release commit (`v0.0.10` or later). The `dist-*` targets
   reject untagged, dirty, or non-semver releases. Authenticate `bluectl` via
   gcloud Application Default Credentials and set `BLUE_PGP_KEY` and
   `BLUE_PGP_KEYRING` (see `bluectl release upload -h`).
3. **Publish** with the target matching the environment, OS, and architecture:

   ```sh
   make dist-staging-darwin-arm64   # on macOS
   make dist-prod-darwin-amd64      # on macOS
   make dist-staging-linux-arm64    # on Linux
   make dist-prod-linux-amd64       # on Linux
   ```

   All `staging`/`prod` × `darwin`/`linux` × `arm64`/`amd64` combinations
   follow this naming pattern. Each target checks the tag, cleans, builds,
   signs/notarizes on macOS, runs `make test` (including `.go` source-leak
   checks on the tarball and notarization zip), then uploads `zig.tar.gz` via
   `dist.sh`. It selects the pinned project and per-platform release bucket
   from `deploy/bluectl/`; do not run `dist.sh` directly. Run a separate target
   for each architecture. The `darwin-amd64` package omits `lldb-dap` because
   LLVM 22 has no official macOS x86_64 prebuilt.

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
