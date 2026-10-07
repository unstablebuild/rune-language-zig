#!/usr/bin/env bash
# Signs and checks the macOS build of a Rune language package. The same file
# is in every rune-language-* repo; keep the copies identical.
#
# Rune.app is signed with the hardened runtime and no entitlements, so macOS
# library validation lets it dlopen only libraries signed by its own team,
# $TEAM_ID. That is enforced on every load, quarantined or not, so skipping
# Gatekeeper does not avoid it: a tree-sitter.so with the linker's ad-hoc
# signature fails with "mapping process and mapped file (non-platform) have
# different Team IDs", and Rune reports that the syntax tree parser is not
# available.
#
# Packages are not notarized. Notarization only matters to Gatekeeper, which
# assesses quarantined files, and Rune installs packages without the
# quarantine attribute. The Developer ID signature is what Rune needs.
#
# Usage: macos-signing.sh <command> [args]
#   preflight             fail unless this host can sign: macOS and the
#                         Developer ID identity
#   files <dir>           list the Mach-O files under <dir> that need signing
#   sign <dir>            sign them with the Developer ID
#   check <dir> <symbol>  verify an extracted package (see check below)
#
# Environment: TEAM_ID and CODESIGN_IDENTITY; TARGET_ARCH (arm64 or amd64)
# for check.
set -euo pipefail

: "${TEAM_ID:?TEAM_ID is not set}"
: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY is not set}"

die() {
	echo "error: $*" >&2
	exit 1
}

# quiet runs a command, printing its output only if it fails.
quiet() {
	local out
	out="$("$@" 2>&1)" || {
		printf '%s\n' "$out" >&2
		return 1
	}
}

work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT

preflight() {
	[ "$(uname)" = Darwin ] ||
		die "macOS packages are signed with the Developer ID, which only a macOS host can do; on Linux, build and publish the linux packages only"
	security find-identity -v -p codesigning | grep -qF "\"$CODESIGN_IDENTITY\"" ||
		die "codesigning identity '$CODESIGN_IDENTITY' is not in the keychain"
}

# files: every Mach-O executable, dynamic library and bundle under <dir>,
# relative to it. Found by scanning rather than from a list, so a binary added
# to a package later is signed and checked too. Object files (Go's .syso, test
# fixtures) are never loaded or run, so they are not signed.
files() {
	local dir=$1 f
	# Read the magic number first: running file(1) on every file of a large
	# payload such as GOROOT takes tens of seconds.
	find "$dir" -type f -print0 |
		perl -0ne 'chomp; open(my $f, "<", $_) or next; read($f, my $m, 4);
			print "$_\0" if $m =~ /^(?:\xfe\xed\xfa[\xce\xcf]|[\xce\xcf]\xfa\xed\xfe|\xca\xfe\xba[\xbe\xbf])$/' |
		sort -z |
		while IFS= read -r -d '' f; do
			case "$(file -b "$f")" in
			*Mach-O*executable* | *Mach-O*"shared library"* | *Mach-O*bundle*)
				printf '%s\n' "${f#"$dir"/}"
				;;
			esac
		done
}

# sign replaces the linkers' ad-hoc signatures (and vendor signatures, such as
# on downloaded tools) with the Developer ID. Only the team matters to library
# validation, so there is no hardened runtime, which notarization would need.
sign() {
	local dir=$1 list
	list="$(files "$dir")"
	[ -n "$list" ] || die "no Mach-O files to sign in $dir"
	(cd "$dir" && printf '%s\n' "$list" | tr '\n' '\0' |
		xargs -0 codesign --force --sign "$CODESIGN_IDENTITY")
}

