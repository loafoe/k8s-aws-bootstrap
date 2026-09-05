# Node Readiness Gate for Karpenter Disruption

Make Karpenter's own node-replacement sequencing wait for real CSI/CNI readiness (not just kubelet Ready) before it drains the node being replaced, closing the gap that disrupted StatefulSets during the recent k3s upgrade.

## Problem

During the recent k3s version rollout, a few StatefulSets were disrupted and took longer than expected to recover. Root cause:

1. Karpenter launches a replacement node.
2. Pods get scheduled/rescheduled onto it.
3. The EBS CSI node plugin and SPIFFE CSI driver aren't fully registered yet (Cilium has its own readiness taint, but EBS/SPIFFE CSI have no equivalent).
4. PVC attach and pod sandbox creation fail, retrying with backoff.
5. The old node finishes draining while recovery on the new node is still incomplete.

Karpenter's NodeClaim `Initialized` condition (kubelet Ready + all `startupTaints` removed) already gates *when a replacement node is considered usable*, and Karpenter's disruption controller (drift/expiration/consolidation-replace) already launches replacements before draining the node being replaced, waiting for `Initialized` first. But today only `karpenter.sh/unregistered` is in `startupTaints` — Cilium's own `node.cilium.io/agent-not-ready` taint isn't part of that list, and there's no taint at all for EBS CSI / SPIFFE CSI readiness. So Karpenter proceeds as soon as kubelet is Ready, well before CSI/CNI are actually functional.

Separately: the EBS CSI node DaemonSet already tolerates all `NoSchedule` taints (`operator: Exists`), so it isn't gated by anything — it schedules immediately, but its node-driver-registrar sidecar still needs time to register `ebs.csi.aws.com` with kubelet. Nothing today prevents a PVC-backed pod landing on the node before that registration completes.

## Solution

Extend Karpenter's `startupTaints` with two more taints so `Initialized` means "ready for stateful workloads," not just "kubelet is up":

- **`node.cilium.io/agent-not-ready`** (`NoSchedule`) — Cilium already manages this taint's full lifecycle (`removeNodeTaints`/`setNodeTaints: true` are already the effective defaults in the vendored chart). We only need to (a) add it to `startupTaints` so Karpenter waits on it, and (b) also register it via kubelet `--register-with-taints` at boot, closing the small window between node-Ready and cilium-operator noticing the unmanaged node and applying the taint itself.
- **`k8s-aws-bootstrap.io/csi-not-ready`** (`NoSchedule`) — new taint, registered via kubelet `--register-with-taints` at boot (same mechanism already used for `karpenter.sh/unregistered`). Cleared by a new healer CronJob once both `ebs.csi.aws.com` and `csi.spiffe.io` are registered in the node's `CSINode` object and their respective DaemonSet pods on that node are Ready.

No new persistent controller. This reuses a mechanism Karpenter already ships (`startupTaints`) and a pattern this repo already has twice (`pod-identity-webhook-healer`, `cilium-operator-healer`): a small, stateless CronJob.

### Why this actually fixes the disruption sequencing

Karpenter's disruption controller, for Karpenter-driven replacement (drift, expiration, consolidation-with-replace), creates the replacement NodeClaim first and blocks on its `Initialized` condition before cordoning/draining/terminating the node it's replacing. Putting real CSI/CNI readiness into `startupTaints` makes that existing wait condition honest.

