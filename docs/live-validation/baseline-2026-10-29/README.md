# Baseline snapshot — 2026-10-29

Captured against `dip-ce-k3s-eu` before any Phase 2 policy change. Raw,
machine-readable data is in this directory; this file is the human-readable
summary. Reproduce it with the commands in
[`../README.md`](../README.md#reproducing-this-snapshot).

## Cluster

| | |
| :--- | :--- |
| Kubernetes | `v1.37.1+k3s1`, 1 control-plane + 6 workers |
| Kyverno | `v1.19.2` |
| `kyverno-exceptions` namespace age | since 2026-10-27T10:14:29Z |
| Argo CD `kyverno` app | `Synced` / `Healthy` at `566335cc02ba` |
| Argo CD `policy-reporter` app | `Synced` / `Healthy` at `566335cc02ba` |

`566335cc02ba` is this repository's `HEAD` at capture time — see
[CI↔cluster parity](../README.md#ci-cluster-parity) in the runbook.

## Policies deployed

[`validating-policies.json`](validating-policies.json): **20** `ValidatingPolicy`
objects — 12 `Audit`, 8 `Deny`.
[`mutating-policies.json`](mutating-policies.json): **2** `MutatingPolicy`
objects (`cnpg-on-demand-nodes`, `default-revision-history-limit`).

**Drift from the pre-flight count of 21 `ValidatingPolicy`:** the pre-flight
note was taken the same day this issue was filed; `require-image-digest`
(CHAR-28, merged as the same-day commit `1d7b9ed`) made that policy opt-in
and disabled by default (`features.kyverno.requireImageDigest.enabled:
false` in `charts/bootstrap/values.yaml`, see
[`../../optional-policies.md`](../../optional-policies.md)). It is not
rendered on this cluster, which accounts for 21 → 20. No other policy is
missing or unexpectedly present.

## PolicyReport / ClusterPolicyReport results

[`policy-report-summary.json`](policy-report-summary.json) — generated from
a full `clusterpolicyreports`/`policyreports -A` pull (results summarized;
raw per-object dumps were not committed, per the issue's "results summary,
not full dumps" instruction).

- **764** report objects (`ClusterPolicyReport` + `PolicyReport`)
- **2160** individual rule results: **1608** pass, **276** fail, **207** skip, **69** error

### Error inventory — reproduces the cited `69` exactly

| Result | Policy | Message | Count |
| :--- | :--- | :--- | ---: |
| error | `validate-karpenter-pod-identity` | `failed to load context: no such key: name` | 12 |
| error | `validate-karpenter-serviceaccount-pod-identity` | `failed to load context: no such key: name` | 12 |
| error | `validate-ebs-csi-controller-pod-identity` | `failed to load context: no such key: name` | 11 |
| error | `validate-ebs-csi-controller-serviceaccount-pod-identity` | `failed to load context: no such key: name` | 11 |
| error | `validate-aws-lbc-pod-identity` | `failed to load context: no such key: name` | 9 |
| error | `validate-external-dns-pod-identity` | `failed to load context: no such key: name` | 5 |
| error | `validate-external-dns-serviceaccount-pod-identity` | `failed to load context: no such key: name` | 5 |
| error | `restrict-escalation-verbs` | `got 'types.Null', expected iterable type` | 2 |
| error | `restrict-wildcard-rbac` | `got 'types.Null', expected iterable type` | 2 |

Subtotals: **65** from the 7 pod-identity policies' `no such key: name`
context-loading bug, **4** from the two RBAC policies' `types.Null` CEL
error — matching the issue's cited `65` and `4` exactly. These are owned by
the follow-on evaluation-error issue; this snapshot only captures them.

### Fail counts by policy (top offenders)

| Policy | Fails |
| :--- | ---: |
| `require-owner-label` | 133 |
| `restrict-wildcard-rbac` | 61 |
| `require-restricted-pod-security` | 51 |
| `disallow-default-serviceaccount` | 24 |
| `restrict-escalation-verbs` | 6 |
| `restrict-cluster-admin-binding` | 1 |

All six are `Audit`-mode policies (see `validating-policies.json`) —
observed, not blocked. Full breakdown by namespace is in
`policy-report-summary.json`'s `fail_and_error_by_namespace`.
