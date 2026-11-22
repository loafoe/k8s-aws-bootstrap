#!/usr/bin/env bash
# Fails when a resource is synced at an Argo CD wave earlier than (or the same as) the
# wave that installs its API group's CRD -- the bug class from the crossplane-providers
# VPA incident: crossplane-providers-aws (wave 18) rendered a VerticalPodAutoscaler, but
# the vertical-pod-autoscaler app that installs that CRD runs at wave 21. Argo CD's
# resource-discovery step failed validation for the *whole* app before anything in it
# ever applied, which blocked everything after it, including the ArgoCD HTTPRoute.
#
# For each fixture in tests/render/values, renders charts/bootstrap, then every child
# Application the way Argo CD does (scripts/lib/render-tree.sh; OCI charts are pulled),
# and for every resource whose API group is not a Kubernetes built-in:
#   - fails if the group is not listed in scripts/crd-providers.yaml at all -- that file
#     is the map of which wave installs which group, and an unlisted group means either
#     this script or that file is now out of date with what the charts render;
#   - fails if the resource's own wave (its owning Application's root sync-wave) is <=
#     the wave crd-providers.yaml records for that group, unless the resource or its
#     whole Application opts out with
#     argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true.
#
# Needs helm, yq (mikefarah v4) and jq.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib/render-tree.sh
source scripts/lib/render-tree.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CACHE_HOME="$work/helm-cache"

providers_file="scripts/crd-providers.yaml"
builtin_groups=(
    "" apps batch rbac.authorization.k8s.io policy storage.k8s.io networking.k8s.io
    admissionregistration.k8s.io apiextensions.k8s.io scheduling.k8s.io
    coordination.k8s.io events.k8s.io discovery.k8s.io node.k8s.io certificates.k8s.io
    authentication.k8s.io authorization.k8s.io autoscaling apiregistration.k8s.io
)

variants=(
    ""
    "--set features.hspAwsPlatform.cloudnativePg.enabled=true --set features.gatewayApi.httproutes.grafana=true --set features.kubePrometheusStack.grafana.enabled=true --set features.kyverno.requireImageDigest.enabled=true"
    "--set features.shutdown.enabled=true"
)

status=0
fail() { echo "✗ $*" >&2; status=1; }

is_builtin() {
    local g="$1" b
    for b in "${builtin_groups[@]}"; do
        [ "$g" = "$b" ] && return 0
    done
    return 1
}

