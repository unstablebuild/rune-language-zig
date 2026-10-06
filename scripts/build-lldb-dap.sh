#!/usr/bin/env bash
# Builds lldb-dap and liblldb (plus lldb-server on Linux) from the LLVM source
# release so they meet the platform floors on docs.rune.build, and packs them
# into a tarball laid out as <dir>/{bin,lib}.
#
# Usage: build-lldb-dap.sh <os> <arch> <out.tar.xz>
#
# Environment:
#   LLVM_SRC      LLVM source release tarball (llvm-project-<ver>.src.tar.xz)
#   LLVM_VERSION  version of LLVM_SRC
#   MACOS_MIN     macOS deployment target for darwin builds
#   GLIBC_MIN     glibc version linux builds link against
#   ZIG           host zig, used as the cross compiler for linux builds
#   WORK          scratch dir for sources and build trees (several GB)
#
# Upstream prebuilts miss the floors: they need macOS 14.0, and on Linux glibc
# 2.34 plus system libpython3.11, libxml2 and ncurses. This build:
#   - disables every optional dependency (Python, Lua, libedit, curses, lzma,
#     libxml2, zlib, zstd), so lldb-dap needs only libc;
#   - targets MACOS_MIN on macOS with the system clang;
#   - cross-compiles Linux with `zig cc` against GLIBC_MIN, statically linking
#     zig's libc++, so there is no libstdc++ version floor either.
# macOS ships no debugserver: lldb falls back to Apple's signed one from the
# Xcode command line tools. Linux ships lldb-server, which lldb launches from
# the bin/ directory next to lib/liblldb.
set -euo pipefail

if [ $# -ne 3 ]; then
	echo "usage: $0 <os> <arch> <out.tar.xz>" >&2
	exit 2
fi
OS=$1 ARCH=$2 OUT=$3
: "${LLVM_SRC:?}" "${LLVM_VERSION:?}" "${MACOS_MIN:?}" "${GLIBC_MIN:?}" "${WORK:?}"
for tool in cmake ninja; do
	command -v "$tool" > /dev/null || { echo "error: $tool is required to build lldb-dap" >&2; exit 1; }
done
JOBS=$(getconf _NPROCESSORS_ONLN)
# zig's linker keeps every input archive open (liblldb links ~200), past the
# 256 descriptors macOS shells allow by default.
ulimit -n 8192 2>/dev/null || ulimit -n "$(ulimit -Hn)"
# GNU tar: macOS bsdtar adds AppleDouble ._* entries to archives it creates.
TAR=$(command -v gtar || command -v tar)
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
OUT=$(cd "$(dirname "$OUT")" && pwd -P)/$(basename "$OUT")

case "$ARCH" in
amd64) LLVM_ARCH=x86_64 ;;
arm64) LLVM_ARCH=$([ "$OS" = darwin ] && echo arm64 || echo aarch64) ;;
*) echo "error: unsupported arch $ARCH" >&2; exit 1 ;;
esac

# Only the parts of the monorepo that clang and lldb need.
SRC=$WORK/src-$LLVM_VERSION
if [ ! -f "$SRC/.stamp" ]; then
	rm -rf "$SRC" && mkdir -p "$SRC"
	top=llvm-project-$LLVM_VERSION.src
	"$TAR" -xJf "$LLVM_SRC" -C "$SRC" --strip-components=1 \
		$top/llvm $top/clang $top/lldb $top/cmake $top/third-party
	touch "$SRC/.stamp"
fi

COMMON=(
	-G Ninja
	-DCMAKE_BUILD_TYPE=Release
	# WORK may sit inside another git checkout; never stamp its revision
	# into the version string.
	-DLLVM_APPEND_VC_REV=OFF
	-DLLVM_ENABLE_PROJECTS="clang;lldb"
	-DLLVM_TARGETS_TO_BUILD="AArch64;X86"
	-DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
	-DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF
	-DCLANG_INCLUDE_TESTS=OFF -DLLDB_INCLUDE_TESTS=OFF
	-DLLVM_ENABLE_BINDINGS=OFF
	-DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF
	-DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF
	-DLLDB_ENABLE_PYTHON=OFF -DLLDB_ENABLE_LUA=OFF -DLLDB_ENABLE_SWIG=OFF
	-DLLDB_ENABLE_LIBEDIT=OFF -DLLDB_ENABLE_CURSES=OFF -DLLDB_ENABLE_LZMA=OFF
	-DLLDB_ENABLE_LIBXML2=OFF -DLLDB_ENABLE_FBSDVMCORE=OFF
	-DLLDB_ENABLE_PROTOCOL_SERVERS=OFF
	-DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF
)

