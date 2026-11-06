# Gateway API CRDs v1.6.3 (Standard Channel Bundle)
#
# These CRDs are installed when .Values.features.gatewayApi.enabled is true.
#
# Included CRDs (Standard channel, from standard-install.yaml):
# - backendtlspolicies.yaml
# - gatewayclasses.yaml
# - gateways.yaml
# - grpcroutes.yaml
# - httproutes.yaml
# - listenersets.yaml
# - referencegrants.yaml
# - tcproutes.yaml
# - tlsroutes.yaml
# - udproutes.yaml
#
# Included ValidatingAdmissionPolicy (also shipped by standard-install.yaml):
# - safe-upgrades-vap.yaml — blocks re-installing Experimental-channel CRDs
#   on top of these Standard-channel ones (and blocks downgrading below
#   v1.5.0). Do not delete unless intentionally moving back to Experimental.
#
# Experimental-only CRDs kept alongside (not part of Standard channel, but
# not currently in use in this cluster — safe to keep or drop):
# - xbackends.yaml
# - xbackendtrafficpolicies.yaml
# - xmeshes.yaml
#
# NOTE: TLSRoute/TCPRoute/UDPRoute/BackendTLSPolicy graduated to Standard as
# `v1` in Gateway API 1.5+; the Standard channel bundle serves ONLY `v1` for
# these (no v1alpha2/v1alpha3). Any consumer (e.g. external-dns) must use a
# version that speaks the `v1` Gateway API types — see
# https://github.com/kubernetes-sigs/external-dns/issues/6247 for the
# external-dns-specific fallout of this exact migration.
#
# Source: https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.3
#
# To update these CRDs, download from:
# Standard: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
# Experimental (the x-*.yaml files only): .../download/v1.6.3/experimental-install.yaml
# Each file is one document of those bundles: the license header (except the
# x-*.yaml files), then the document, with
# `argocd.argoproj.io/sync-options: ServerSideApply=true` added to each CRD's
# annotations; safe-upgrades-vap.yaml is the policy and its binding.
#
# Two owners, keep them in step. Since k3s v1.37.0, k3s itself installs the
# Standard-channel CRDs as a bundled chart (HelmChart kube-system/gateway-api-crd,
# Helm release "gateway-api-crd"; it was not a manual install), and ArgoCD applies
# these files over them with server-side apply. Whichever wrote last wins the
# bundle-version annotation, so this bundle version must match what the
# cluster's k3s version ships: k3s v1.37.2+k3s1 ships v1.6.3 (chart 1.6.301),
# and the CRD specs here are identical to it. Check on every k3s bump.
#
# Cilium's own go.mod pins sigs.k8s.io/gateway-api (v1.6.3 as of Cilium v1.20.4):
# keep this bundle in step with that on every Cilium bump as well.

