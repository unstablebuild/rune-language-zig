#!/bin/sh
# Shim published onto PATH as `zig` in place of the real compiler.
#
# zig locates lib/ (std, compiler, libc headers) by walking up from its own
# executable path, so the compiler must run from inside the package toolchain
# dir next to its lib/. The Rune installer flat-copies every non-hidden
# executable in the package into $RUNE_DATADIR/bin, which would publish a
# severed copy of the compiler; the real binary is therefore hidden (zig/.zig,
# skipped by the installer) and only this shim reaches PATH. No ZIG_LIB_DIR is
# exported anywhere, so user-provided zig toolchains are never affected.
#
# The shim runs from two locations: the package's own bin/ dir
# (<pkg>/bin/zig) and the installer's shared copy ($RUNE_DATADIR/bin/zig,
# where lib/zig symlinks the package root).
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
for zig in "$dir/../zig/.zig" "$dir/../lib/zig/zig/.zig"; do
	if [ -x "$zig" ]; then
		exec "$zig" "$@"
	fi
done
echo "zig shim: packaged compiler not found near $dir" >&2
exit 127