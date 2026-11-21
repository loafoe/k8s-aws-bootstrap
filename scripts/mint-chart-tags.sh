#!/usr/bin/env bash
set -euo pipefail

# Mints an immutable tag the moment a wrapper chart's vendored dependency
# reaches a version that isn't tagged yet.
#
# Tag-existence-driven, not before/after-driven: this script takes no
# event-derived input (no before/after SHAs, no commit list) and only reads
# the current checkout. Whether the tag already exists IS the idempotency
# rule, and it is also what makes a version bump and its vendoring fix work
# correctly even when they land in two separate pushes (helm-deps.yaml's
# main-branch recovery path pushes outside any PR) -- the push that only
# bumps Chart.yaml finds vendoring inconsistent and mints nothing; a later
# push that fixes vendoring has no Chart.yaml change of its own, but still
# finds the tag missing and mints it then.
#
# Usage:
#   ./scripts/mint-chart-tags.sh [--dry-run]

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
fi

# Emit "name<TAB>version" for every entry of the dependencies: block of a
# Chart.yaml. Stops at the next top-level key. (Copied from
# scripts/check-chart-deps.sh's dump_deps -- each script here owns its own
# awk helpers rather than sharing a lib.)
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

minted=0
failed=0

for chart_file in charts/*/Chart.yaml; do
    [[ -f "$chart_file" ]] || continue
    dir="$(dirname "$chart_file")"
    chart_name="$(basename "$dir")"

    grep -q '^dependencies:' "$chart_file" || continue

    mapfile -t deps < <(dump_deps "$chart_file")
    dep_count="${#deps[@]}"
    [[ "$dep_count" -gt 0 ]] || continue

    for entry in "${deps[@]}"; do
        dep_name="${entry%%$'\t'*}"
        version="${entry#*$'\t'}"

        if [[ "$dep_count" -eq 1 ]]; then
            tag="${chart_name}-${version}"
        else
            tag="${chart_name}-${dep_name}-${version}"
        fi

        if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
            echo "  ${tag}: already exists, skipping"
            continue
        fi

        if ! ./scripts/check-chart-deps.sh "$dir" >/dev/null 2>&1; then
            echo "  ${dir}: not fully vendored yet, skipping"
            continue
        fi

        sha="$(git log --first-parent -1 --format=%H -- "$dir")"

        if [[ "$dry_run" == true ]]; then
            echo "  would tag ${tag} at ${sha}"
            minted=$((minted + 1))
            continue
        fi

        # One chart's tag failing to push (e.g. a rejected push, a transient
        # network error) must not stop every other chart from being tagged
        # in this same run -- isolate the failure, keep going, and report it
        # at the end instead of letting `set -e` abort the whole script.
        if git tag -a "$tag" -m "${chart_name} ${version}" "$sha" && git push origin "$tag"; then
            echo "  tagged ${tag} at ${sha}"
            minted=$((minted + 1))
        else
            echo "  ${tag}: failed to tag/push, see above" >&2
            git tag -d "$tag" >/dev/null 2>&1 || true
            failed=$((failed + 1))
        fi
    done
done

if [[ "$minted" -gt 0 ]]; then
    echo "Minted ${minted} tag(s)."
else
    echo "No new tags."
fi

if [[ "$failed" -gt 0 ]]; then
    echo "${failed} tag(s) failed to push; see errors above." >&2
    exit 1
fi
