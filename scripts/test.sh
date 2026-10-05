#!/usr/bin/env bash
# Verifies properties of a built release tarball. Run through `make test`,
# which builds the tarball and passes the variables below.
#
# Guards:
#   1. No .go source files leak into the tarball. The repo vendors the `rune`
#      Go submodule and builds extension_zig from it, so a stray copy of Go
#      sources into pkg/ would ship source into the release.
#   2. The zig lib/ payload actually shipped (zig is useless without it).
#   3. The real compiler is hidden (zig/.zig) so the installer's flat bin-copy
#      cannot publish a copy severed from lib/, and the bin/zig shim runs it
#      from both install locations: the package's own bin/ and the shared
#      $RUNE_DATADIR/bin (simulated with a fake data dir + lib/zig symlink).
#      A real `zig build` must succeed through the shared-location shim.
#   4. zls matches $ZLS_VERSION and shares zig's major.minor, since zls
#      hard-fails against a mismatched zig at runtime.
#   5. config.yaml exports no ZIG_LIB_DIR: gui.env leaks into every zig run
#      inside Rune, and the env var would pin user-provided toolchains (e.g. a
#      dev compiler) to this package's std lib.
#   6. Binaries meet the platform floors on docs.rune.build: Mach-O minos <=
#      $MACOS_MIN, ELF glibc symbol versions <= $GLIBC_MIN. lldb-dap and
#      liblldb are not checked: the upstream LLVM prebuilts need macOS 14.0,
#      and glibc 2.34 plus a system libpython3.11.
#   7. darwin-arm64 Mach-O files carry a valid ad-hoc signature. This is not
#      Developer ID signing or notarization: the arm64 kernel kills any code
#      without a valid signature on exec, quarantined or not. The build signs
#      nothing and relies on the ad-hoc signature each linker embeds, which
#      any post-link edit (strip, install_name_tool, ...) would invalidate.
#
# Guards 3 and 4 and the lldb-dap check execute the packaged binaries, so they
# only run when RUN_BINARIES=1 (the tarball targets the host platform).
set -euo pipefail

TAR="${TAR:?}"
TARGET_OS="${TARGET_OS:?}"
TARGET_ARCH="${TARGET_ARCH:?}"
MACOS_MIN="${MACOS_MIN:?}"
GLIBC_MIN="${GLIBC_MIN:?}"
RUN_BINARIES="${RUN_BINARIES:-0}"
ZIG_VERSION="${ZIG_VERSION:-}"
ZLS_VERSION="${ZLS_VERSION:-}"

if [ ! -f "$TAR" ]; then
	echo "error: $TAR not found; run 'make' first" >&2
	exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# List archive members. Matches the build's gtar invocation (entries are
# relative to pkg/, e.g. ./bin/extension_zig). Kept in a file: `grep -q` exits
# on the first match, which would SIGPIPE a feeding printf under pipefail.
members="$workdir/members.txt"
tar -tzf "$TAR" > "$members"

go_files="$(grep -E '\.go$' "$members" || true)"
if [ -n "$go_files" ]; then
	echo "error: $TAR contains .go source files:" >&2
	printf '%s\n' "$go_files" >&2
	exit 1
fi

echo "ok: no .go files in $TAR"

for want in ./zig/.zig ./zig/lib/std/std.zig ./bin/zig ./bin/zls ./bin/extension_zig \
	./lib/tree-sitter.so ./lib/highlights.scm ./config.yaml; do
	if ! grep -qxF "$want" "$members"; then
		echo "error: $TAR is missing $want" >&2
		exit 1
	fi
done
echo "ok: zig toolchain, zls, extension and grammar payload present in $TAR"

# The real compiler must ship hidden-only: a non-hidden executable named zig
# outside bin/ would be flat-copied over the shim in $RUNE_DATADIR/bin.
if grep -qxF ./zig/zig "$members"; then
	echo "error: $TAR ships a non-hidden ./zig/zig; the installer would publish it over the shim" >&2
	exit 1
fi

tar -xzf "$TAR" -C "$workdir"

if grep -qE '^[[:space:]]*ZIG_LIB_DIR' "$workdir/config.yaml"; then
	echo "error: packaged config.yaml sets ZIG_LIB_DIR; it leaks into user-provided zig toolchains" >&2
	exit 1
fi
echo "ok: no ZIG_LIB_DIR exported"

# sort_versions: sorts dotted versions numerically (BSD and GNU sort alike).
sort_versions() { sort -t. -k1,1n -k2,2n -k3,3n; }
# version_le A B: true if dotted version A <= B.
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort_versions | head -1)" = "$1" ]; }