# group_of <apiVersion>
group_of() {
    case "$1" in
    */*) echo "${1%/*}" ;;
    *) echo "" ;;
    esac
}

# provider_entry <group>: prints "wave<TAB>providedBy" from crd-providers.yaml, matching
# an exact group first, then a "*suffix" pattern. Empty output means no match.
provider_entry() {
    local g="$1" pattern wave provided_by line
    line="$(yq -o=json ".groups[] | select(.group == \"$g\")" "$providers_file" \
        | jq -rs 'if length == 0 then "" else [.[0].wave, .[0].providedBy] | @tsv end')"
    if [ -n "$line" ]; then
        echo "$line"
        return
    fi
    while IFS=$'\t' read -r pattern wave provided_by; do
        [ -n "$pattern" ] || continue
        # shellcheck disable=SC2254  # deliberate glob: pattern comes from crd-providers.yaml
        case "$g" in
        $pattern) echo -e "$wave\t$provided_by" && return ;;
        esac
    done < <(yq -o=json '.groups[] | select(.group | test("\\*"))' "$providers_file" | jq -r '[.group, .wave, .providedBy] | @tsv')
}

# has_skip_option <json-file> <jq path to syncOptions array>
has_skip_option() {
    jq -e "(${2} // []) | index(\"SkipDryRunOnMissingResource=true\") != null" "$1" >/dev/null 2>&1
}

# check_one_resource <label> <what> <api-version> <wave> <resource-skip: true|false>
#                     <app-skip: 0|1> <context: current Application's name, or "root">
check_one_resource() {
    local label="$1" what="$2" api_version="$3" wave="$4" resource_skip="$5" app_skip="$6" context="$7"
    local group pwave provided_by
    group="$(group_of "$api_version")"
    is_builtin "$group" && return 0
    [ "$app_skip" = 1 ] && return 0
    [ "$resource_skip" = "true" ] && return 0

    IFS=$'\t' read -r pwave provided_by < <(provider_entry "$group")
    if [ -z "$pwave" ]; then
        echo -e "$label\t$what\t$group\t$wave\tUNKNOWN" >>"$work/violations"
        return 0
    fi
    [ "$provided_by" = "$context" ] && return 0
    if [ "$wave" -le "$pwave" ]; then
        echo -e "$label\t$what\t$group\t$wave\t$pwave" >>"$work/violations"
    fi
}

# check_root_resources <manifest-file> <label>
# Each resource runs at its own sync-wave annotation (default 0).
check_root_resources() {
    local manifest="$1" label="$2" resfile="$work/res.json"
    yq -o=json 'select(.kind != null and .apiVersion != null)' "$manifest" >"$resfile"
    local api_version kind name resource_skip wave
    while IFS=$'\t' read -r api_version kind name wave resource_skip; do
        [ -n "$api_version" ] || continue
        check_one_resource "$label" "$kind/$name" "$api_version" "${wave:-0}" "$resource_skip" 0 root
    done < <(jq -r '[.apiVersion, .kind, .metadata.name, (.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0"), ((.metadata.annotations["argocd.argoproj.io/sync-options"] // "") | contains("SkipDryRunOnMissingResource=true"))] | @tsv' "$resfile")
}

# check_app_resources <manifest-file> <effective-wave> <label> <app-level-skip: 0|1>
# Every resource here runs as part of its owning Application's single sync, at that
# Application's root wave -- its own intra-app sync-wave annotation (if any) only orders
# it relative to siblings inside the same app, not relative to other Applications.
check_app_resources() {
    local manifest="$1" wave="$2" label="$3" app_skip="$4" app_name="$5" resfile="$work/res.json"
    yq -o=json 'select(.kind != null and .apiVersion != null)' "$manifest" >"$resfile"
    local api_version kind name resource_skip
    while IFS=$'\t' read -r api_version kind name resource_skip; do
        [ -n "$api_version" ] || continue
        check_one_resource "$label" "$kind/$name" "$api_version" "$wave" "$resource_skip" "$app_skip" "$app_name"
    done < <(jq -r '[.apiVersion, .kind, .metadata.name, ((.metadata.annotations["argocd.argoproj.io/sync-options"] // "") | contains("SkipDryRunOnMissingResource=true"))] | @tsv' "$resfile")
}

: >"$work/violations"

for values in tests/render/values/*.yaml; do
    for variant in "${variants[@]}"; do
        label="$(basename "$values")${variant:+ (${variant//--set /})}"
        root="$work/root.yaml"
        # shellcheck disable=SC2086
        render_root "$values" $variant >"$root"

        # Root-level resources (not Application/AppProject) run in the root app's own
        # sync, each at its own sync-wave annotation.
        root_only="$work/root-only.yaml"
        yq 'select(.kind != "Application" and .kind != "AppProject")' "$root" >"$root_only"
        check_root_resources "$root_only" "$label: root"

        for app in $(app_names "$root"); do
            app_json "$root" "$app" "$work/app.json"
            app_wave="$(jq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0"' "$work/app.json")"
            app_skip=0
            has_skip_option "$work/app.json" '.spec.syncPolicy.syncOptions' && app_skip=1

            out="$work/child.yaml"
            if ! render_app "$work/app.json" "$out" "$work/child.err"; then
                fail "$label: Application $app does not render: $(head -c 300 "$work/child.err")"
                continue
            fi
            check_app_resources "$out" "$app_wave" "$label: $app" "$app_skip" "$app"
        done
    done
done

if [ -s "$work/violations" ]; then
    status=1
    echo "Resources synced before their API group's CRD is installed:" >&2
    echo >&2
    while IFS=$'\t' read -r label what group wave pwave; do
        if [ "$pwave" = UNKNOWN ]; then
            echo "  $label: $what uses group '$group' (wave $wave), which is not in $providers_file -- add it" >&2
        else
            echo "  $label: $what uses group '$group' at wave $wave, but $providers_file says it's installed at wave $pwave" >&2
        fi
    done <"$work/violations" | sort -u
    echo >&2
    echo "Fix by: moving the resource (or its Application) to a later wave, adding" >&2
    echo "  argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true" >&2
    echo "to the resource (or the whole Application's syncOptions if it's a vendored" >&2
    echo "chart you can't annotate directly), or updating $providers_file." >&2
else
    echo "✓ every resource's API group is available by the wave it syncs at"
fi

exit "$status"
