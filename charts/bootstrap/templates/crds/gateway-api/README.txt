# Gateway API CRDs v1.6.1 (Standard Channel Bundle)
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
# Source: https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.1
#
# To update these CRDs, download from:
# Standard: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
# (Cilium's own go.mod pins sigs.k8s.io/gateway-api to the same v1.6.1 as of
# Cilium v1.20.1 — keep this bundle version in step with Cilium's pinned
# gateway-api module version on every Cilium bump.)

