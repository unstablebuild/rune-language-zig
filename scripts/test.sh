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
#      $MACOS_MIN, ELF glibc symbol versions <= $GLIBC_MIN. They also link
#      nothing beyond the OS: glibc's own libraries on Linux, /usr/lib and
#      /System on macOS, plus the packaged liblldb. Upstream lldb-dap
#      prebuilts failed both (macOS 14.0; glibc 2.34, libstdc++, libpython).
#   7. macOS targets: Rune.app can load the package. Every Mach-O file, found
#      by scanning, is signed with the $TEAM_ID Developer ID; and
#      tree-sitter.so loads into a process signed like Rune.app, whose library
#      validation refuses a tree-sitter.so signed by any other team (or
#      ad-hoc). This runs for both macOS architectures on any Apple silicon
#      host, x86_64 under Rosetta (scripts/macos-signing.sh check).
#   8. lldb-dap debugs a zig program from the package layout, as config.yaml
#      runs it: it stops at a breakpoint and reads a local (scripts/dapsmoke).
#
# Guards 3, 4 and 8 execute the packaged binaries, so they
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
if [ "$TARGET_OS" = darwin ]; then
	TEAM_ID="${TEAM_ID:?}"
	CODESIGN_IDENTITY="${CODESIGN_IDENTITY:?}"
fi

if [ ! -f "$TAR" ]; then
	echo "error: $TAR not found; run 'make' first" >&2
	exit 1
fi

# Resolved (macOS mktemp lives under the /var -> /private/var symlink): the
# lldb-dap check matches breakpoint paths verbatim against debug info.
workdir="$(cd "$(mktemp -d)" && pwd -P)"
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
	./lib/tree-sitter.so ./lib/highlights.scm ./bin/lldb-dap ./config.yaml; do
	if ! grep -qxF "$want" "$members"; then
		echo "error: $TAR is missing $want" >&2
		exit 1
	fi
done
echo "ok: zig toolchain, zls, extension, grammar and lldb-dap payload present in $TAR"

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

# Every shipped executable and shared library (liblldb's symlinks excluded).
binaries="zig/.zig bin/zls bin/extension_zig lib/tree-sitter.so bin/lldb-dap"
for f in "$workdir"/lib/liblldb.*; do
	[ -L "$f" ] || binaries="$binaries lib/${f##*/}"
done
if [ "$TARGET_OS" = linux ]; then
	binaries="$binaries bin/lldb-server"
fi

for f in $binaries; do
	if [ ! -f "$workdir/$f" ]; then
		echo "error: $TAR is missing $f" >&2
		exit 1
	fi
	case "$TARGET_OS" in
	darwin)
		minos="$(otool -l "$workdir/$f" | awk '$1 == "minos" {print $2}' | sort_versions | tail -1)"
		if [ -z "$minos" ] || ! version_le "$minos" "$MACOS_MIN"; then
			echo "error: $f requires macOS ${minos:-<unknown>}, above the $MACOS_MIN floor" >&2
			exit 1
		fi
		foreign="$(otool -L "$workdir/$f" | tail -n +2 | awk '{print $1}' |
			{ grep -vE '^(/usr/lib/|/System/Library/|@rpath/liblldb\.)' || true; })"
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
		foreign="$({ objdump -p "$workdir/$f" 2>/dev/null || true; } | awk '$1 == "NEEDED" {print $2}' |
			{ grep -vE '^(libc|libm|libdl|libpthread|librt|libutil)\.so\.[0-9]+$|^ld-linux-(x86-64|aarch64)\.so\.[0-9]+$|^liblldb\.so\.' || true; })"
		;;
	esac
	if [ -n "$foreign" ]; then
		echo "error: $f links libraries outside the OS:" $foreign >&2
		exit 1
	fi
done
echo "ok: binaries meet the $TARGET_OS floor (macOS $MACOS_MIN / glibc $GLIBC_MIN) and link only OS libraries"

if [ "$TARGET_OS" = darwin ]; then
	TEAM_ID="$TEAM_ID" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" TARGET_ARCH="$TARGET_ARCH" \
		"$(dirname "$0")/macos-signing.sh" check "$workdir" tree_sitter_zig
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

# lldb-dap must load liblldb from its package-local sibling lib/, which is
# the path config.yaml's debugger command uses, and debug a zig program:
# macOS through Apple's debugserver, Linux through the packaged lldb-server.
if ! "$workdir/bin/lldb-dap" --help > /dev/null 2>&1; then
	echo "error: packaged lldb-dap cannot run from its package layout" >&2
	"$workdir/bin/lldb-dap" --help >&2 || true
	exit 1
fi
mkdir -p "$workdir/debug"
printf '%s\n' 'const std = @import("std");' '' 'pub fn main() void {' \
	'    var x: u32 = 41;' '    x += 1;' '    std.mem.doNotOptimizeAway(x);' '}' > "$workdir/debug/main.zig"
(
	cd "$workdir/debug"
	ZIG_GLOBAL_CACHE_DIR="$workdir/zig-cache" "$workdir/bin/zig" build-exe -femit-bin=debuggee main.zig
)
(cd "$(dirname "$0")/dapsmoke" && go build -o "$workdir/dapsmoke" .)
if ! "$workdir/dapsmoke" -adapter "$workdir/bin/lldb-dap" -program "$workdir/debug/debuggee" \
	-source "$workdir/debug/main.zig" -line 5 -var x=41 > "$workdir/dapsmoke.log" 2>&1; then
	echo "error: packaged lldb-dap failed to debug a zig program:" >&2
	cat "$workdir/dapsmoke.log" >&2
	exit 1
fi
echo "ok: lldb-dap debugs a zig program from the package layout ($(tail -1 "$workdir/dapsmoke.log"))"