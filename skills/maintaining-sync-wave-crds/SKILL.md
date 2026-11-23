---
name: maintaining-sync-wave-crds
description: Use when scripts/check-sync-wave-crds.sh fails in k8s-aws-bootstrap (an "is not in scripts/crd-providers.yaml" or "but ... says it's installed at wave N" error), when adding a new chart or Application to charts/bootstrap, when a chart starts rendering a resource of a kind it didn't render before, or when deciding whether a resource needs a SkipDryRunOnMissingResource exemption.
---

# Maintaining the sync-wave/CRD map

## Overview

Argo CD syncs `charts/bootstrap`'s Applications in `sync-wave` order, waiting for
each wave to be healthy before starting the next. A resource whose API group's CRD
isn't installed yet fails Argo's validation for its *whole* Application atomically
(not just that one resource) — if that Application also prunes, the failure repeats
forever and blocks every later wave, including anything after it in the tree. That's
the crossplane-providers VPA incident: a `VerticalPodAutoscaler` at wave 18 needed a
CRD that `vertical-pod-autoscaler` only installs at wave 21.

`scripts/check-sync-wave-crds.sh` renders the whole app-of-apps tree (root chart +
every child Application's chart, OCI or in-repo) and catches this before it reaches a
cluster. `scripts/crd-providers.yaml` is the hand-maintained map it checks against:
API group → the wave that's guaranteed to have installed it.

## Running it

```bash
scripts/check-sync-wave-crds.sh        # full matrix: all tests/render/values fixtures
```

Takes about a minute (pulls the 3 OCI child charts fresh each run). Needs `helm`,
`yq` (mikefarah v4), `jq`.

## Fixing "group 'X' is not in scripts/crd-providers.yaml"

A resource is using an API group the map has never seen. Find what installs it:

1. Does any Application's rendered output contain a literal
   `CustomResourceDefinition` for that group? That Application's own `sync-wave`
   annotation is the wave to record.
2. If no literal CRD ever appears (Crossplane installs provider/function CRDs
   dynamically from a `Provider`/`Function` package, not a static manifest): record
   the wave of the Application that renders that package resource.
3. Add `{group: <group>, providedBy: <Application name>, wave: <N>}` to
   `scripts/crd-providers.yaml`. Use a `providedBy` value matching the owning
   Application's `metadata.name` *exactly* — see "self-reference" below for why.
4. A family of groups from one provider (Crossplane's upbound providers mint one
   group per AWS service: `s3.aws.upbound.io`, `kms.aws.upbound.io`, ...) can share
   one entry with a `*`-suffix pattern, e.g. `"*aws.upbound.io"`, instead of listing
   every service.

## Fixing "uses group 'X' at wave W, but ... installed at wave P" (W <= P)

Pick one:
- **Move the consumer later.** Bump the resource's own `sync-wave` annotation (if it
  carries one) or the whole Application's wave past P. Simplest when you control the
  template and the dependency is incidental.
- **Add the exemption.** `argocd.argoproj.io/sync-options:
  SkipDryRunOnMissingResource=true` — as an annotation on the resource if you can
  edit its template directly, or as an entry in the owning Application's
  `spec.syncPolicy.syncOptions` list if the resource comes from a vendored chart you
  can't annotate (this is how `cilium`, `karpenter` and `policy-reporter`'s
  `ServiceMonitor`s are exempted — none of those three own their own `templates/`
  dir). The Application-level option applies to every resource in that app's sync,
  so only reach for it when the resource itself can't be annotated.
- **Lower the provider's wave.** Rarely right — check nothing else depends on the
  provider being late.

## The self-reference rule

A resource is never flagged against a group whose `crd-providers.yaml` entry has
`providedBy` equal to the resource's *own* owning Application. This is not a bug to
work around — it's how every chart that ships its own CRDs alongside resources using
them (e.g. `kube-prometheus-stack`'s `Prometheus`/`Alertmanager` CRs and its own
`Prometheus` CRDs) is already safe: Argo applies both in one atomic sync. Don't add a
`SkipDryRunOnMissingResource` exemption for this case — fix the `providedBy` value
in the map instead if you see a false positive here.

## The "pre-existing" sentinel

Some CRDs (Argo CD's own `argoproj.io`, Crossplane core's `apiextensions.crossplane.io`
and `pkg.crossplane.io`) are installed once, outside Argo CD entirely, by the master
node's own bootstrap kustomization (k3s-on-ec2's `pkg/bootstrap`) before any sync-wave
ever runs. These use `providedBy: pre-existing, wave: -1`, even though a later
Application (`argocd` wave 10, `crossplane` wave 2) also manages that same install
going forward — that Application is reconciling an existing install, not creating it
for the first time. Don't "correct" these to point at that Application's wave.

## Related files

- `scripts/lib/render-tree.sh` — shared rendering helpers (`render_root`,
  `app_names`, `app_json`, `render_app`). `check-appproject.sh` uses the same
  functions; if you add a new Application source type (today: this repo's own path,
  or an OCI chart), extend `render_app` there once, not in both scripts.
- `.github/workflows/bootstrap-render.yaml` — runs this alongside
  `check-bootstrap-render.sh` and `check-appproject.sh` on any `charts/**`,
  `scripts/lib/**`, or `scripts/crd-providers.yaml` change.

## Common mistakes

| Mistake | Why it's wrong |
|---|---|
| Treating a same-wave, same-app CRD + CR pair as a violation | That's the normal, safe case every self-contained chart relies on — fix `providedBy`, don't add an exemption |
| Pointing `pkg.crossplane.io`/`apiextensions.crossplane.io` at the `crossplane` Application's wave | Crossplane core is pre-existing from master boot; the `crossplane` app only re-manages it |
| Annotating a resource that lives in a vendored chart's `charts/*.tgz` | You can't edit vendored templates directly — use the owning Application's `syncOptions` instead |
| Forgetting a wildcard entry still needs the literal base group to match too | `"*aws.upbound.io"` matches `aws.upbound.io` itself as well as `iam.aws.upbound.io` — no separate exact entry needed |
