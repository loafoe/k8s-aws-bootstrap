# Argo CD RBAC Exemption — Risk Acceptance

`restrict-wildcard-rbac` and `restrict-escalation-verbs` (Zero Trust RBAC,
`Audit`-only) carve out Argo CD's own Role/ClusterRole objects. This is a
recorded risk acceptance, decided on CHAR-36: **Option 1 — a config-driven
exclusion list** in `charts/bootstrap/values.yaml`, not a time-bounded
`PolicyException`.

## What is exempted

`features.kyverno.rbacExemptions.argoCD` (`charts/bootstrap/values.yaml`):

```yaml
features:
  kyverno:
    rbacExemptions:
      argoCD:
        enabled: true
        namespaces: ["argocd"]
        clusterRolePrefixes: ["argocd-", "argocd:"]
```

Rendered into both policies as a `matchConditions` guard
(`charts/bootstrap/templates/_helpers.tpl`:
`bootstrap.argoCDRbacExemptionMatchCondition`):

- A cluster-scoped **ClusterRole** is exempt when its name starts with one
  of `clusterRolePrefixes` — it has no namespace, so the name prefix is its
  only gate.
- A namespaced **Role** is exempt only when **both** its namespace is in
  `namespaces` **and** its name starts with one of `clusterRolePrefixes`.
  Namespace membership alone is deliberately not enough: a Role placed in
  the `argocd` namespace that isn't actually one of Argo CD's own
  components (e.g. a tenant's or an attacker's) is still held to both
  policies. `tests/policies/rbac-argocd-exemption/` asserts this with a
  `rogue-tenant-role` fixture.

This currently exempts, by name: `argocd-application-controller` (`verbs:
["*"]`, `resources: ["*"]`), `argocd-server` (`resources: ["*"]`), and
`argocd:aggregate-to-crossplane` (`verbs: ["*"]` on `applications`), plus
the namespaced `argocd-repo-server` Role.

`crossplane-rbac-manager` and `k8s-monitoring-alloy-operator` are genuine
privileged RBAC managers, not Argo CD components, and do not match either
prefix — they keep reporting (asserted in the same test suite).

## Why Argo CD needs it

`argocd-application-controller` is a cluster-wide GitOps reconciler: by
design it creates and manages arbitrary resource kinds, in arbitrary
tenant namespaces, on behalf of every `Application` synced through it.
There is no fixed, enumerable verb/resource set that covers "whatever a
tenant's manifests declare" — narrowing it (Option 3, remediate instead of
exempt) would mean re-deriving Argo CD's own upstream RBAC design and
re-breaking it on every chart upgrade. See the CHAR-36 issue body for the
full three-option comparison; Option 1 was the recorded decision.

## Compensating controls

A tenant cannot reach this cluster-wide capability directly — it is Argo
CD's own identity, not something a tenant authenticates as. The actual
blast-radius control sits one layer up, in Argo CD's own authorization:

- **Argo CD RBAC** (`argocd-rbac-cm`) governs which human/SSO identities
  can create, modify, or sync `Application`/`AppProject` objects at all.
- **`AppProject` restrictions** (`sourceRepos`, `destinations`,
  `clusterResourceWhitelist`/`namespaceResourceBlacklist`) bound what any
  given `Application` — and therefore what the controller acting on its
  behalf — is allowed to sync, per tenant/project.
- **Who can edit `AppProject`s** is itself gated by Argo CD RBAC
  (`p, role:..., applications, update, ...` / `appprojects` policies) —
  review `argocd-rbac-cm` alongside this document; it is this exemption's
  actual least-privilege boundary, not the Kubernetes RBAC objects
  exempted here.

This exemption is a statement that **Kubernetes RBAC is the wrong
enforcement layer for Argo CD's own reconciler** — Argo CD's own RBAC and
`AppProject` model is — not a statement that nothing enforces it.

## Review cadence

Review this exemption whenever:

- Argo CD is upgraded and its bundled `ClusterRole`s change shape or
  naming (would require updating `clusterRolePrefixes`).
- A new component is added to the `argocd` namespace that is **not**
  Argo CD's own (would need to NOT match `argocd-`/`argocd:`, or it
  silently inherits the exemption for any ClusterRole it's granted).
- At minimum, once per quarter as part of the standing Zero Trust RBAC
  review — confirm `argocd-rbac-cm` and the `AppProject` set still bound
  what Argo CD can be asked to do, since that is what actually limits the
  risk accepted here.

**Owner:** the platform team (workspace owner) that holds
`cluster-admin`/`platform-admins` and governs `charts/bootstrap/values.yaml`
changes via normal PR review — not a separate role, since there is no
runtime object to delegate ownership of; the review surface is this file
and the two policy templates it documents.

## Residual risk

This is a permanent, code-review-protected blind spot, not a time-bounded
one (that trade-off against Option 2's TTL `PolicyException` governance was
accepted explicitly in CHAR-36). A `ClusterRole` named `argocd-anything` is
exempt from both policies regardless of who actually created it — nothing
in-cluster verifies the name prefix corresponds to the real Argo CD
installation. The compensating control against that specific risk is
`restrict-cluster-admin-binding` plus ordinary admission/RBAC on who may
create `ClusterRole` objects at all, not this exemption's own matching
logic.

## Related

- [`live-validation/README.md`](live-validation/README.md) — the
  `dip-ce-k3s-eu` runbook this exemption's live re-validation step uses.
- [`optional-policies.md`](optional-policies.md) — the pattern for
  per-cluster Helm parameter overrides via the Argo CD UI, applicable if a
  cluster ever needs `rbacExemptions.argoCD.enabled: false` (e.g. a
  cluster that doesn't run Argo CD in-tree at all).
