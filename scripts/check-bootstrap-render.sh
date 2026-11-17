#!/usr/bin/env bash
# Renders charts/bootstrap with each fixture in tests/render/values and compares the
# manifests to tests/render/golden. A change that leaves them identical changes nothing a
# cluster gets: use it to show a refactor (or a new switch that defaults to the current
# behaviour) is a no-op. A change meant to alter the output regenerates them:
#
#   scripts/check-bootstrap-render.sh --update   # then review the diff of tests/render/golden
#
# The fixtures are what a k3s-on-ec2 cluster passes (see the header of each). Needs helm.
set -euo pipefail

cd "$(dirname "$0")/.."
update=false
[ "${1:-}" = "--update" ] && update=true

render() { # render <values file>
    helm template bootstrap charts/bootstrap --namespace argocd --values "$1"
}

status=0
mkdir -p tests/render/golden
for values in tests/render/values/*.yaml; do
    name="$(basename "$values")"
    golden="tests/render/golden/$name"
    rendered="$(mktemp)"
    trap 'rm -f "$rendered"' EXIT
    render "$values" >"$rendered"
    if $update; then
        cp "$rendered" "$golden"
        echo "updated $golden"
    elif ! diff -u "$golden" "$rendered" >&2; then
        echo "✗ charts/bootstrap renders differently for $values than $golden." >&2
        echo "  If that is intended, run scripts/check-bootstrap-render.sh --update and review the diff." >&2
        status=1
    else
        echo "✓ $name"
    fi
    rm -f "$rendered"
done
exit "$status"
