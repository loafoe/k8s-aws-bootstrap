#!/usr/bin/env bash
set -euo pipefail

# Fails when a chart's vendored dependencies do not match what it declares.
#
# Every dependency in Chart.yaml has to be vendored under charts/<name>/charts/
# at the declared version, and Chart.lock must not pin anything that is not
# vendored. Renovate only rewrites the version in Chart.yaml; the vendored
# tarballs and Chart.lock are filled in afterwards by
# .github/workflows/helm-deps.yaml. When that workflow fails the PR still looks
# complete, so this check is what keeps a half-updated chart from being merged.
#
# Usage:
#   ./scripts/check-chart-deps.sh [chart-dir...]
#
#   With no arguments every chart under charts/ is checked.

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Emit "name<TAB>version" for every entry of a Chart.lock, or of the
# dependencies: block of a Chart.yaml. Stops at the next top-level key.
dump_deps() {
    awk '
        /^[[:space:]]*#/ { next }
        /^dependencies:[[:space:]]*$/ { in_deps = 1; next }
        /^[A-Za-z]/ { if (in_deps) exit; next }
        in_deps && /name:[[:space:]]*/ {
            n = $0; sub(/^.*name:[[:space:]]*/, "", n); gsub(/[^A-Za-z0-9._-]/, "", n); name = n
        }
        in_deps && /version:[[:space:]]*/ {
            v = $0; sub(/^.*version:[[:space:]]*/, "", v); gsub(/[^0-9A-Za-z.+-]/, "", v)
            if (name != "") { print name "\t" v; name = "" }
        }
    ' "$1"
}

# Succeeds when every dependency declared in Chart.yaml is vendored at the
# right version AND Chart.lock agrees with what is vendored.
deps_in_sync() {
    local dir="$1"
    local bad dep_name dep_version

    grep -q '^dependencies:' "$dir/Chart.yaml" || return 0

    # Let helm do the version comparison rather than reconstructing filenames:
    # helm normalises the v prefix when naming tarballs (crossplane v2.4.2 ->
    # crossplane-2.4.2.tgz).
    # NB: helm pads the STATUS column and emits a trailing blank line, hence
    # the NF > 1 guard.
    bad=$(helm dependency list "$dir" 2>/dev/null |
        awk 'NR > 1 && NF > 1 && $NF != "ok" { sub(/^[[:space:]]+/, ""); print }')
    if [[ -n "$bad" ]]; then
        echo "    Chart.yaml declares versions that are not vendored:"
        echo "$bad" | sed 's/^/      /'
        return 1
    fi

    # Chart.lock must not pin versions we do not have vendored either.
    if [[ -f "$dir/Chart.lock" ]]; then
        while IFS=$'\t' read -r dep_name dep_version; do
            [[ -n "$dep_name" ]] || continue
            if [[ ! -f "$dir/charts/${dep_name}-${dep_version}.tgz" ]]; then
                echo "    Chart.lock pins ${dep_name}-${dep_version} but that tarball is not vendored"
                return 1
            fi
        done < <(dump_deps "$dir/Chart.lock")
    fi

    return 0
}

if [[ $# -gt 0 ]]; then
    dirs=("$@")
else
    dirs=()
    for chart in charts/*/Chart.yaml; do
        [[ -f "$chart" ]] && dirs+=("$(dirname "$chart")")
    done
fi

failed=0
for dir in "${dirs[@]}"; do
    dir="${dir%/}"
    if [[ ! -f "$dir/Chart.yaml" ]]; then
        echo "error: no Chart.yaml in $dir" >&2
        exit 2
    fi
    if ! deps_in_sync "$dir"; then
        echo "  out of sync: $dir"
        failed=1
    fi
done

if [[ $failed -ne 0 ]]; then
    echo >&2
    echo "One or more charts have dependencies that are not vendored." >&2
    echo "fix: ./scripts/helm-deps-sync.sh <chart-dir>, or wait for the" >&2
    echo "     Update Helm Dependencies workflow to push its artifacts commit." >&2
    exit 1
fi

echo "All chart dependencies are vendored at their declared versions."
