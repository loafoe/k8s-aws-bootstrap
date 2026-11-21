#!/usr/bin/env bash
set -euo pipefail

# Mints an immutable tag the moment a wrapper chart's own version changes
# to something that isn't tagged yet.
#
# Tagged by the WRAPPER chart's own top-level `version:`, not the vendored
# dependency's version: bump-chart-version.sh bumps that field on every
# change to the chart -- a dependency bump (helm-deps.yaml calls it after
# re-vendoring) and a hand-authored values.yaml/templates fix alike
# (check-chart-version-bump.sh requires it in CI). Tagging by the
# dependency's version instead would miss the hand-authored case entirely:
# a wrapper-only fix doesn't change that number, so no new tag would ever
# be minted for it, and the Application would stay pinned to an older tag
# forever once pinned -- a silent non-deploy, not caught until after the
# first real rollout. Tagging by the wrapper's own version also means every
# wrapper has exactly one tag-worthy version regardless of how many
# dependencies it vendors, so there is no multi-dependency tag-name case to
# handle here (bump-app-tag.sh still parses the older
# "<chart>-<depName>-<version>" shape too, for tags minted before this
# change, or any hand-made equivalent -- it does not care which number a
# tag's suffix is, only that a real chart dir prefixes it).
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
case "${1:-}" in
    "") ;;
    --dry-run) dry_run=true ;;
    *)
        echo "usage: $0 [--dry-run]" >&2
        exit 2
        ;;
esac

# Top-level `version:` of a chart. (Same single-line-match style as
# version_of() in scripts/check-chart-version-bump.sh -- each script here
# owns its own awk helpers rather than sharing a lib.)
version_of() {
    awk '/^version:[[:space:]]*/ {
        v = $0; sub(/^version:[[:space:]]*/, "", v); gsub(/["'"'"'[:space:]]/, "", v); print v; exit
    }' "$1"
}

minted=0
failed=0
minted_tags=()

for chart_file in charts/*/Chart.yaml; do
    [[ -f "$chart_file" ]] || continue
    dir="$(dirname "$chart_file")"
    chart_name="$(basename "$dir")"

    # Only wrapper charts (something vendored under dependencies:) are this
    # scheme's concern.
    grep -q '^dependencies:' "$chart_file" || continue

    version="$(version_of "$chart_file")"
    [[ -n "$version" ]] || continue

    tag="${chart_name}-${version}"

    if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
        echo "  ${tag}: already exists, skipping"
        continue
    fi

    vendor_check="$(./scripts/check-chart-deps.sh "$dir" 2>&1)" || {
        echo "  ${dir}: not fully vendored yet, skipping"
        echo "$vendor_check" | sed 's/^/    /'
        continue
    }

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
        minted_tags+=("$tag")
    else
        echo "  ${tag}: failed to tag/push, see above" >&2
        git tag -d "$tag" >/dev/null 2>&1 || true
        failed=$((failed + 1))
    fi
done

if [[ "$minted" -gt 0 ]]; then
    echo "Minted ${minted} tag(s)."
else
    echo "No new tags."
fi

# Called directly here, after tagging is fully done, rather than relying on
# bump-app-tag.yaml's own push:tags: trigger: GitHub does not start a new
# workflow run for a ref pushed with the default GITHUB_TOKEN (its built-in
# anti-recursion rule), confirmed experimentally -- a tag pushed by this
# same credential at a brand new commit still didn't fire it. bump-app-tag.sh
# switches branches as part of its own work, so it must run only after every
# chart in the loop above has already been evaluated against a stable
# checkout; calling it mid-loop would corrupt every later chart's
# `git log --first-parent -- "$dir"` result.
repoint_failed=0
if [[ "$dry_run" != true ]]; then
    for tag in "${minted_tags[@]:-}"; do
        [[ -n "$tag" ]] || continue
        if ! ./scripts/bump-app-tag.sh "$tag"; then
            echo "  ${tag}: bump-app-tag.sh failed, see above" >&2
            repoint_failed=$((repoint_failed + 1))
        fi
    done
fi

if [[ "$failed" -gt 0 || "$repoint_failed" -gt 0 ]]; then
    echo "${failed} tag(s) failed to push, ${repoint_failed} repoint(s) failed; see errors above." >&2
    exit 1
fi
