#!/usr/bin/env bash
set -euo pipefail

# Syncs Helm dependencies for charts with modified Chart.yaml files.
# - Removes stale .tgz files
# - Runs helm dependency update
# - Stages the resulting changes
#
# Usage:
#   As pre-commit hook: symlink or copy to .git/hooks/pre-commit
#   Manually: ./scripts/helm-deps-sync.sh [chart-dir...]

REPO_ROOT="$(git rev-parse --show-toplevel)"

sync_chart() {
    local chart_dir="$1"
    local charts_subdir="$chart_dir/charts"

    if [[ ! -f "$chart_dir/Chart.yaml" ]]; then
        return 0
    fi

    # Check if this chart has dependencies
    if ! grep -q '^dependencies:' "$chart_dir/Chart.yaml" 2>/dev/null; then
        return 0
    fi

    echo "Syncing dependencies for $chart_dir"

    # Remove old tarballs
    rm -f "$charts_subdir"/*.tgz 2>/dev/null || true

    # Update dependencies
    helm dependency update "$chart_dir" --skip-refresh

    # Stage the charts directory changes
    git add "$charts_subdir" 2>/dev/null || true
    git add "$chart_dir/Chart.lock" 2>/dev/null || true
}

if [[ $# -gt 0 ]]; then
    # Manual mode: sync specified directories
    for dir in "$@"; do
        sync_chart "$dir"
    done
else
    # Pre-commit mode: find staged Chart.yaml files
    changed_charts=$(git diff --cached --name-only --diff-filter=ACM | grep 'Chart\.yaml$' || true)

    if [[ -z "$changed_charts" ]]; then
        exit 0
    fi

    for chart_file in $changed_charts; do
        chart_dir="$REPO_ROOT/$(dirname "$chart_file")"
        sync_chart "$chart_dir"
    done
fi