# Host tablegens, shared by every target build so cross builds never run
# target binaries.
HOST=$WORK/host-$LLVM_VERSION
if [ ! -f "$HOST/.stamp" ]; then
	cmake -S "$SRC/llvm" -B "$HOST" "${COMMON[@]}" > "$WORK/host-configure.log"
	ninja -C "$HOST" -j "$JOBS" llvm-tblgen llvm-min-tblgen clang-tblgen lldb-tblgen
	touch "$HOST/.stamp"
fi

TARGET=(-DLLVM_NATIVE_TOOL_DIR="$HOST/bin")
COMPONENTS=(lldb-dap liblldb)
case "$OS" in
darwin)
	TARGET+=(
		-DCMAKE_OSX_ARCHITECTURES="$LLVM_ARCH"
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
		-DLLVM_HOST_TRIPLE="$LLVM_ARCH-apple-darwin"
		# Drop local symbols at link time: stripping afterwards would
		# invalidate the linker's ad-hoc signature.
		-DCMAKE_EXE_LINKER_FLAGS="-Wl,-x" -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-x"
	)
	;;
linux)
	: "${ZIG:?is required to cross-compile linux builds}"
	ZIG=$(cd "$(dirname "$ZIG")" && pwd -P)/$(basename "$ZIG")
	TC=$WORK/toolchain-$OS-$ARCH
	mkdir -p "$TC"
	for t in cc c++; do
		printf '#!/bin/sh\nexec "%s" %s -target %s-linux-gnu.%s "$@"\n' \
			"$ZIG" "$t" "$LLVM_ARCH" "$GLIBC_MIN" > "$TC/$t"
	done
	for t in ar ranlib; do
		printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$ZIG" "$t" > "$TC/$t"
	done
	chmod +x "$TC"/*
	cat > "$TC/toolchain.cmake" <<-EOF
		set(CMAKE_SYSTEM_NAME Linux)
		set(CMAKE_SYSTEM_PROCESSOR $LLVM_ARCH)
		set(CMAKE_C_COMPILER $TC/cc)
		set(CMAKE_CXX_COMPILER $TC/c++)
		set(CMAKE_AR $TC/ar CACHE FILEPATH "")
		set(CMAKE_RANLIB $TC/ranlib CACHE FILEPATH "")
		# Never pick up libraries from the build host.
		set(CMAKE_FIND_ROOT_PATH $TC/sysroot)
		set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
		set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
		set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
		set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
	EOF
	export ZIG_GLOBAL_CACHE_DIR=$WORK/zig-cache ZIG_LOCAL_CACHE_DIR=$WORK/zig-cache
	TARGET+=(
		-DCMAKE_TOOLCHAIN_FILE="$TC/toolchain.cmake"
		-DLLVM_HOST_TRIPLE="$LLVM_ARCH-unknown-linux-gnu"
		# zig cc emits DWARF by default; the link strips it anyway (-s), so
		# skip it to keep the build tree around 1GB instead of 8GB.
		-DCMAKE_C_FLAGS="-g0" -DCMAKE_CXX_FLAGS="-g0"
		-DCMAKE_EXE_LINKER_FLAGS="-s" -DCMAKE_SHARED_LINKER_FLAGS="-s"
	)
	COMPONENTS+=(lldb-server)
	;;
*)
	echo "error: unsupported os $OS" >&2
	exit 1
	;;
esac

BUILD=$WORK/$OS-$ARCH
cmake -S "$SRC/llvm" -B "$BUILD" "${COMMON[@]}" "${TARGET[@]}" \
	-DCMAKE_INSTALL_PREFIX="$BUILD/install" > "$WORK/$OS-$ARCH-configure.log"
ninja -C "$BUILD" -j "$JOBS" "${COMPONENTS[@]}"
rm -rf "$BUILD/install"
for c in "${COMPONENTS[@]}"; do
	cmake --install "$BUILD" --component "$c" > /dev/null
done

# Pack bin/ and lib/ under a top-level dir, like the upstream LLVM tarballs.
name=$(basename "$OUT" .tar.xz)
rm -rf "$WORK/$name" && mkdir -p "$WORK/$name"
cp -a "$BUILD/install/bin" "$BUILD/install/lib" "$WORK/$name/"
"$TAR" -cJf "$OUT.part" -C "$WORK" "$name"
mv "$OUT.part" "$OUT"
echo "built $OUT"