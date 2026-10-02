#!/usr/bin/env bash
set -euo pipefail

# Fails when a chart's hand-authored content changed without a version bump.
#
# Scope is deliberately limited to values.yaml and templates/ -- the files a
# human writes. Dependency changes (a dependency version in Chart.yaml,
# Chart.lock, and the vendored charts/*.tgz) are bumped automatically by
# scripts/helm-deps-sync.sh and .github/workflows/helm-deps.yaml in the same
# commit, so demanding a bump for those too would only race with that tooling.
#
# Usage:
#   ./scripts/check-chart-version-bump.sh [base-ref]
#
#   base-ref defaults to origin/main. The diff covers that base against the
#   working tree, the index, and untracked files, so the script works both as
#   a pre-commit hook and as a CI check on a pull request.

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

base="${1:-origin/main}"

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
    echo "error: base ref '$base' not found" >&2
    exit 1
fi

changed_files() {
    {
        git diff --name-only "$base" --
        git diff --cached --name-only
        git ls-files --others --exclude-standard
    } | sort -u
}

# Top-level version of a chart at a given ref, empty if the file or the
# version is not there.
version_at() {
    local ref="$1" path="$2" content
    # A chart that does not exist at $ref has no version yet; an empty result
    # is correct and must not abort the script under `set -e`.
    content="$(git show "$ref:$path" 2>/dev/null)" || return 0
    printf '%s\n' "$content" | awk '/^version:[[:space:]]*/ {
        v = $0; sub(/^version:[[:space:]]*/, "", v); gsub(/["'"'"'[:space:]]/, "", v); print v; exit
    }'
}

version_of() {
    awk '/^version:[[:space:]]*/ {
        v = $0; sub(/^version:[[:space:]]*/, "", v); gsub(/["'"'"'[:space:]]/, "", v); print v; exit
    }' "$1"
}

# True when $2 is a strictly higher major.minor.patch than $1. Unparseable
# versions are reported as increased so this check never becomes the reason a
# legitimate change is rejected.
version_increased() {
    local before="${1#v}" after="${2#v}"

    # All three components must be captured in the same `local` statement: a
    # separate declaration clears BASH_REMATCH and would silently zero them.
    [[ "$before" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 0
    local b0="${BASH_REMATCH[1]}" b1="${BASH_REMATCH[2]}" b2="${BASH_REMATCH[3]}"
    [[ "$after" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 0
    local a0="${BASH_REMATCH[1]}" a1="${BASH_REMATCH[2]}" a2="${BASH_REMATCH[3]}"

    if   ((a0 != b0)); then ((a0 > b0))
    elif ((a1 != b1)); then ((a1 > b1))
    else                     ((a2 > b2))
    fi
}

mapfile -t changed < <(changed_files)

# chart dir -> human authored files that changed
declare -A content_changed=()
declare -a chart_dirs=()

for file in "${changed[@]}"; do
    # Only charts under charts/<name>/
    [[ "$file" =~ ^charts/([^/]+)/ ]] || continue
    dir="charts/${BASH_REMATCH[1]}"

    rel="${file#"$dir"/}"
    case "$rel" in
        values.yaml|templates/*)
            content_changed["$dir"]+="$rel "
            ;;
    esac

    # remember the chart once per dir, in first-seen order
    seen=0
    for known in "${chart_dirs[@]:-}"; do
        [[ "$known" == "$dir" ]] && seen=1 && break
    done
    [[ $seen -eq 0 ]] && chart_dirs+=("$dir")
done

if [[ ${#chart_dirs[@]} -eq 0 ]]; then
    echo "No chart content changed relative to $base."
    exit 0
fi

failed=0
for dir in "${chart_dirs[@]}"; do
    [[ -n "${content_changed[$dir]:-}" ]] || continue

    chart_file="$dir/Chart.yaml"
    if [[ ! -f "$chart_file" ]]; then
        echo "error: $chart_file referenced by changes but not present" >&2
        failed=1
        continue
    fi

    before="$(version_at "$base" "$chart_file")"
    after="$(version_of "$chart_file")"

    if [[ "$before" == "$after" ]]; then
        {
            echo "chart version not bumped: $dir"
            echo "  changed: ${content_changed[$dir]% }"
            echo "  version: still $after (unchanged since $base)"
            echo "  fix:     scripts/bump-chart-version.sh $dir"
        } >&2
        failed=1
        continue
    fi

    # A different value is not necessarily a bump: catch 1.0.0 -> 0.9.0 too.
    if [[ -n "$before" ]] && ! version_increased "$before" "$after"; then
        {
            echo "chart version did not increase: $dir"
            echo "  changed: ${content_changed[$dir]% }"
            echo "  version: $before -> $after"
            echo "  fix:     scripts/bump-chart-version.sh $dir"
        } >&2
        failed=1
    fi
done

if [[ $failed -ne 0 ]]; then
    echo >&2
    echo "One or more charts changed without a version bump." >&2
    exit 1
fi

echo "All changed chart content has a matching version bump."
