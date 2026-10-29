## Post-fix snapshot — 2026-10-29 (Phase 2.4 / CHAR-37)

Captured against `dip-ce-k3s-eu` after pruning the 37 stale `PolicyReport`s
left behind by CHAR-35's autogen fix. Raw, machine-readable data is in this
directory; this file is the human-readable summary.

## Cluster

| | |
| :--- | :--- |
| Kubernetes | `v1.37.1+k3s1`, 1 control-plane + 6 workers |
| Kyverno | `v1.19.2` |
| Argo CD `kyverno` app | `Synced` / `Healthy` at `105fc0ef0cb7701a37366b79f61d6ec28f0a1782` |
| Argo CD `policy-reporter` app | `Synced` / `Healthy` at `105fc0ef0cb7701a37366b79f61d6ec28f0a1782` |

**This is not the same revision as the baseline.** Between the
[`baseline-2026-10-29/`](../baseline-2026-10-29/) capture (`566335cc02ba`)
and this one, five more PRs merged and synced: CHAR-35 (#307, the
autogen/null-rules fix this issue follows up on), plus #308–#311
(exempting known-legit system workloads from four audit policies, fixing a
CEL map-index error, disabling autogen on two name-exclusion policies, and
closing the wildcard-verb escalation blind spot). **The fail/error counts
below are not comparable 1:1 to the baseline** — most of the drop is from
those legitimate exemption fixes, not from anything in this issue.

## Policies deployed

[`validating-policies.json`](validating-policies.json): **20**
`ValidatingPolicy` objects — **8** `Audit`, **12** `Deny`.
[`mutating-policies.json`](mutating-policies.json): same **2**
`MutatingPolicy` objects as baseline.

Note the **Audit/Deny split flipped from baseline's 12/8 to 8/12** — four
more policies are now `Deny` than at baseline time, including several of
the `validate-*-pod-identity` policies this issue's pruning touched. Argo CD
reports `Synced`, i.e. this matches the currently merged manifests exactly;
it is not drift. It is called out here only because the runbook's own
guardrail ("no `Deny` rollout without an `Audit` soak first") makes this
worth a maintainer's eyes — CHAR-37 made no policy or chart changes and did
not cause this.

## PolicyReport / ClusterPolicyReport results

[`policy-report-summary.json`](policy-report-summary.json) — same shape as
the baseline file.

- **708** report objects (down from baseline's 764: the 28 deleted stale
  reports, plus natural `ReplicaSet`-history garbage collection on this live
  cluster during the session — see [the runbook](../README.md#phase-22-stale-policyreport-pruning))
- **1942** individual rule results: **1609** pass, **138** fail, **195**
  skip, **0** error

### Error count: 0, and it is clean

Before pruning, this cluster still carried the 55 stale `error` results
(across 32 `PolicyReport`s) described in this issue: `failed to load
context: no such key: name` from the `validate-*-pod-identity` /
`validate-*-serviceaccount-pod-identity` policies, attached to `ReplicaSet`s
that CHAR-35's autogen scope change made permanently unreachable by those
rules. Of the 32:

- **28** were deleted outright — every result on the report was `error`,
  dated 2026-10-29T12:11–12:12Z (before the CHAR-35 merge sync at 12:46Z),
  and owned by a `ReplicaSet` scaled to 0 that will never run again.
  (1 of the originally-enumerated 29 such reports had already been garbage
  collected by Kubernetes between enumeration and deletion — expected
  behaviour on this live cluster, not an error.)
- **3** were *not* deleted — they belong to the live `Deployment` objects
  (`karpenter`, `external-dns`, `aws-load-balancer-controller`), which are
  actively rescanned by every other policy and carried current `pass`/`skip`
  results alongside the two stale `error` entries. Deleting the whole report
  would have thrown away that live data. Instead, only the stale `error`
  result entries were removed from each report's `.results` array (5 entries
  across the 3 reports), leaving every other result and the report's
  identity untouched.

```bash
kubectl get policyreports,clusterpolicyreports -A -o json \
  | jq '[.items[].results[]? | select(.result=="error")] | length'
# 0
```

### Fail counts by policy

| Policy | Fails | Baseline (12:00Z) |
| :--- | ---: | ---: |
| `require-owner-label` | 61 | 133 |
| `restrict-wildcard-rbac` | 50 | 61 |
| `disallow-default-serviceaccount` | 22 | 24 |
| `restrict-escalation-verbs` | 4 | 6 |
| `restrict-cluster-admin-binding` | 1 | 1 |
| `require-restricted-pod-security` | 0 | 51 |

`require-restricted-pod-security` going to 0 is PR #309's `kube-system`/
`cilium*` exemption, not this issue. No fail count here changed as a side
effect of the pruning this issue did — pruning only ever touched `error`
results.
