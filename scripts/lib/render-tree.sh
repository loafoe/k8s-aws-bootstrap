# shellcheck shell=bash
# Shared helpers for rendering the bootstrap app-of-apps tree the way Argo CD does: the
# root chart, then every child Application's own chart (an OCI pull, or this repo's own
# path) with that Application's Helm values. check-appproject.sh and
# check-sync-wave-crds.sh both walk this same tree; this file exists so they can't drift
# apart on how a child gets rendered.
#
# Source this file; it only defines functions. Needs helm, yq (mikefarah v4) and jq.

RENDER_TREE_REPO_ROOT="${RENDER_TREE_REPO_ROOT:-$(git rev-parse --show-toplevel)}"

# render_root <values-file> [extra helm template args...]
# Prints the rendered root chart manifests to stdout.
render_root() {
    local values="$1"
    shift
    # shellcheck disable=SC2068
    helm template bootstrap "$RENDER_TREE_REPO_ROOT/charts/bootstrap" --namespace argocd \
        --values "$values" $@
}

# app_names <root-manifest-file>
# One Application name per line.
app_names() {
    yq 'select(.kind == "Application") | .metadata.name' "$1" | grep -v '^---$' || true
}

# app_json <root-manifest-file> <app-name> <outfile>
# Writes the named Application resource as JSON to outfile.
app_json() {
    local root="$1" app="$2" out="$3"
    yq -o=json "select(.kind == \"Application\" and .metadata.name == \"$app\")" "$root" >"$out"
}

# render_app <app-json-file> <outfile> <errfile>
# Renders the Application's child chart the way Argo CD would, with its Helm values.
# Returns non-zero (and leaves a message in errfile) if the source is neither an OCI
# chart nor this repo's own path, or if the render itself fails.
render_app() {
    local app_json="$1" out="$2" err="$3"
    local url path rev dest_ns release values_file

    url="$(jq -r '.spec.source.repoURL' "$app_json")"
    path="$(jq -r '.spec.source.path // "."' "$app_json")"
    rev="$(jq -r '.spec.source.targetRevision // ""' "$app_json")"
    dest_ns="$(jq -r '.spec.destination.namespace // ""' "$app_json")"
    release="$(jq -r '.spec.source.helm.releaseName // .metadata.name' "$app_json")"

    values_file="$(mktemp)"
    # Argo CD's rule: valuesObject when set, else the values string.
    if jq -e '.spec.source.helm.valuesObject != null' "$app_json" >/dev/null; then
        jq '.spec.source.helm.valuesObject' "$app_json" >"$values_file"
    else
        jq -r '.spec.source.helm.values // ""' "$app_json" >"$values_file"
    fi

    local chart
    if [[ "$url" == oci://* ]]; then
        chart=("$url" --version "$rev")
    elif [ "$url" = https://github.com/loafoe/k8s-aws-bootstrap ]; then
        chart=("$RENDER_TREE_REPO_ROOT/$path")
    else
        echo "source $url is neither this repo nor an OCI chart; teach render_app to render it" >"$err"
        rm -f "$values_file"
        return 2
    fi

    local rc=0
    helm template "$release" "${chart[@]}" --namespace "${dest_ns:-argocd}" --values "$values_file" \
        --include-crds --kube-version 1.35.0 \
        --api-versions monitoring.coreos.com/v1 --api-versions cert-manager.io/v1 \
        --api-versions gateway.networking.k8s.io/v1 >"$out" 2>"$err" || rc=$?
    rm -f "$values_file"
    return "$rc"
}
