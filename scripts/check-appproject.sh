#!/usr/bin/env bash
# Checks that the bootstrap AppProject (charts/bootstrap/templates/argo-cd/appproject.yaml)
# permits everything the root and its child Applications deploy. Argo CD refuses a whole sync
# when one resource is outside the project, and the root is in the project it renders, so a
# gap here blocks the root's own sync on every cluster.
#
# For each fixture in tests/render/values (and the optional features on top of each), it
# renders charts/bootstrap, then every child Application the way Argo CD does (its chart
# with its Helm values; OCI charts are pulled), and fails on:
#   - an Application outside the project, or with a source/destination the project lacks
#   - a resource in a namespace the project lacks (child charts write outside their
#     Application's namespace too, e.g. cilium-secrets, kube-system)
#
# Needs helm, yq (mikefarah v4) and jq.
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CACHE_HOME="$work/helm-cache"
# shellcheck source=lib/render-tree.sh
source scripts/lib/render-tree.sh

variants=(
    ""
    "--set features.hspAwsPlatform.cloudnativePg.enabled=true --set features.gatewayApi.httproutes.grafana=true --set features.kubePrometheusStack.grafana.enabled=true --set features.kyverno.requireImageDigest.enabled=true"
    "--set features.shutdown.enabled=true"
)

status=0
fail() { echo "✗ $*" >&2; status=1; }

# resources <file>: "<namespace>\t<kind>/<name>" for every resource with an explicit namespace
resources() {
    yq -o=json -I=0 'select(.kind != null and .metadata.namespace != null) | [.metadata.namespace, .kind + "/" + .metadata.name]' "$1" \
        | grep '^\[' | jq -r 'select(length > 0) | @tsv' || true
}

for values in tests/render/values/*.yaml; do
    for variant in "${variants[@]}"; do
        label="$(basename "$values")${variant:+ (${variant//--set /})}"
        root="$work/root.yaml"
        # shellcheck disable=SC2086
        render_root "$values" $variant >"$root"

        project="$(yq 'select(.kind == "AppProject" and .metadata.namespace == "argocd") | .metadata.name' "$root" | grep -v '^---$' | head -1 || true)"
        if [ -z "$project" ]; then
            fail "$label: charts/bootstrap renders no AppProject"
            continue
        fi
        proj="$work/project.json"
        yq -o=json "select(.kind == \"AppProject\" and .metadata.name == \"$project\")" "$root" >"$proj"
        allowed_ns="$(jq -r '.spec.destinations[] | select(.server == "https://kubernetes.default.svc" or .name == "in-cluster") | .namespace' "$proj")"
        allowed_repos="$(jq -r '.spec.sourceRepos[]' "$proj")"
        ns_ok() { grep -qxF "$1" <<<"$allowed_ns" || grep -qxF '*' <<<"$allowed_ns"; }

        grep -qxF https://github.com/loafoe/k8s-aws-bootstrap <<<"$allowed_repos" \
            || fail "$label: the project does not permit the root's own source (this repo)"
        ns_ok argocd || fail "$label: the project does not permit the root's destination namespace argocd"

        while IFS=$'\t' read -r ns what; do
            ns_ok "$ns" || fail "$label: root resource $what is in namespace $ns, not permitted in project $project"
        done < <(resources "$root")

        apps="$(app_names "$root")"
        for app in $apps; do
            app_json "$root" "$app" "$work/app.json"
            app_project="$(jq -r '.spec.project' "$work/app.json")"
            url="$(jq -r '.spec.source.repoURL' "$work/app.json")"
            dest_ns="$(jq -r '.spec.destination.namespace // ""' "$work/app.json")"

            [ "$app_project" = "$project" ] || fail "$label: Application $app is in project $app_project, not $project"
            grep -qxF "$url" <<<"$allowed_repos" || fail "$label: Application $app's source $url is not permitted in project $project"
            [ -z "$dest_ns" ] || ns_ok "$dest_ns" || fail "$label: Application $app's destination namespace $dest_ns is not permitted in project $project"

            out="$work/child.yaml"
            if ! render_app "$work/app.json" "$out" "$work/child.err"; then
                fail "$label: Application $app does not render: $(head -c 500 "$work/child.err")"
                continue
            fi
            while IFS=$'\t' read -r ns what; do
                ns_ok "$ns" || fail "$label: $app's $what is in namespace $ns, not permitted in project $project"
            done < <(resources "$out")
        done
        [ "$status" -eq 0 ] && echo "✓ $label"
    done
done
exit "$status"
