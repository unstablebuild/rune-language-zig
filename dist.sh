#!/usr/bin/env bash
# Uploads build/<os>-<arch>/zig.tar.gz as a release of the `zig` package.
#
# Usage: dist.sh <prod|staging> <os> <arch>
#
# Do not run this directly: the make dist-* targets build and test the tarball
# first. <env> selects the pinned bluectl project and the per-platform release
# bucket under deploy/bluectl/.
set -eu
cd "$(dirname "$0")"

if [ $# -ne 3 ]; then
	echo "usage: $0 <prod|staging> <os> <arch>" >&2
	exit 2
fi
ENV=$1 OS=$2 ARCH=$3
BLUECTL_CONFIG_DIR="deploy/bluectl/$ENV/$OS-$ARCH"
BLUE_RELEASE_TAR="build/$OS-$ARCH/zig.tar.gz"
if [ ! -f "$BLUECTL_CONFIG_DIR/config" ]; then
	echo "error: no bluectl config at $BLUECTL_CONFIG_DIR" >&2
	exit 1
fi
if [ ! -f "$BLUE_RELEASE_TAR" ]; then
	echo "error: $BLUE_RELEASE_TAR not found; use the make dist-* targets" >&2
	exit 1
fi
: "${BLUE_PGP_KEY:?is not set. See bluectl release upload -h for help.}"
: "${BLUE_PGP_KEYRING:?is not set. See bluectl release upload -h for help.}"

GIT_REMOTE_URL=$(git remote get-url origin)
GIT_AUTHOR_EMAIL=$(git log -1 --pretty=format:'%ae')
GIT_TAG=$(git describe --tags --dirty)
GIT_HEAD=$(git rev-parse HEAD)

# If HEAD is tagged, log the range between the latest two tags; otherwise
# between the latest tag and HEAD.
if git describe --contains >/dev/null 2>&1; then
	GIT_LOG_RANGE=$(git tag -l --sort=-version:refname | head -2 | xargs | sed 's/ /.../g')
else
	GIT_LOG_RANGE="$(git tag -l --sort=-version:refname | head -1)...HEAD"
fi
GIT_LOG=$(git log --pretty=format:"%h: %s" "$GIT_LOG_RANGE")

echo "uploading zig $GIT_TAG for $OS/$ARCH to $ENV ($GIT_LOG_RANGE)"
printf '%s\n' "$GIT_LOG"
bluectl -c "$BLUECTL_CONFIG_DIR" release upload \
	-d target-os="$OS" \
	-d target-arch="$ARCH" \
	-d git-remote-url="$GIT_REMOTE_URL" \
	-d git-author-email="$GIT_AUTHOR_EMAIL" \
	-d git-tag="$GIT_TAG" -d git-head="$GIT_HEAD" \
	-d git-log="$GIT_LOG" \
	-y \
	-k "$BLUE_PGP_KEY" \
	-r "$BLUE_PGP_KEYRING" zig "$GIT_TAG" "$BLUE_RELEASE_TAR"