for f in zig/.zig bin/zls bin/extension_zig lib/tree-sitter.so; do
	case "$TARGET_OS" in
	darwin)
		minos="$(otool -l "$workdir/$f" | awk '$1 == "minos" {print $2}' | sort_versions | tail -1)"
		if [ -z "$minos" ] || ! version_le "$minos" "$MACOS_MIN"; then
			echo "error: $f requires macOS ${minos:-<unknown>}, above the $MACOS_MIN floor" >&2
			exit 1
		fi
		;;
	linux)
		command -v objdump > /dev/null || { echo "error: objdump is required to check glibc floors" >&2; exit 1; }
		# Static binaries have no dynamic symbols, so objdump may fail on them.
		glibc="$({ objdump -T "$workdir/$f" 2>/dev/null || true; } |
			{ grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/^GLIBC_//' | sort_versions | tail -1)"
		if [ -n "$glibc" ] && ! version_le "$glibc" "$GLIBC_MIN"; then
			echo "error: $f requires glibc $glibc, above the $GLIBC_MIN floor" >&2
			exit 1
		fi
		;;
	esac
done
echo "ok: binaries meet the $TARGET_OS floor (macOS $MACOS_MIN / glibc $GLIBC_MIN)"

if [ "$TARGET_OS-$TARGET_ARCH" = darwin-arm64 ]; then
	for f in zig/.zig bin/zls bin/extension_zig lib/tree-sitter.so bin/lldb-dap lib/liblldb.*.dylib; do
		[ -e "$workdir/$f" ] || continue
		if ! codesign --verify "$workdir/$f" 2>/dev/null; then
			echo "error: $f has no valid ad-hoc signature; the arm64 kernel kills it on exec" >&2
			exit 1
		fi
	done
	echo "ok: every darwin-arm64 binary carries a valid ad-hoc signature"
fi

if [ "$RUN_BINARIES" != 1 ]; then
	echo "skip: $TAR targets another platform; not running its binaries"
	exit 0
fi

lib_dir="$workdir/zig/lib"

# Reproduce the installed layout: the shim is flat-copied into a shared bin
# dir, and lib/zig symlinks the package root (the installer's lib/<pkg-id>
# convention). The shim must find the hidden compiler through that symlink.
fdd="$workdir/fakedatadir"
mkdir -p "$fdd/bin" "$fdd/lib"
cp "$workdir/bin/zig" "$fdd/bin/zig"
ln -s "$workdir" "$fdd/lib/zig"

if ! "$fdd/bin/zig" env > "$workdir/zig-env.zon" 2>&1; then
	echo "error: shim in shared bin failed to run the packaged compiler:" >&2
	cat "$workdir/zig-env.zon" >&2
	exit 1
fi
# `zig env` prints ZON and reports lib_dir relative to the cwd when that is
# shorter, so compare resolved paths rather than strings.
reported="$(sed -n 's/^[[:space:]]*\.lib_dir = "\(.*\)",$/\1/p' "$workdir/zig-env.zon")"
if [ -z "$reported" ] ||
	[ "$(cd "$reported" 2>/dev/null && pwd -P)" != "$(cd "$lib_dir" && pwd -P)" ]; then
	echo "error: shim-run zig did not resolve lib_dir=$lib_dir:" >&2
	cat "$workdir/zig-env.zon" >&2
	exit 1
fi
echo "ok: shared-bin shim resolves the packaged lib dir with no ZIG_LIB_DIR"

# End-to-end: a real project builds and runs through the shared-location shim.
mkdir -p "$workdir/proj"
(
	cd "$workdir/proj"
	ZIG_GLOBAL_CACHE_DIR="$workdir/zig-cache" "$fdd/bin/zig" init > /dev/null 2>&1
	ZIG_GLOBAL_CACHE_DIR="$workdir/zig-cache" "$fdd/bin/zig" build
	./zig-out/bin/proj > /dev/null 2>&1 || true
)
echo "ok: zig build succeeds through the shim"

# Package-local invocation (<pkg>/bin/zig), the shim's other install location.
zig_version="$("$workdir/bin/zig" version)"
if [ -n "$ZIG_VERSION" ] && [ "$zig_version" != "$ZIG_VERSION" ]; then
	echo "error: packaged zig is $zig_version, expected $ZIG_VERSION" >&2
	exit 1
fi

zls_version="$("$workdir/bin/zls" --version)"
if [ -n "$ZLS_VERSION" ] && [ "$zls_version" != "$ZLS_VERSION" ]; then
	echo "error: packaged zls is $zls_version, expected $ZLS_VERSION" >&2
	exit 1
fi

# zls refuses to serve a zig whose major.minor differs from its own.
zig_mm="$(printf '%s' "$zig_version" | cut -d. -f1,2)"
zls_mm="$(printf '%s' "$zls_version" | cut -d. -f1,2)"
if [ "$zig_mm" != "$zls_mm" ]; then
	echo "error: zls $zls_version does not match zig $zig_version (major.minor must agree)" >&2
	exit 1
fi
echo "ok: zig $zig_version and zls $zls_version are a matched pair"

# lldb-dap ships everywhere except darwin-amd64 (no official LLVM prebuilt).
# When present, it must load liblldb from its package-local sibling lib/,
# which is the path config.yaml's debugger command uses.
if [ -f "$workdir/bin/lldb-dap" ]; then
	if ! "$workdir/bin/lldb-dap" --help > /dev/null 2>&1; then
		echo "error: packaged lldb-dap cannot run from its package layout" >&2
		"$workdir/bin/lldb-dap" --help >&2 || true
		exit 1
	fi
	echo "ok: lldb-dap runs from the package bin/ + lib/ layout"
fi