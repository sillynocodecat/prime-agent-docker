#!/bin/sh
# Resolve the Prime Agent release to build (CI metadata job; also runnable locally).
#
# Uses GitHub's "latest published release" API — never the numerically largest
# tag and never the moving `beta` tag — validates a plain vX.Y.Z tag that is
# neither a draft nor a prerelease, and resolves that exact tag to its peeled
# commit through `git ls-remote`. Prints `tag=`, `version=`, `revision=` lines
# and appends them to $GITHUB_OUTPUT when set.
#
# Environment: UPSTREAM_REPO (default PrimeIntellect-ai/prime-agent),
# GITHUB_TOKEN (optional, raises the API rate limit), PIN_TAG (optional: build
# this exact release tag instead of the latest one; still validated).
set -eu
REPO=${UPSTREAM_REPO:-PrimeIntellect-ai/prime-agent}
die() { printf 'resolve-upstream: %s\n' "$*" >&2; exit 1; }
for t in curl jq git; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
auth=""; [ -z "${GITHUB_TOKEN:-}" ] || auth="Authorization: Bearer $GITHUB_TOKEN"
api() { curl -fsSL -H "Accept: application/vnd.github+json" ${auth:+-H "$auth"} "https://api.github.com/repos/$REPO/$1"; }

if [ -n "${PIN_TAG:-}" ]; then
  json=$(api "releases/tags/$PIN_TAG") || die "release $PIN_TAG not found"
else
  json=$(api "releases/latest") || die "cannot query the latest release of $REPO"
fi
tag=$(printf '%s' "$json" | jq -r '.tag_name // empty')
draft=$(printf '%s' "$json" | jq -r '.draft')
prerelease=$(printf '%s' "$json" | jq -r '.prerelease')
[ -n "$tag" ] || die "release has no tag_name"
printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "release tag is not a plain vX.Y.Z: $tag"
[ "$draft" = false ] || die "release $tag is a draft"
[ "$prerelease" = false ] || die "release $tag is a prerelease"

# Peel the tag to its commit (annotated tags list a second `^{}` line).
refs=$(git ls-remote --tags "https://github.com/$REPO.git" "refs/tags/$tag" "refs/tags/$tag^{}") || die "git ls-remote failed"
revision=$(printf '%s\n' "$refs" | awk '$2 == "refs/tags/'"$tag"'^{}" { print $1 }')
[ -n "$revision" ] || revision=$(printf '%s\n' "$refs" | awk '$2 == "refs/tags/'"$tag"'" { print $1 }')
[ -n "$revision" ] || die "tag $tag does not exist in $REPO"
printf '%s' "$revision" | grep -Eq '^[0-9a-f]{40}$' || die "unexpected revision for $tag: $revision"

version=${tag#v}
printf 'tag=%s\nversion=%s\nrevision=%s\n' "$tag" "$version" "$revision"
if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'tag=%s\nversion=%s\nrevision=%s\n' "$tag" "$version" "$revision" >>"$GITHUB_OUTPUT"; fi
