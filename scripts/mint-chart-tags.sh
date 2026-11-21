#!/usr/bin/env bash
set -euo pipefail

# Mints an immutable tag the moment a wrapper chart's version pair (its
# vendored dependency's version, plus its own wrapper version) changes to
# something that isn't tagged yet.
#
# Tag shape for a chart with exactly one dependency: "<chart>-<depVersion>-
# <wrapperVersion>" (e.g. "cilium-1.20.5-0.1.5") -- the upstream version
# leads, for a human reading targetRevision in the Argo CD UI, but the
# wrapper version is still part of the tag so a hand-authored wrapper fix
# (values.yaml/templates, no dependency bump) still mints a new tag.
# bump-chart-version.sh bumps the wrapper's own version on every change to
# the chart, dependency bump or hand-authored fix alike (helm-deps.yaml
# calls it after re-vendoring; check-chart-version-bump.sh requires it in
# CI for the hand-authored case), so without that suffix a wrapper-only fix
# would never mint a new tag at all, and a pinned Application would stay on
# an older tag forever -- a silent non-deploy, not caught until after this
# design's first real rollout. For a chart with zero or more than one
# dependency, there is no single upstream version to lead with, so the tag
# is just "<chart>-<wrapperVersion>" (bump-app-tag.sh's chart-dir-prefix
# matching handles either shape the same way; it does not care which
# number or numbers follow the chart name).
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

# Emit "name<TAB>version" for every entry of the dependencies: block of a
# Chart.yaml. Stops at the next top-level key. (Copied from
# scripts/check-chart-deps.sh's dump_deps.)
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
minted_tags=()

for chart_file in charts/*/Chart.yaml; do
    [[ -f "$chart_file" ]] || continue
    dir="$(dirname "$chart_file")"
    chart_name="$(basename "$dir")"

    # Only wrapper charts (something vendored under dependencies:) are this
    # scheme's concern.
    grep -q '^dependencies:' "$chart_file" || continue

    wrapper_version="$(version_of "$chart_file")"
    [[ -n "$wrapper_version" ]] || continue

    mapfile -t deps < <(dump_deps "$chart_file")
    if [[ "${#deps[@]}" -eq 1 ]]; then
        dep_version="${deps[0]#*$'\t'}"
        tag="${chart_name}-${dep_version}-${wrapper_version}"
    else
        tag="${chart_name}-${wrapper_version}"
    fi

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
    if git tag -a "$tag" -m "${chart_name} wrapper ${wrapper_version}" "$sha" && git push origin "$tag"; then
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
