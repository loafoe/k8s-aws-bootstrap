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

render() { # render <values file> [helm flags...]
    local values="$1"
    shift
    helm template bootstrap charts/bootstrap --namespace argocd --values "$values" "$@"
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
$update && exit "$status"

# environmentConfig.bootstrap.controlPlane: unset means k3s, so an explicit k3s renders the same
# manifests; any other kind is refused until the chart bootstraps it
for values in tests/render/values/*.yaml; do
    name="$(basename "$values")"
    if render "$values" --set environmentConfig.bootstrap.controlPlane=k3s | cmp -s - "tests/render/golden/$name"; then
        echo "✓ $name with controlPlane=k3s"
    else
        echo "✗ $values renders differently with controlPlane=k3s than without it." >&2
        status=1
    fi
done
fixtures=(tests/render/values/*.yaml)
values="${fixtures[0]}"
if out="$(render "$values" --set environmentConfig.bootstrap.controlPlane=eks 2>&1 >/dev/null)"; then
    echo "✗ controlPlane=eks rendered; it should be refused until the chart bootstraps it." >&2
    status=1
elif ! grep -q 'only bootstraps k3s clusters' <<<"$out"; then
    echo "✗ controlPlane=eks failed, but not with the controlPlane message: $out" >&2
    status=1
else
    echo "✓ controlPlane=eks refused"
fi
exit "$status"
