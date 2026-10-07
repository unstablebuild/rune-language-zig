# rune-language-zig

Rune language package for Zig: the `zig` toolchain, `zls`, `extension_zig`,
the tree-sitter grammar and `lldb-dap`, shipped as one tarball
published to the `zig` package id.

To install Zig support in Rune, run this command in the Rune console:

```text
pkg install zig
```

The release instructions below are for Rune maintainers.

## Release runbook

1. **Prepare the build host.** A Mac builds all four platforms; a Linux host
   builds only the Linux ones, so `release-all` and `dist-<env>-all` fail on
   Linux. Install Go, Xcode command line tools (macOS),
   `wget`, `xz`, GNU tar (`gtar` on macOS), `objdump`, `cmake`, `ninja` and
   `bluectl`. `extension_zig` is pure Go, and the Linux grammar and `lldb-dap`
   are cross-compiled by a downloaded `zig cc` against glibc 2.28, so no other
   toolchain is needed.
   The macOS `tree-sitter.so` is signed with the `Developer ID Application:
   Unstable Build, LLC. (YYZRWD888J)` identity, so the Mac needs that identity
   in its keychain. Rune.app runs with the hardened runtime, which refuses to
   load a `tree-sitter.so` signed by any other team. The other binaries run as
   separate processes and keep their linker or vendor signatures. Packages are
   not notarized: Rune installs them without the quarantine attribute, so
   Gatekeeper never assesses them.
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out a clean, tagged release commit (`v0.0.10` or later). The `dist-*` targets
   reject untagged, dirty, or non-semver releases. Authenticate `bluectl` via
   gcloud Application Default Credentials and set `BLUE_PGP_KEY` and
   `BLUE_PGP_KEYRING` (see `bluectl release upload -h`).
3. **Publish** every platform to an environment:

   ```sh
   make dist-staging-all
   make dist-prod-all
   ```

   `dist-<env>-all` builds and tests all four platforms into
   `build/<os>-<arch>/zig.tar.gz` and uploads only if every one passes.
   `dist-<env>-<os>-<arch>` (e.g. `dist-prod-linux-amd64`) releases a single
   platform, and `release-all` / `release-<os>-<arch>` build and test without
   uploading. `make test` checks for `.go` source
   leaks, the glibc 2.28 and macOS 13.3 floors, OS-only library dependencies,
   and, for macOS, that Rune.app can load the package: `tree-sitter.so` is
   Developer ID-signed and loads into a process signed like Rune.app, x86_64
   under Rosetta, and every binary is intact and validly signed
   (`scripts/macos-signing.sh`, shared by every language repo). For the host
   platform it also runs the packaged binaries, including a real `lldb-dap`
   debug session.
   Downloads are cached in `downloads/` (`make
   distclean` removes them), as is `lldb-dap`, which is built from the LLVM
   source release by `scripts/build-lldb-dap.sh`: the first build takes about
   10 minutes per platform on a 16-core Mac. Each upload selects the pinned
   project and per-platform release bucket from `deploy/bluectl/`; do not run
   `dist.sh` directly.

## Payload layout

```
pkg/
  config.yaml
  zig/{.zig, lib/**}         # compiler (hidden) + its 225MB lib (std, libc, compiler-rt)
  bin/{zig, zls, extension_zig, lldb-dap}   # zig is the zig-shim.sh wrapper
  bin/lldb-server            # Linux only; macOS uses Apple's debugserver
  lib/{tree-sitter.so, highlights.scm, indents.scm, folds.scm, locals.scm}
  lib/liblldb.*
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
   where `bin/` and `lib/` are siblings. On Linux, lldb launches the
   `lldb-server` next to it (`<liblldb dir>/../bin`); on macOS it falls back to
   the signed `debugserver` from the Xcode command line tools, which macOS
   debugging therefore requires.

`scripts/test.sh` pins invariants 1-3 against the built tarball, including a
real `zig build` through the shim from a simulated `$RUNE_DATADIR` and a debug
session through the package-local `lldb-dap`.
