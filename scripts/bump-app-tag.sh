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
#   <tag> is expected to be "<chart>-<semver>", e.g. cilium-1.20.5. Anything
# that doesn't parse that way, or whose chart directory doesn't exist, is
# treated as "not ours" and ignored (exit 0) rather than failing -- tags
# unrelated to this scheme (hand-made releases, etc.) must not break this.

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <tag>" >&2
    exit 2
fi

tag="$1"

if [[ ! "$tag" =~ ^(.+)-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "not a chart tag, ignoring: $tag"
    exit 0
fi
chart="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[2]}"

if [[ ! -f "charts/${chart}/Chart.yaml" ]]; then
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
