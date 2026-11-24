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
CRD that `vertical-pod-autoscaler` only installed at wave 21. The fix was to move
`vertical-pod-autoscaler` to wave 15, ahead of all three consumers.

Note what the parent app does and doesn't catch: `bootstrap` gates a wave on each
child Application's *health*, not its sync success, and a child that has created no
resources at all still reports `Healthy`. So the parent finished all 22 waves while
those two apps were failing and retrying; only they showed the problem.

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

## Fixing "uses group 'X' at wave W, but ... installed at wave P"

Which fix depends on whether W is **less than** P or **equal** to P — the check treats
them differently because the annotation can only help with one of them.

### W < P: the CRD comes from a later Application

This is the real bug (the VPA one). A `SkipDryRunOnMissingResource` annotation on the
**resource** does not fix it: it only skips the pre-apply dry run (gitops-engine's
`sync_context.go` sets `task.skipDryRun`), so the failure moves from "the whole app
fails validation before anything applies" to "that one task fails at apply time". The
apply still has no REST mapping, so the app fails every attempt until the provider's
wave lands. The check does not accept a resource-level annotation here.

The **Application-level** form (`syncPolicy.syncOptions`) is still honoured, as a
deliberate escape hatch, because for some apps the alternative is worse: `cilium`,
`karpenter` and `policy-reporter` render `ServiceMonitor`s needing
`monitoring.coreos.com` (wave 16) while they run at waves 0 and 3, and without the
option their whole sync fails validation, so on a first-ever sync the CNI never
installs and nothing recovers. Their `ServiceMonitor`s still land only once wave 16 has
synced -- on devcloud the CRDs appeared at 18:44:28 and cilium's monitors at 18:46:07,
after a retry. The option keeps everything else in those apps applying; it does not fix
the ordering. Reach for it only when a hard failure of the whole app is worse than a
deferred one.

Pick one:
- **Move the consumer later.** Bump the whole Application's wave past P. Right when
  the dependency is incidental.
- **Move the provider earlier.** Usually better when several consumers depend on it —
  that's what `vertical-pod-autoscaler` did (21 → 15, ahead of `kube-prometheus-stack`
  at 16, `crossplane-providers-aws` at 18 and `cloudnative-pg-operator` at 21), and
  it's why it sits oddly early in the wave order. Record the new wave in
  `crd-providers.yaml` in the same commit.

### W == P: same wave, different Application

Ordering inside a wave isn't guaranteed, so this is a race. The check accepts the
annotation here and nothing else, but prefer restructuring: the one case that used to
rely on it — the root app's `crossplane-root-ca` / `letsencrypt-prod` /
`crossplane-selfsigned-issuer` against the `cert-manager` Application, all at wave 1 —
failed on the first genuinely fresh cluster (2026-11-24, 07:15:31):

```
resource mapping not found for name: "crossplane-root-ca" ... no matches for kind
"Certificate" in version "cert-manager.io/v1" ... Retrying attempt #1
```

Those three resources carry `SkipDryRunOnMissingResource=true`, and the **apply** still
failed. Fixed by moving `cert-manager` to wave 0 so the CRDs and webhook exist before
anything consumes them; the issuers and the PKI stayed at wave 1. That is the shape to
reach for: if a consumer and its provider share a wave, move the provider down, not the
consumer up.

The annotation can be either:
- on the resource itself, if you control its template, or
- in the owning Application's `spec.syncPolicy.syncOptions`, which applies to every
  resource in that app's sync — this is how `cilium`, `karpenter` and
  `policy-reporter`'s `ServiceMonitor`s are exempted (none of those three own their
  own `templates/` dir).

## W > P is necessary, not sufficient, on a cold cluster

Satisfying the wave gap does not guarantee the first pass applies cleanly. On the same
fresh cluster, wave 4's `ValidatingPolicy/unique-tlsroute-hostnames` failed with
`no matches for kind` at **07:20:24**, while `validatingpolicies.policies.kyverno.io`
had been created at **07:19:23** — a full minute earlier, in wave 3. `kyverno` is
recorded at wave 3 and the consumer is at 4, so the map was right and the apply still
failed. It healed on the next retry.

The mechanism is **not confirmed**. Candidates: kubectl's on-disk discovery cache
(`~/.kube/cache`, 10-minute refresh) in the kubectl invocations Argo CD shells out to,
and CRD `Established` lag. Don't state one as fact without measuring it.

What follows from it:
- Expect roughly one retry per CRD group on a cold cluster. That is normal, and
  `bootstrap`'s unlimited retry plus backoff is what absorbs it. A retry is not
  evidence that the wave map is wrong — check whether the CRD already existed.
- **`SkipDryRunOnMissingResource` is not the fix.** It defers validate-time to
  apply-time, and apply-time hits the same mapping lookup (see the cert-manager case
  above).
- If a consumer genuinely cannot tolerate the retry, give it more slack — a wave or two
  past the provider, not the same wave — or make the CRD pre-existing (installed by the
  master's kustomize bootstrap, like `argoproj.io` and `apiextensions.crossplane.io`).
- A retry restarts the whole sync from wave -10, including the `bootstrap-project-migration`
  hook. That churn is the real cost, and it is why the wave map is worth keeping right
  even though the retries self-heal.

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
| Using `SkipDryRunOnMissingResource` to silence a W < P violation | It only defers the failure to apply time; the app still fails every sync until the provider's wave lands. That's what `a1863c9` got wrong on devcloud |
| Assuming a chart shipping the annotation makes a new consumer safe | The annotation is about Argo's dry run, not about which wave installs the CRD. Check `crd-providers.yaml` for the wave |
| Pointing `pkg.crossplane.io`/`apiextensions.crossplane.io` at the `crossplane` Application's wave | Crossplane core is pre-existing from master boot; the `crossplane` app only re-manages it |
| Annotating a resource that lives in a vendored chart's `charts/*.tgz` | You can't edit vendored templates directly — use the owning Application's `syncOptions` instead |
| Forgetting a wildcard entry still needs the literal base group to match too | `"*aws.upbound.io"` matches `aws.upbound.io` itself as well as `iam.aws.upbound.io` — no separate exact entry needed |
