# Zero Trust RBAC Policy Exemptions

`restrict-wildcard-rbac` and `restrict-escalation-verbs` are audit-only
ValidatingPolicies. Both flag genuinely over-broad RBAC, but a small set of
platform-owned roles is broad by design. Those roles are excluded with
`matchConditions`, not time-bounded `PolicyException`s, because the need is
permanent and tied to how the upstream component works.

`tests/policies/rbac-exemptions/` asserts both the exclusions and the
non-exempt controls (for example, a Role in the `argocd` namespace that is
not an Argo CD component must still fail).

## Wildcard verbs count as escalation

`restrict-escalation-verbs` treats a wildcard (`*`) verb as escalation.
`*` necessarily includes `bind`, `escalate`, and `impersonate`; without this,
a rule listing only `verbs: ["*"]` bypassed the policy entirely. The
trade-off is that wildcard verbs on non-RBAC resources are also reported,
which is consistent with the Zero Trust intent of both policies.

## Exclusions

| Resource | Policies | Why |
|---|---|---|
| `argocd-server`, `argocd-application-controller` | both | Argo CD is a cluster-wide GitOps reconciler: it manages arbitrary kinds in arbitrary tenant namespaces on behalf of `Application`s. There is no fixed verb/resource list that covers what tenants may declare. |
| Names containing `crossplane` | both | Crossplane reconciles arbitrary CRDs and provider-declared RBAC that it does not know at install time. `crossplane-rbac-manager` additionally needs `bind`/`escalate` to grant providers the permissions they ship themselves. |
| `k8s-monitoring-alloy-operator` | escalation | Upstream grafana/k8s-monitoring RBAC (via our observability chart) needs `bind`/`escalate` to provision RBAC for the Alloy CRs it manages. |
| `k3s-cloud-controller-manager` | both | k3s's embedded Addon manifest, applied by the k3s server process at startup; it uses wildcard verbs on `nodes`/`daemonsets`. |
| Label `kubernetes.io/bootstrapping: rbac-defaults` | both | The kube-apiserver's own built-in ClusterRoles (`cluster-admin`, `admin`, `edit`, `system:*`). The API server reconciles these itself on every restart. |

The label check uses `'key' in labels` before indexing. `has(labels)` only
proves the labels map exists; indexing a missing key errors rather than
returning false, which would skip evaluation for every role without the
label.

## Compensating controls

For Argo CD, Kubernetes RBAC is not the least-privilege boundary for its own
reconciler. The effective controls are Argo CD RBAC (`argocd-rbac-cm`) and
the `AppProject` model (`sourceRepos`, `destinations`,
`clusterResourceWhitelist`/`namespaceResourceBlacklist`). Who may edit those
`AppProject`s is itself governed by Argo CD RBAC.

Crossplane's equivalent boundary is who may install/configure providers and
write the RBAC those providers declare. The k3s and API-server-owned roles
are not authored in this repository at all.

## Residual risk and review

These are permanent, code-review-protected carve-outs, not TTL waivers. A
`ClusterRole` that matches an excluded name (for example, anything containing
`crossplane`) is exempt regardless of who created it. Admission/RBAC on who
may create `ClusterRole` objects, plus `restrict-cluster-admin-binding`,
remain the controls against that specific risk.

Review this document and the two policies whenever:

- Argo CD, Crossplane, the k8s-monitoring chart, or k3s changes its bundled
  RBAC names or shape;
- a new component is added that would accidentally match an exclusion;
- at least once per quarter as part of the standing Zero Trust RBAC review.

The policy templates are the source of truth; keep this document and
`tests/policies/rbac-exemptions/` in sync with them.
