GIT_REMOTE_URL=$(git remote get-url origin)
GIT_AUTHOR_EMAIL=$(git log -1 --pretty=format:'%ae')
GIT_TAG=$(git describe --tags --dirty)
GIT_HEAD=$(git rev-parse HEAD)
BLUE_RELEASE_TAR=zig.tar.gz
: "${BLUECTL_CONFIG_DIR:?BLUECTL_CONFIG_DIR is not set. Use the dist-<env>-<os>-<arch> make targets (e.g. dist-prod-darwin-arm64) so the bluectl project-id is pinned to the right environment.}"
BLUE_EXEC=(bluectl -c "$BLUECTL_CONFIG_DIR")
OS="${BLUE_TARGET_OS:-$(uname | awk '{print tolower($0)}')}"
ARCH="${BLUE_TARGET_ARCH:-$([ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] && echo "arm64" || uname -m)}"
case "$ARCH" in
	x86_64) ARCH=amd64 ;;
	aarch64) ARCH=arm64 ;;
esac
BLUE_RELEASE_TAG="$GIT_TAG"

echo "Pushing tarball for OS '$OS' and arch '$ARCH'";

if [[ -z "${BLUE_PGP_KEY}" ]]; then
    echo "BLUE_PGP_KEY is not set. See bluectl release upload -h for help."
	exit 1;
fi

if [[ -z "${BLUE_PGP_KEYRING}" ]]; then
    echo "BLUE_PGP_KEYRING is not set. See bluectl release upload -h for help."
	exit 1;
fi

blue_release_dist() {
	GIT_LOG=$(git log --pretty=format:"%h: %s" $GIT_LOG_RANGE)
	printf "\n$GIT_LOG\n";

	echo "uploading $BLUE_RELEASE_TAG"
	"${BLUE_EXEC[@]}" release upload \
		-d target-os=$OS \
		-d target-arch=$ARCH \
		-d git-remote-url=$GIT_REMOTE_URL \
		-d git-author-email=$GIT_AUTHOR_EMAIL \
		-d git-tag=$GIT_TAG -d git-head=$GIT_HEAD \
		-d git-log="$GIT_LOG" \
		-y \
		-k $BLUE_PGP_KEY \
		-r $BLUE_PGP_KEYRING zig $BLUE_RELEASE_TAG $BLUE_RELEASE_TAR
}

# check if HEAD is tagged; if not, use annotate with range between latest tag and HEAD
git describe --contains 2>&1 1> /dev/null;
if [ $? -ne 0 ];
then
	GIT_LOG_RANGE="$(git tag -l --sort=-version:refname | head -1)...HEAD";
	printf "using git range between latest tag and latest tag + added commits: $GIT_LOG_RANGE:";
	blue_release_dist;
else
	GIT_LOG_RANGE="$(git tag -l --sort=-version:refname | head -2 | xargs | sed 's/ /.../g')";
	printf "using git range between latest tags: $GIT_LOG_RANGE:";
	blue_release_dist;
fi