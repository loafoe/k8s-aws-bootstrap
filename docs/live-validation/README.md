# Live Validation on `dip-ce-k3s-eu`

`dip-ce-k3s-eu` is the standing live testbed for the Kyverno Zero Trust
rollout (CHAR-15 ff.). Phase 1's acceptance criteria (CHAR-16 … CHAR-22) were
all cluster-side observations — "zero admission rejections", "PolicyReports
generated", "expired exceptions pruned" — that CI cannot check. This runbook
turns each of those into a copy-pasteable command against a real cluster, so
the next review states a verified fact instead of "unverified in theory".

Read [`credentials.md`](credentials.md) first if you don't already have a
kubeconfig for this cluster — **never** use a kubeconfig that embeds a
client certificate/key from someone else's machine, and never let one land
in this repo.

## Guardrails

This is a real, shared cluster running real tenant workloads, not a scratch
sandbox.

- **No `Deny`-mode policy rollout here without an `Audit` soak first**, and a
  recorded rollback path before the sync that flips it.
- **Never delete or mutate workload namespaces** (or any resource in one) to
  make a policy pass. If something here is genuinely non-compliant, that is
  a finding to report, not a thing to fix by hand on this cluster.
- **All policy changes land through Argo CD from a merged commit.**
  `kubectl apply`/`patch`/`delete` on a `ValidatingPolicy`, `MutatingPolicy`,
  or `PolicyException` in `kyverno-exceptions` is never a fix — it is drift
  that the next sync (or `argocd app diff`) will flag and that a maintainer
  must reconcile by reverting it in-cluster or fast-following in Git.
- **Rollback = revert the Argo CD `kyverno` (or `policy-reporter`)
  `Application` to its previous Git revision**, then let it sync — not a
  manual `kubectl` edit.
- **Test resources go in a dedicated throwaway namespace** (e.g.
  `char34-live-validation`), labelled so they're identifiable, and are
  deleted at the end of the same session. Never reuse a tenant namespace for
  a probe.

## Phase 1 acceptance criteria — verification status

