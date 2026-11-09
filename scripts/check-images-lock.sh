#!/usr/bin/env bash
set -euo pipefail

# Fails when images.lock is out of date with the charts it describes.
#
# images.lock is the pre-cache list: every image the bootstrap charts pull, plus
# the Crossplane package artifacts (which Crossplane pulls itself and which never
# show up as a kubelet image). It is generated, never edited — see
# scripts/generate-images.sh for what goes in and why.
#
# The reason this is gated in CI: Renovate bumps a chart dependency, the rendered
# image set changes, every cluster keeps working, and the stale lock only shows up
# much later, on the first cluster that has to be bootstrapped from a mirror.
#
# Usage:
#   ./scripts/check-images-lock.sh
#
# Requires helm and yq (the CI job installs both).

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if ! ./scripts/generate-images.sh >"$tmp"; then
    echo "::error::scripts/generate-images.sh failed; cannot verify images.lock" >&2
    exit 1
fi

if ! diff -u images.lock "$tmp"; then
    cat >&2 <<'EOF'

images.lock no longer matches what the pinned charts render.

Refresh it and commit the result:

    ./scripts/generate-images.sh > images.lock

Read the diff before committing — it is the list of images a pre-cached cluster
would have been missing (or keeping needlessly). If a *chart version* changed,
bump that chart's version in charts/<name>/Chart.yaml as usual; the lock follows
the vendored artifacts, not the other way round.
EOF
    exit 1
fi

echo "✓ images.lock matches the pinned charts ($(grep -v '^#' images.lock | grep -c .) references)"