**Known limitation, intentionally out of scope for this iteration:** this only protects Karpenter-driven disruption. A manual `kubectl delete node` / cordon+drain (e.g. to force an immediate k3s version rollout, since the `k8s-aws-bootstrap.io/k3s-version` annotation on `EC2NodeClass` is informational only and isn't part of the spec Karpenter hashes for drift) does not go through Karpenter's create-before-delete sequencing at all — Karpenter reacts to the resulting capacity gap by launching a new node, but can't delay the manual eviction to wait for it. The readiness taint still improves that case (evicted pods sit safely `Pending` instead of landing on a broken node and hitting CSI attach failures), but doesn't eliminate the window. See **Future Improvements**.

## Components Changed

### 1. `charts/bootstrap/templates/karpenter/karpenter-ec2nodeclass.yaml`
Extend the kubelet `register-with-taints` argument:
```
--kubelet-arg="register-with-taints=karpenter.sh/unregistered=true:NoExecute,node.cilium.io/agent-not-ready=true:NoSchedule,k8s-aws-bootstrap.io/csi-not-ready=true:NoSchedule"
```

### 2. `charts/bootstrap/templates/karpenter/karpenter-nodepool.yaml` and `karpenter-nodepool-system.yaml`
Add both new taints to `startupTaints` (alongside the existing `karpenter.sh/unregistered`):
```yaml
startupTaints:
  - key: karpenter.sh/unregistered
    value: "true"
    effect: NoExecute
  - key: node.cilium.io/agent-not-ready
    value: "true"
    effect: NoSchedule
  - key: k8s-aws-bootstrap.io/csi-not-ready
    value: "true"
    effect: NoSchedule
```

### 3. `charts/spire/values.yaml`
Add tolerations for both new taints to `spire-agent` and `spiffe-csi-driver`. Without this, adding the taints deadlocks SPIFFE CSI: it can't schedule until the taint clears, and the taint can't clear until it registers. Neither component needs pod networking to function, so tolerating `node.cilium.io/agent-not-ready` is also safe/correct — they should start as early as possible.

EBS CSI node needs no change — it already tolerates all `NoSchedule` taints. Cilium agent needs no change — it already self-tolerates its own taint and has a catch-all `NoSchedule` toleration.

### 4. New: `charts/bootstrap/templates/aws/node-readiness-healer-cronjob.yaml` (or a new `node-readiness/` subdirectory)
Same pattern as `pod-identity-webhook-heal-cronjob.yaml` / `cilium-operator-healer-cronjob.yaml`: ServiceAccount + ClusterRole (list/patch nodes, get csinodes, list pods) + ClusterRoleBinding + CronJob, running in `kube-system`.

- **Schedule:** `* * * * *` (Kubernetes CronJob's minimum granularity), `concurrencyPolicy: Forbid`.
- **Body:** loop internally every ~10s for up to ~50s (bounded by `activeDeadlineSeconds`) rather than running once and exiting — gives near-real-time (~10s) reaction latency without a persistent controller.
- **Per iteration:** list nodes carrying the `k8s-aws-bootstrap.io/csi-not-ready` taint. For each: read `kubectl get csinode <node> -o jsonpath='{.spec.drivers[*].name}'` and confirm both `ebs.csi.aws.com` and `csi.spiffe.io` are present; confirm the `ebs-csi-node` and `spiffe-csi-driver` pods scheduled on that node are `Ready`. If satisfied, re-read the node's current `.spec.taints`, filter out only the `k8s-aws-bootstrap.io/csi-not-ready` entry, and `kubectl patch node <node> --type=merge -p="{\"spec\":{\"taints\":[...]}}"` with the filtered list — read-filter-patch, not a fixed-index JSON patch, so a concurrent removal of a different taint (e.g. Karpenter clearing `karpenter.sh/unregistered`) can't race into removing the wrong entry.
- Tolerates `CriticalAddonsOnly` and schedules on system/control-plane nodes, matching the existing healers.

### 5. Priority class
Verified against the vendored chart templates directly (not assumed):
- `ebs-csi-node` — **no change needed.** The upstream chart's node DaemonSet template already defaults `priorityClassName` to `system-node-critical` (`{{ .Values.node.priorityClassName | default "system-node-critical" }}` in `_node.tpl`) regardless of target namespace — confirming there's no namespace restriction on this built-in PriorityClass in this cluster's Kubernetes version.
- `cilium-agent` — the chart exposes a top-level `priorityClassName` field. Set it to `system-node-critical` in `charts/cilium/values.yaml`.
- `spire-agent` and `spiffe-csi-driver` — their DaemonSet templates **don't expose `priorityClassName` at all** (confirmed: no such field in either `spire/charts/spire-agent/templates/daemonset.yaml` or `spire/charts/spiffe-csi-driver/templates/daemonset.yaml`), so it can't be set via Helm values. Add a new Kyverno `ClusterPolicy` that mutates pods matching these two DaemonSets to inject `spec.priorityClassName: system-node-critical`, following the exact pattern already used in `kyverno-cnpg-on-demand-nodes-policy.yaml` (match-and-patchStrategicMerge).

### 6. `docs/node-scheduling-guide.md`
Document the new taints, what clears them, and add a **Future Improvements** note (see below) — no runbook implementation, just the note.

## Future Improvements (documented, not implemented now)

The taint/healer mechanism above only protects Karpenter-initiated disruption (drift, expiration, consolidation-replace). A manual node rotation (`kubectl delete node`, or cordon+drain to force an immediate k3s version rollout) bypasses Karpenter's create-before-delete sequencing entirely, since the termination isn't a Karpenter disruption decision. Closing that gap would require either:
- Triggering a real Karpenter *drift* event for version rollouts (e.g., a spec-level change Karpenter's AWS provider actually hashes) so its native sequencing applies, or
- A scripted rotation procedure that explicitly cordons the new node in, waits for it to clear all `startupTaints` (`Initialized=True` on its NodeClaim), and only then cordons+drains+deletes the old node.

Not designed further here; flagged for a future iteration if manual rotations remain a recurring need.

## Testing / Validation Plan

1. Render the modified charts (`helm template`) and confirm the taint/toleration/priorityClass changes produce valid manifests.
2. Deploy to a non-prod path or dry-run against the live cluster's ArgoCD diff.
3. Manually trigger a node replacement (cordon + delete one Karpenter-managed node) and observe:
   - `kubectl get nodeclaims` shows the replacement's `Initialized` condition `False` until the healer clears `k8s-aws-bootstrap.io/csi-not-ready`.
   - No application pods land on the new node until both taints clear.
   - `spiffe-csi-driver`/`spire-agent`/`ebs-csi-node` pods reach Ready on the new node without needing the taint removed first (confirms the toleration fix).
   - The healer CronJob's logs show it detecting readiness and clearing the taint within ~1 minute of actual readiness.
4. Confirm the old node is only drained after the above, for a Karpenter-driven disruption (e.g. trigger drift via an AMI change).

## Files to Create/Modify

1. `charts/bootstrap/templates/karpenter/karpenter-ec2nodeclass.yaml` — extend `register-with-taints`
2. `charts/bootstrap/templates/karpenter/karpenter-nodepool.yaml` — add `startupTaints` entries
3. `charts/bootstrap/templates/karpenter/karpenter-nodepool-system.yaml` — add `startupTaints` entries
4. `charts/spire/values.yaml` — add tolerations to `spire-agent`, `spiffe-csi-driver`
5. `charts/cilium/values.yaml` — add `priorityClassName: system-node-critical` (ebs-csi-node already defaults to it; spire-agent/spiffe-csi-driver handled by the Kyverno policy below since their charts don't expose the field)
6. New `charts/bootstrap/templates/kyverno/kyverno-spire-priority-class-policy.yaml` — Kyverno `ClusterPolicy` injecting `priorityClassName: system-node-critical` onto `spire-agent`/`spiffe-csi-driver` pods
7. New `charts/bootstrap/templates/aws/node-readiness-healer-cronjob.yaml` — ServiceAccount, ClusterRole, ClusterRoleBinding, CronJob
8. `docs/node-scheduling-guide.md` — document new taints/healer + Future Improvements note