Evidence captured 2026-10-29 against commit `566335cc02ba` (this repo's
`HEAD` at the time, and the revision Argo CD had synced — see
[CI↔cluster parity](#ci-cluster-parity)). Full data:
[`baseline-2026-10-29/`](baseline-2026-10-29/).

| # | Criterion | Check | Status | Evidence |
| :-- | :--- | :--- | :--- | :--- |
| 1 | Exceptions confined to `kyverno-exceptions` | Create a well-formed `PolicyException` in a tenant namespace, targeting a resource that violates an `Audit` policy | **verified** | Admission *admitted* the exception (with a `must match the defined namespace` warning) but it was **not honoured**: the targeted resource kept failing `require-owner-label` (`result: fail`) exactly as without it. The same exception, same resource, recreated in `kyverno-exceptions`, flipped the result to `skip` on the next background scan. See [§Exceptions](#1-exceptions-confined-to-kyverno-exceptions). |
| 2 | Exceptions are TTL-governed | Apply a compliant exception with a short TTL; confirm cleanup-controller recognizes it | **partially verified** | `cleanup.kyverno.io/ttl: "1d"` label applied and recognized (no admission error, no immediate `deletionTimestamp`). `kyverno-cleanup-controller` runs `--ttlReconciliationInterval=5m` and watches TTL-labelled resources. **Actual deletion was not observed**: `govern-policy-exceptions` only allows `1d`/`3d`/`7d`/`14d`, all too long to wait out in one session. See [§TTL](#2-exceptions-are-ttl-governed). |
| 3 | Unannotated exceptions rejected | Apply an exception missing `cleanup.kyverno.io/ttl` | **verified** | Rejected: `admission webhook "vpol.validate.kyverno.svc-ignore" denied the request: Policy govern-policy-exceptions failed: PolicyExceptions must carry a 'cleanup.kyverno.io/ttl' label...`. See [§Unannotated](#3-unannotated-exceptions-rejected). |
| 4 | Audit policies do not block | Create a deliberately non-compliant pod; confirm it's created and reported | **verified** | `probe-pod` (default `ServiceAccount`, no owner label) reached `Running` immediately. The same pod shows `disallow-default-serviceaccount: fail` and `require-owner-label: fail` in its `PolicyReport`. See [§Audit](#4-audit-policies-do-not-block). |
| 5 | Reporting pipeline live | Confirm results reach Policy Reporter UI and are scraped by `kube-prometheus-stack` | **verified** | `policy-reporter-ui` returns `HTTP 200`. Prometheus (`prometheus/kps-prometheus`) query `up{job=~".*policy-reporter.*"}` returns `1`. See [§Reporting](#5-reporting-pipeline-live). |
| 6 | CI↔cluster parity | For each `tests/policies/*` suite, confirm the in-cluster spec matches the tested spec | **verified** | Argo CD `Application/kyverno` and `Application/policy-reporter`: both `Synced`/`Healthy` at revision `566335cc02ba`, equal to this repo's checked-out `HEAD`. `Synced` means Argo CD's own live-vs-desired diff is empty at that revision — the same templates `tests/policies/*` exercises. See [§Parity](#6-ci-cluster-parity). |

### 1. Exceptions confined to `kyverno-exceptions`

Confinement is enforced two ways: `exceptions-rbac.yaml` only grants the
`platform-admins` group write access to `policyexceptions` *in the
`kyverno-exceptions` namespace*, and the admission controller itself runs
with `--exceptionNamespace=kyverno-exceptions`, so an exception object
living anywhere else is simply never loaded into the exception cache used
during evaluation — regardless of who created it or how well-formed it is.

```bash
NS=char34-live-validation
kubectl create namespace $NS
kubectl run probe-pod -n $NS --image=registry.k8s.io/pause:3.9 --restart=Never

cat <<'EOF' | kubectl apply -f -
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: probe-wrong-ns
  namespace: char34-live-validation   # tenant namespace, not kyverno-exceptions
  labels:
    cleanup.kyverno.io/ttl: "1d"
  annotations:
    exceptions.kyverno.io/ticket: "..."
    exceptions.kyverno.io/owner: "..."
    exceptions.kyverno.io/compensating-controls: "..."
spec:
  policyRefs:
  - {name: require-owner-label, kind: ValidatingPolicy}
  matchConditions:
  - name: match-probe-pod
    expression: "object.metadata.name == 'probe-pod'"
EOF
# admitted, with: Warning: PolicyException resource namespace must match the defined namespace.

kubectl delete pod probe-pod -n $NS && kubectl run probe-pod -n $NS --image=registry.k8s.io/pause:3.9 --restart=Never
# wait ~30-60s for the background scan, then:
kubectl get polr -n $NS -o json | jq -r '.items[].results[] | select(.policy=="require-owner-label") | .result'
# still "fail" — the exception had no effect
```

Recreating the *same* exception object in `kyverno-exceptions` (correct
namespace) and re-running the last two commands flips the result to `skip`.

### 2. Exceptions are TTL-governed

```bash
kubectl get policyexception.policies.kyverno.io <name> -n kyverno-exceptions \
  -o jsonpath='{.metadata.labels}{"\n"}{.metadata.deletionTimestamp}{"\n"}'
# labels include cleanup.kyverno.io/ttl: "1d"; deletionTimestamp empty immediately after creation
kubectl -n kyverno get deploy kyverno-cleanup-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o 'ttlReconciliationInterval=[^"]*'
```

Deletion itself was not observed in this session — the shortest TTL
`govern-policy-exceptions` allows is `1d`. A follow-up check (e.g. a
`multica issue wakeup` after 25h, or a maintainer revisiting) should confirm
a `1d`-labelled exception is actually gone on schedule.

### 3. Unannotated exceptions rejected

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: probe-no-ttl
  namespace: kyverno-exceptions
  annotations:
    exceptions.kyverno.io/ticket: "..."
    exceptions.kyverno.io/owner: "..."
    exceptions.kyverno.io/compensating-controls: "..."
spec:
  policyRefs:
  - {name: require-owner-label, kind: ValidatingPolicy}
  matchConditions:
  - {name: m, expression: "object.metadata.name == 'probe-pod'"}
EOF
# Error from server: ... admission webhook "vpol.validate.kyverno.svc-ignore" denied the request:
# Policy govern-policy-exceptions failed: PolicyExceptions must carry a
# 'cleanup.kyverno.io/ttl' label set to one of '1d', '3d', '7d', or '14d' ...
```

### 4. Audit policies do not block

```bash
kubectl run probe-pod -n char34-live-validation --image=registry.k8s.io/pause:3.9 --restart=Never
kubectl get pod probe-pod -n char34-live-validation   # Running
# after the background scan:
kubectl get polr -n char34-live-validation -o json \
  | jq -r '.items[].results[] | "\(.policy) -> \(.result)"'
# disallow-default-serviceaccount -> fail
# require-owner-label             -> fail
# (pod stays Running throughout — these are Audit, not Deny)
```

### 5. Reporting pipeline live

```bash
kubectl -n kyverno port-forward svc/policy-reporter-ui 18080:8080 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/   # 200

kubectl -n prometheus port-forward svc/kps-prometheus 19090:9090 &
curl -s 'http://127.0.0.1:19090/api/v1/query?query=up%7Bjob%3D~%22.*policy-reporter.*%22%7D' \
  | jq '.data.result[0].value[1]'   # "1"
```

### 6. CI↔cluster parity

```bash
kubectl -n argocd get applications.argoproj.io kyverno policy-reporter \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{" "}{.status.sync.revision}{"\n"}{end}'
# kyverno          Synced Healthy 566335cc02ba...
# policy-reporter  Synced Healthy 566335cc02ba...
git -C . rev-parse HEAD   # matches, when checked out at the same point
```

`Synced` is Argo CD's own continuous diff between the live cluster state and
the manifests rendered from that Git revision — the same templates
`tests/policies/*` tests. A `Synced`/`Healthy` app at a revision equal to
your checkout's `HEAD` is parity; `OutOfSync` would mean the cluster no
longer reflects what CI tested.

## Reproducing this snapshot

```bash
export KUBECONFIG=<your own kubeconfig — see credentials.md>

kubectl get validatingpolicies.policies.kyverno.io -o json \
  | jq '[.items[] | {name: .metadata.name, validationActions: .spec.validationActions}] | sort_by(.name)'
kubectl get mutatingpolicies.policies.kyverno.io -o json \
  | jq '[.items[].metadata.name] | sort'

kubectl get clusterpolicyreports -o json > /tmp/cpr.json
kubectl get policyreports -A -o json > /tmp/pr.json
# then aggregate results by .result/.policy/.metadata.namespace — see
# baseline-2026-10-29/policy-report-summary.json for the exact shape produced
```

## Known baseline (owned by the follow-on evaluation-error issue)

`69` `error` results existed at baseline capture time: `65` from `failed to
load context: no such key: name` across the 7 pod-identity policies, `4`
from `got 'types.Null', expected iterable type` on
`restrict-escalation-verbs` and `restrict-wildcard-rbac`. This runbook and
[`baseline-2026-10-29/`](baseline-2026-10-29/) capture them as the
reference point. Both root causes are fixed as of CHAR-35 (PR #307,
`f41b84a`) and CHAR-37 below; **the cluster carries 0 `error` results as of
the [post-fix-2026-10-29](post-fix-2026-10-29/) snapshot.**

## Phase 2.2: stale PolicyReport pruning (CHAR-37)

CHAR-35's fix stopped new `error` results from being produced, but 37
`PolicyReport` objects created *before* the fix kept their stale `error`
entries forever: the fix narrowed the `validate-*-pod-identity` policies'
autogen scope to `v1/pods` only, so the `ReplicaSet`/`Deployment`-level rule
that used to produce (buggy) results for controller objects stopped firing
on them entirely — nothing ever overwrites the old `error` entry on an
object that no longer gets evaluated.

**Enumeration (32 reports carrying 55 stale `error` results at the time of
pruning — down from the issue's originally-cited 37/65 due to ordinary
`ReplicaSet`-history garbage collection in the hours between filing and
pruning):**

| Namespace | Stale reports | Owner kind |
| :--- | ---: | :--- |
| `aws-ebs-csi-driver` | 8 | `ReplicaSet` (scaled to 0) |
| `aws-load-balancer-controller` | 8 `ReplicaSet` + 1 `Deployment` | mixed |
| `external-dns` | 4 `ReplicaSet` + 1 `Deployment` | mixed |
| `karpenter` | 9 `ReplicaSet` + 1 `Deployment` | mixed |

- **29 `ReplicaSet`-owned reports** (28 still present at delete time; 1 had
  already been garbage-collected when its owning `ReplicaSet` was reaped)
  had **only** stale `error` results — every result on the object predated
  the 12:46Z CHAR-35 sync. These were deleted outright:
  `kubectl delete policyreport -n <ns> <name>`.
- **3 `Deployment`-owned reports** (`karpenter`, `external-dns`,
  `aws-load-balancer-controller`) are live — actively rescanned by every
  other policy, carrying current `pass`/`skip` results alongside the stale
  `error` entries. Deleting them would have discarded that live data, so
  only the stale `error` entries were removed from each report's
  `.results` array (and `.summary.error` zeroed), via `kubectl get -o json
  | jq '...' | kubectl replace -f -`. Everything else on those 3 reports is
  untouched.

No workload, policy, RBAC object, or chart value was touched — only
`wgpolicyk8s.io/v1alpha2` `PolicyReport` objects, scoped to the enumerated
names above. See [`post-fix-2026-10-29/`](post-fix-2026-10-29/) for the
full before/after data and the resulting `error: 0`,
`fail: 138` (vs. baseline's `276` — see that directory's README for why
the two aren't 1:1 comparable; five more fix PRs synced in between).

### Recurrence-prevention decision

This bug class — a policy's autogen/match scope narrowing so that
previously-evaluated controller objects stop being evaluated, stranding
their last (possibly `error`) result forever — will recur on any future
autogen or `matchConstraints` change. Evaluated options:

- **Kyverno `CleanupPolicy`** (`cleanup.kyverno.io`) garbage-collecting
  `PolicyReport`s with no recent result: possible, but it is a new
  cluster-scoped object and a chart/manifest addition, which this issue's
  guardrails explicitly put out of scope (no policy manifest or chart value
  changes here). Left for a maintainer to pick up as a follow-on if wanted.
- **Manual runbook step (chosen):** documented below. It needs no new
  in-cluster object and is immediately actionable by whoever makes the next
  autogen/scope change.

**Added to the re-validation runbook:** after any change that narrows a
policy's `autogen.podControllers` or `matchConstraints` scope, re-run the
[error inventory check](#reproducing-this-snapshot)
(`kubectl get policyreports,clusterpolicyreports -A -o json | jq '[.items[].results[]? | select(.result=="error")]'`)
once the sync has gone out. Any `error` result whose timestamp predates the
sync is a stranded result from the narrowed scope, not a new regression —
cross-check its owner still exists and hasn't produced a fresh result
since. Prune per the pattern above: delete the whole `PolicyReport` only if
*every* result on it is stale; otherwise patch out just the stale `error`
entries and leave the rest of the report alone.
