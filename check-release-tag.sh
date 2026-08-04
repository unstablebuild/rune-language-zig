#!/bin/bash
# Validate that HEAD carries a release tag the in-product upgrader will
# accept, before any expensive build/notarize work runs. Invoked as the
# first prerequisite of the dist-* make targets.
#
# Rules (kept in sync with the ide upgrade manager):
#   - version must match canonical semver ("vMAJOR[.MINOR[.PATCH]][-pre][+build]")
#     as accepted by golang.org/x/mod/semver.
#   - no dirty/distance suffix from `git describe` (-dirty, -<N>-g<sha>):
#     those parse as pre-release labels and compare in surprising ways.
#
# NOTE: this package supersedes the grammar-only `zig` package published from
# rune-language-template (v0.0.9-1-g58ab44c), so the first release tag must sort
# above it: start at v0.0.10 or later.
set -e

GIT_TAG=$(git describe --tags --dirty)

if [[ ! "$GIT_TAG" =~ ^v[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo "ERROR: tag '${GIT_TAG}' is not canonical semver (e.g. v1.2.3 or v1.2.3-beta.1)."
    echo "       The in-product upgrader (golang.org/x/mod/semver) will refuse it."
    exit 1
fi
case "$GIT_TAG" in
    *-dirty|*-dirty+*)
        echo "ERROR: tag '${GIT_TAG}' has a dirty suffix; commit or stash before publishing."
        exit 1
        ;;
esac
if [[ "$GIT_TAG" =~ -[0-9]+-g[0-9a-f]+$ ]]; then
    echo "ERROR: tag '${GIT_TAG}' looks like an untagged describe output (-N-g<sha>); tag the commit first."
    exit 1
fi