#!/usr/bin/env bash
set -euo pipefail

# Bumps the patch level of a chart's own `version:` in Chart.yaml.
#
# Every chart in charts/ is a wrapper that pins upstream charts as
# dependencies. Helm treats the vendored tarballs under charts/<name>/charts/
# together with the wrapper's own values.yaml and templates/ as the chart
# artifact, so every one of those changes alters the chart without altering
# anything that "0.1.0" used to describe. Bumping the wrapper version keeps it
# an accurate identifier of the artifact.
#
# Only the top-level `version:` is touched: dependency versions are indented
# and never match the `^version:` anchor.
#
# Usage:
#   ./scripts/bump-chart-version.sh <chart-dir>...
#   git diff --cached --name-only | grep Chart.yaml | xargs -n1 dirname | xargs ./scripts/bump-chart-version.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"

read_version() {
    # Top-level version only. Fails loudly if the chart has none.
    awk '/^version:[[:space:]]*/ {
        v = $0; sub(/^version:[[:space:]]*/, "", v); gsub(/["'"'"']/, "", v); gsub(/[[:space:]]/, "", v)
        print v; exit
    }' "$1"
}

bump_chart_version() {
    local chart_file="$1"
    local current next major minor patch prefix=""

    current="$(read_version "$chart_file")"
    if [[ -z "$current" ]]; then
        echo "error: no top-level 'version:' in $chart_file" >&2
        return 1
    fi

    [[ "$current" == v* ]] && prefix="v"

    if [[ ! "$current" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "error: cannot bump '$current' in $chart_file (expected major.minor.patch)" >&2
        return 1
    fi

    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    next="${prefix}${major}.${minor}.$((patch + 1))"

    # Rewrite the single top-level version line, leaving every other byte alone.
    awk -v new="$next" '
        !done && /^version:[[:space:]]*/ {
            print "version: " new
            done = 1
            next
        }
        { print }
    ' "$chart_file" > "$chart_file.bak"
    mv "$chart_file.bak" "$chart_file"

    echo "  bumped $(basename "$(dirname "$chart_file")"): $current -> $next"
}

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <chart-dir>..." >&2
    exit 2
fi

for dir in "$@"; do
    [[ "$dir" == /* ]] || dir="$REPO_ROOT/$dir"
    if [[ ! -f "$dir/Chart.yaml" ]]; then
        echo "error: no Chart.yaml in $dir" >&2
        exit 1
    fi
    bump_chart_version "$dir/Chart.yaml"
done