# check verifies what Rune needs from the package, independently of how it was
# built:
#   1. Every Mach-O executable, library and bundle is signed, in every
#      architecture slice, by the $TEAM_ID Developer ID (certificate chain up
#      to Apple, not just the team string).
#   2. lib/tree-sitter.so loads, for $TARGET_ARCH, into a process signed like
#      Rune.app, and <symbol> returns its language. A negative control first
#      proves that the process enforces library validation, by requiring it
#      to refuse an ad-hoc signed library. An x86_64 package is loaded under
#      Rosetta on Apple silicon.
check() {
	local dir=$1 symbol=$2 devid rel f slice n=0 failed=0
	devid="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]"
	devid="$devid and certificate leaf[field.1.2.840.113635.100.6.1.13]"
	devid="$devid and certificate leaf[subject.OU] = \"$TEAM_ID\""
	while IFS= read -r rel; do
		n=$((n + 1))
		f=$dir/$rel
		for slice in $(lipo -archs "$f"); do
			if ! codesign --verify --strict --arch "$slice" -R="$devid" "$f" 2> /dev/null; then
				echo "error: $rel ($slice) is not signed with the $TEAM_ID Developer ID" >&2
				failed=1
			fi
		done
	done < <(files "$dir")
	if [ "$n" -eq 0 ]; then
		die "no Mach-O files in $dir"
	fi
	if [ "$failed" -eq 0 ]; then
		echo "ok: $n Mach-O files are signed with the $TEAM_ID Developer ID"
	fi
	# Run the load test even after a signature failure: its error is the one
	# Rune would show.
	load "$dir/lib/tree-sitter.so" "$symbol" || failed=1
	[ "$failed" -eq 0 ]
}

load() {
	local so=$1 symbol=$2 arch out
	case "${TARGET_ARCH:?TARGET_ARCH is not set}" in
	arm64) arch=arm64 ;;
	amd64) arch=x86_64 ;;
	*) die "unsupported TARGET_ARCH '$TARGET_ARCH'" ;;
	esac
	[ -f "$so" ] || die "$so not found"
	lipo "$so" -verify_arch "$arch" || die "$so has no $arch slice"
	case "$(uname -m)-$arch" in
	arm64-x86_64)
		arch -x86_64 /usr/bin/true 2> /dev/null ||
			die "loading the x86_64 tree-sitter.so needs Rosetta: softwareupdate --install-rosetta"
		;;
	x86_64-arm64)
		die "an Intel Mac cannot run arm64 code to check that Rune loads tree-sitter.so; build darwin-arm64 on Apple silicon"
		;;
	esac

	work="$(mktemp -d)"
	# Loads a library the way Rune does (internal/ide/syntax/treesitter).
	cat > "$work/loader.c" << 'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
	void *h = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
	if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }
	if (argc < 3) return 0;
	const void *(*language)(void) = (const void *(*)(void))dlsym(h, argv[2]);
	if (!language) { fprintf(stderr, "%s\n", dlerror()); return 1; }
	if (!language()) { fprintf(stderr, "%s returned no language\n", argv[2]); return 1; }
	return 0;
}
EOF
	# check calls this under ||, which disables set -e, so fail explicitly.
	if ! {
		quiet cc -arch "$arch" -o "$work/loader" "$work/loader.c" &&
			quiet codesign --force --options runtime --timestamp=none --sign "$CODESIGN_IDENTITY" "$work/loader" &&
			echo 'int rune_control(void) { return 0; }' > "$work/control.c" &&
			quiet cc -arch "$arch" -dynamiclib -o "$work/control.dylib" "$work/control.c" &&
			quiet codesign --force --sign - "$work/control.dylib"
	}; then
		echo "error: cannot build the test loader" >&2
		return 1
	fi

	if out="$("$work/loader" "$work/control.dylib" 2>&1)" ||
		! grep -q 'code signature' <<< "$out"; then
		echo "error: the test loader does not enforce library validation, so it cannot check tree-sitter.so:" >&2
		printf '%s\n' "${out:-it loaded an ad-hoc signed library}" >&2
		return 1
	fi
	if ! out="$("$work/loader" "$so" "$symbol" 2>&1)"; then
		echo "error: Rune.app cannot load $so ($arch):" >&2
		printf '%s\n' "$out" >&2
		return 1
	fi
	echo "ok: tree-sitter.so ($arch) loads into a hardened process signed by $TEAM_ID, and $symbol returns its language"
}

cmd="${1:-}"
case "$cmd" in
preflight) preflight ;;
files | sign) [ $# -eq 2 ] || die "usage: $0 $cmd <dir>"; "$cmd" "$2" ;;
check) [ $# -eq 3 ] || die "usage: $0 check <dir> <symbol>"; check "$2" "$3" ;;
*) die "usage: $0 preflight | files <dir> | sign <dir> | check <dir> <symbol>" ;;
esac