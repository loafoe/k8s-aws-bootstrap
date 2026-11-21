#!/usr/bin/env bash
set -euo pipefail

# Opens a PR repointing an Argo CD Application's targetRevision at a chart
# version tag minted by scripts/mint-chart-tags.sh.
#
# Never pushes directly to main: the Application this touches runs with
# syncPolicy.automated.selfHeal, so an unreviewed direct push would deploy
# to every cluster instantly. This always goes through a PR, same as any
# other targetRevision bump.
#
# Usage:
#   ./scripts/bump-app-tag.sh <tag>
#
#   <tag> is expected to be "<chart>-<semver>" (e.g. cilium-1.20.5) or, for a
# chart that vendors more than one dependency, "<chart>-<depName>-<semver>"
# (e.g. cloudnative-pg-cloudnative-pg-0.29.2). Matched against the real
# charts/* directory list rather than guessed from the tag's string shape,
# so "spire-crds-0.6.1" resolves to chart spire-crds (not chart spire with
# a fictitious "crds" dependency) and the two-dependency case parses at
# all. Anything that doesn't match an actual chart dir this way is "not
# ours" and ignored (exit 0) rather than failing -- tags unrelated to this
# scheme (hand-made releases, etc.) must not break this.

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <tag>" >&2
    exit 2
fi

tag="$1"

# Longest chart-dir-name prefix match wins, so "spire-crds-0.6.1" prefers
# chart dir "spire-crds" over the shorter "spire".
chart=""
for chart_file in charts/*/Chart.yaml; do
    [[ -f "$chart_file" ]] || continue
    dir="$(dirname "$chart_file")"
    name="$(basename "$dir")"
    prefix="${name}-"
    [[ "$tag" == "${prefix}"* ]] || continue

    rest="${tag#"$prefix"}"
    if [[ "$rest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        : # single-dependency tag: "<chart>-<version>"
    elif [[ "$rest" =~ ^[A-Za-z0-9._-]+-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        : # multi-dependency tag: "<chart>-<depName>-<version>"
    else
        continue
    fi

    [[ "${#name}" -gt "${#chart}" ]] && chart="$name"
done

if [[ -z "$chart" ]]; then
    echo "not a chart tag, ignoring: $tag"
    exit 0
fi

mapfile -t matches < <(grep -rlE "path: charts/${chart}\$" charts/bootstrap/templates/)
if [[ "${#matches[@]}" -eq 0 ]]; then
    echo "error: no Application template sources charts/${chart}" >&2
    exit 1
elif [[ "${#matches[@]}" -gt 1 ]]; then
    echo "error: more than one Application template sources charts/${chart}: ${matches[*]}" >&2
    exit 1
fi
app_file="${matches[0]}"

current_target="$(awk '/targetRevision:[[:space:]]*/ {
    v = $0; sub(/^.*targetRevision:[[:space:]]*/, "", v); gsub(/["'"'"'[:space:]]/, "", v); print v; exit
}' "$app_file")"

if [[ "$current_target" == "$tag" ]]; then
    echo "already pinned to $tag"
    exit 0
fi

branch="bump-app-tag/${tag}"
git fetch origin main
git checkout -b "$branch" origin/main

sed -i.bak "s/targetRevision:[[:space:]]*.*/targetRevision: ${tag}/" "$app_file"
rm -f "${app_file}.bak"

./scripts/bump-chart-version.sh charts/bootstrap
./scripts/check-bootstrap-render.sh --update

git add -A
git commit -m "chore(bootstrap): pin ${chart} to ${tag}"
git push origin "$branch"

gh pr create \
    --title "chore(bootstrap): pin ${chart} to ${tag}" \
    --body "Repoints the ${chart} Application's targetRevision from ${current_target:-HEAD} to ${tag}, minted by the Mint Chart Tags workflow." \
    --base main \
    --head "$branch"
