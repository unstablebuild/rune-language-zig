#!/usr/bin/env bash
# Verifies properties of the built release artifacts. Run after `make`.
#
# Guards:
#   1. No .go source files leak into the tarball. The repo vendors the `rune`
#      Go submodule and builds extension_zig from it, so a stray copy of Go
#      sources into pkg/ would ship source into the release.
#   2. No .go source files leak into the notarization zip ($NOTARIZE_ZIP),
#      which is submitted to Apple and must contain only signed binaries.
#   3. The zig lib/ payload actually shipped (zig is useless without it).
#   4. A COPY of the zig binary, detached from its sibling lib/, works when
#      ZIG_LIB_DIR points at the packaged lib/. This is the packaging
#      regression test for config.yaml's ZIG_LIB_DIR: the installer copies
#      executables into $RUNE_DATADIR/bin, which severs zig from its lib/.
#   5. zls matches $ZLS_VERSION and shares zig's major.minor, since zls
#      hard-fails against a mismatched zig at runtime.
set -euo pipefail

TAR="${TAR:-zig.tar.gz}"
NOTARIZE_ZIP="${NOTARIZE_ZIP:-zig-notarize.zip}"
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

# The notarization zip is only produced on macOS (see the Makefile's `sign`
# target). Skip the check when it's absent rather than failing the build.
if [ -f "$NOTARIZE_ZIP" ]; then
	unzip -Z1 "$NOTARIZE_ZIP" > "$workdir/zip-members.txt"
	zip_go_files="$(grep -E '\.go$' "$workdir/zip-members.txt" || true)"
	if [ -n "$zip_go_files" ]; then
		echo "error: $NOTARIZE_ZIP contains .go source files:" >&2
		printf '%s\n' "$zip_go_files" >&2
		exit 1
	fi
	echo "ok: no .go files in $NOTARIZE_ZIP"
fi

for want in ./zig/zig ./zig/lib/std/std.zig ./bin/zls ./bin/extension_zig \
	./lib/tree-sitter.so ./lib/highlights.scm ./config.yaml; do
	if ! grep -qxF "$want" "$members"; then
		echo "error: $TAR is missing $want" >&2
		exit 1
	fi
done
echo "ok: zig toolchain, zls, extension and grammar payload present in $TAR"

tar -xzf "$TAR" -C "$workdir"

# Reproduce what the installer does: copy the binary out of the package, away
# from its sibling lib/, and drive it through ZIG_LIB_DIR.
mkdir -p "$workdir/detached"
cp "$workdir/zig/zig" "$workdir/detached/zig"
lib_dir="$workdir/zig/lib"

# A detached zig with no ZIG_LIB_DIR must fail; if this ever starts passing,
# the env var in config.yaml has become unnecessary.
if "$workdir/detached/zig" env > /dev/null 2>&1; then
	echo "error: detached zig unexpectedly found a lib dir without ZIG_LIB_DIR" >&2
	exit 1
fi

if ! ZIG_LIB_DIR="$lib_dir" "$workdir/detached/zig" env > "$workdir/zig-env.zon"; then
	echo "error: detached zig failed with ZIG_LIB_DIR=$lib_dir" >&2
	exit 1
fi
# `zig env` prints ZON and reports lib_dir relative to the cwd when that is
# shorter, so compare resolved paths rather than strings.
reported="$(sed -n 's/^[[:space:]]*\.lib_dir = "\(.*\)",$/\1/p' "$workdir/zig-env.zon")"
if [ -z "$reported" ] ||
	[ "$(cd "$reported" 2>/dev/null && pwd -P)" != "$(cd "$lib_dir" && pwd -P)" ]; then
	echo "error: 'zig env' did not report lib_dir=$lib_dir:" >&2
	cat "$workdir/zig-env.zon" >&2
	exit 1
fi
echo "ok: detached zig resolves its lib dir through ZIG_LIB_DIR"

zig_version="$(ZIG_LIB_DIR="$lib_dir" "$workdir/detached/zig" version)"
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