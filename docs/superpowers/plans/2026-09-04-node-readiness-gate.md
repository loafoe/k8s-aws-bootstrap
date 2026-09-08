# Node Readiness Gate for Karpenter Disruption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Karpenter's node-replacement sequencing wait for real CSI/CNI readiness (EBS CSI, SPIFFE CSI, Cilium) before it drains the node being replaced, so StatefulSets don't get disrupted by PVC-attach/sandbox failures on a not-yet-ready replacement node.

**Architecture:** Add `node.cilium.io/agent-not-ready` (already self-managed by Cilium) and a new `k8s-aws-bootstrap.io/csi-not-ready` taint to both Karpenter NodePools' `startupTaints`, so Karpenter's existing `Initialized` condition (which already gates its create-before-delete disruption sequencing) blocks on them. A new stateless healer CronJob clears the custom taint once `CSINode` shows both `ebs.csi.aws.com` and `csi.spiffe.io` registered and their DaemonSet pods are Ready on that node. Fix a toleration gap on `spire-agent`/`spiffe-csi-driver` that would otherwise deadlock against the new taints, and raise scheduling priority on the affected DaemonSets.

**Tech Stack:** Helm charts (this repo's "thin wrapper" chart pattern), ArgoCD (GitOps sync via `argocd.argoproj.io/sync-wave` annotations), Kyverno `ClusterPolicy` for mutation where a subchart doesn't expose a field, a `batch/v1` CronJob (alpine/k8s image, POSIX `sh`) matching the existing `pod-identity-webhook-healer`/`cilium-operator-healer` pattern.

**Spec:** `docs/superpowers/specs/2026-09-04-node-readiness-gate-design.md`

## Global Constraints

- New taint `k8s-aws-bootstrap.io/csi-not-ready`, value `"true"`, effect `NoSchedule` — registered via kubelet `--register-with-taints` at node boot, cleared only by the new healer CronJob.
- Existing taint `node.cilium.io/agent-not-ready`, value `"true"`, effect `NoSchedule` — already self-managed by Cilium (`removeNodeTaints`/`setNodeTaints: true` are the chart's effective defaults); we only add it to `startupTaints` and to kubelet's `register-with-taints` (belt-and-suspenders for the window before cilium-operator notices an unmanaged node).
- CSINode driver names to check: `ebs.csi.aws.com`, `csi.spiffe.io`.
- Verified pod labels/namespaces (confirmed via `helm template` against the vendored subchart tarballs, not assumed):
  - EBS CSI node: namespace `aws-ebs-csi-driver`, labels `app=ebs-csi-node`, container `ebs-plugin`. Already defaults `priorityClassName: system-node-critical` in the upstream chart — no change needed.
  - SPIFFE CSI driver: namespace `spire-system`, labels `app.kubernetes.io/name=spiffe-csi-driver`, container `spiffe-csi-driver`. Chart does **not** expose `priorityClassName`.
  - spire-agent: namespace `spire-system`, labels `app.kubernetes.io/name=agent`, `app.kubernetes.io/component=default`. Chart does **not** expose `priorityClassName`.
  - cilium-agent: namespace `kube-system`. Chart **does** expose a top-level `priorityClassName` field.
- Local render verification: use the scratch values file below (not committed) with `helm template`/`helm lint` against `charts/bootstrap` for anything under `charts/bootstrap/templates/`; charts under `charts/cilium`, `charts/spire`, `charts/aws-ebs-csi-driver` render standalone with no extra values needed.

Create this scratch file once, before Task 1 — every later task's render-verification step assumes it exists at this path:

**File:** `/tmp/bootstrap-test-values.yaml` (not committed — local verification only)
```yaml
features:
  hspAwsPlatform:
    enabled: false
environmentConfig:
  bootstrap:
    resourcePrefix: test
    awsAccountId: "123456789012"
    awsPartition: aws
    awsRegion: us-east-1
    clusterName: test
    clusterFqdn: test.example.com
    clusterHost: test.example.com
    clusterEndpoint: https://test.example.com
    oidcProvider: oidc.eks.us-east-1.amazonaws.com/id/TEST
    oidcProviderArn: arn:aws:iam::123456789012:oidc-provider/test
    awsVpcId: vpc-test
    awsLbcRoleArn: arn:aws:iam::123456789012:role/test
    awsEbsCsiDriverRoleArn: arn:aws:iam::123456789012:role/test
    awsExternalDnsRoleArn: arn:aws:iam::123456789012:role/test
    certManagerRoleArn: arn:aws:iam::123456789012:role/test
    karpenterRoleArn: arn:aws:iam::123456789012:role/test
    crossplaneProviderAwsIamRoleArn: arn:aws:iam::123456789012:role/test
    karpenterInstanceProfile: test-profile
    k3sTokenParameterName: /test/k3s-token
    k3sVersionParameterName: /test/k3s-version
```

Verify it works before starting Task 1:
```bash
helm lint charts/bootstrap -f /tmp/bootstrap-test-values.yaml
```
Expected: `1 chart(s) linted, 0 chart(s) failed`.

## File Structure

```
charts/bootstrap/templates/karpenter/
├── karpenter-nodepool.yaml          # MODIFY: add startupTaints (Task 1)
├── karpenter-nodepool-system.yaml   # MODIFY: add startupTaints (Task 1)
└── karpenter-ec2nodeclass.yaml      # MODIFY: extend register-with-taints (Task 2)

charts/spire/values.yaml              # MODIFY: tolerations on spire-agent + spiffe-csi-driver (Task 3)
charts/cilium/values.yaml             # MODIFY: priorityClassName on agent (Task 4)

charts/bootstrap/templates/kyverno/
└── kyverno-spire-priority-class-policy.yaml   # CREATE: inject priorityClassName (Task 5)

charts/bootstrap/templates/aws/
└── node-readiness-healer-cronjob.yaml         # CREATE: healer CronJob + RBAC (Task 6)

docs/node-scheduling-guide.md         # MODIFY: document taints/healer + future-improvement note (Task 7)
```

---

### Task 1: Add readiness startupTaints to both Karpenter NodePools

**Files:**
- Modify: `charts/bootstrap/templates/karpenter/karpenter-nodepool.yaml:61-65`
- Modify: `charts/bootstrap/templates/karpenter/karpenter-nodepool-system.yaml:67-71`

**Interfaces:**
- Produces: the two taint definitions (`node.cilium.io/agent-not-ready` and `k8s-aws-bootstrap.io/csi-not-ready`, both `value: "true"`, `effect: NoSchedule`) that Task 2 must register identically via kubelet, and that Task 6's healer must clear using the identical key/value for `k8s-aws-bootstrap.io/csi-not-ready`.

- [ ] **Step 1: Verify Cilium's actual applied taint value on a live node (correctness-critical)**

Karpenter's `Initialized` condition only treats a `startupTaints` entry as "removed" when it finds an *exact* key+value+effect match currently absent from `node.spec.taints`. If Cilium applies its taint with a different value than we declare, Karpenter will never gate on it. Confirm before writing the taint into the NodePool spec:

```bash
kubectl describe node <any-existing-karpenter-node> | grep -A2 "Taints:"
```

Expected: if the node currently has no `node.cilium.io/agent-not-ready` taint (already cleared, since it's already healthy), instead check a freshly-launched node right after it registers (e.g. during a scale-up event), or check Cilium's own logs/events for the literal taint string it applies. Confirm it reads `node.cilium.io/agent-not-ready=true:NoSchedule` (value `true`, not empty). If the value differs, use that exact value in Step 2 instead of `"true"`.

- [ ] **Step 2: Edit `karpenter-nodepool.yaml`**

Current (lines 61-65):
```yaml
      # Startup taints for K3s initialization
      startupTaints:
        - key: karpenter.sh/unregistered
          value: "true"
          effect: NoExecute
```

Replace with:
```yaml
      # Startup taints for K3s initialization
      startupTaints:
        - key: karpenter.sh/unregistered
          value: "true"
          effect: NoExecute
        # Cilium already manages this taint's full lifecycle (applies at boot,
        # removes once cilium-agent is healthy). Declaring it here makes
        # Karpenter's own Initialized/disruption-sequencing wait for real CNI
        # readiness, not just kubelet Ready.
        - key: node.cilium.io/agent-not-ready
          value: "true"
          effect: NoSchedule
        # Cleared by the node-readiness-healer CronJob once ebs.csi.aws.com
        # and csi.spiffe.io are registered in CSINode and their DaemonSet
        # pods are Ready on this node. See node-readiness-healer-cronjob.yaml.
        - key: k8s-aws-bootstrap.io/csi-not-ready
          value: "true"
          effect: NoSchedule
```

- [ ] **Step 3: Edit `karpenter-nodepool-system.yaml`** identically

Current (lines 67-71):
```yaml
      # Startup taints for K3s initialization
      startupTaints:
        - key: karpenter.sh/unregistered
          value: "true"
          effect: NoExecute
```

Replace with the same three-entry list as Step 2 (identical taint keys/values/effects — both NodePools share the same EC2NodeClass/userData, so they must declare the same startup taints).

- [ ] **Step 4: Render and verify**

```bash
helm template test charts/bootstrap -f /tmp/bootstrap-test-values.yaml --show-only templates/karpenter/karpenter-nodepool.yaml | grep -A9 "startupTaints:"
helm template test charts/bootstrap -f /tmp/bootstrap-test-values.yaml --show-only templates/karpenter/karpenter-nodepool-system.yaml | grep -A9 "startupTaints:"
```

Expected: both show all three taints (`karpenter.sh/unregistered`, `node.cilium.io/agent-not-ready`, `k8s-aws-bootstrap.io/csi-not-ready`) with matching values/effects.

- [ ] **Step 5: Commit**

```bash
git add charts/bootstrap/templates/karpenter/karpenter-nodepool.yaml charts/bootstrap/templates/karpenter/karpenter-nodepool-system.yaml
git commit -m "feat(karpenter): gate node Initialized on CNI/CSI readiness taints"
```

---

### Task 2: Register the new taints via kubelet at node boot

**Files:**
- Modify: `charts/bootstrap/templates/karpenter/karpenter-ec2nodeclass.yaml:184-197`

**Interfaces:**
- Consumes: the exact taint key/value/effect strings from Task 1 (`node.cilium.io/agent-not-ready=true:NoSchedule`, `k8s-aws-bootstrap.io/csi-not-ready=true:NoSchedule`) — must match character-for-character or Karpenter's `Initialized` check (Task 1) and the healer's removal target (Task 6) won't line up with what's actually on the node.

- [ ] **Step 1: Edit the `register-with-taints` kubelet arg**

Current (line 189, inside the `curl -sfL https://get.k3s.io | sh -s -` block):
```bash
      --kubelet-arg="register-with-taints=karpenter.sh/unregistered=true:NoExecute" \
```

Replace with:
```bash
      --kubelet-arg="register-with-taints=karpenter.sh/unregistered=true:NoExecute,node.cilium.io/agent-not-ready=true:NoSchedule,k8s-aws-bootstrap.io/csi-not-ready=true:NoSchedule" \
```

- [ ] **Step 2: Render and verify**

```bash
helm template test charts/bootstrap -f /tmp/bootstrap-test-values.yaml --show-only templates/karpenter/karpenter-ec2nodeclass.yaml | grep "register-with-taints"
```

Expected: one line containing all three taints comma-separated, in the order above.

- [ ] **Step 3: Commit**

```bash
git add charts/bootstrap/templates/karpenter/karpenter-ec2nodeclass.yaml
git commit -m "feat(karpenter): register CNI/CSI readiness taints at kubelet boot"
```

---

### Task 3: Fix the SPIFFE CSI toleration deadlock

**Files:**
- Modify: `charts/spire/values.yaml:60-64` (`spire-agent.tolerations`)
- Modify: `charts/spire/values.yaml:74-78` (`spiffe-csi-driver.tolerations`)

**Why this task exists:** Tasks 1-2 add `node.cilium.io/agent-not-ready` and `k8s-aws-bootstrap.io/csi-not-ready` as `NoSchedule` taints on every new node. `spire-agent` and `spiffe-csi-driver` currently only tolerate `CriticalAddonsOnly` and `node-role.kubernetes.io/control-plane` — neither taint. Without this fix, `spiffe-csi-driver` could never schedule to register `csi.spiffe.io`, so `k8s-aws-bootstrap.io/csi-not-ready` would never clear — a permanent deadlock. Neither component needs pod networking, so tolerating `node.cilium.io/agent-not-ready` is also correct on its own merits (they should start as early as possible). `ebs-csi-node` needs no equivalent fix — it already tolerates all `NoSchedule` taints (`operator: Exists`).

**Interfaces:**
- Consumes: the exact taint keys from Task 1/2.

- [ ] **Step 1: Edit `spire-agent` tolerations**

Current (lines 60-64):
```yaml
    socketPath: /run/spire/agent-sockets/spire-agent.sock
    tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
```

Replace with:
```yaml
    socketPath: /run/spire/agent-sockets/spire-agent.sock
    tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
    # spire-agent needs no pod networking and must register csi.spiffe.io
    # (via spiffe-csi-driver) before these taints will ever clear - tolerate
    # both so it isn't blocked on itself.
    - key: node.cilium.io/agent-not-ready
      operator: Exists
    - key: k8s-aws-bootstrap.io/csi-not-ready
      operator: Exists
```

- [ ] **Step 2: Edit `spiffe-csi-driver` tolerations**

Current (lines 74-78):
```yaml
      limits:
        memory: 24Mi
    tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
```

Replace with:
```yaml
      limits:
        memory: 24Mi
    tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
    # Must be able to schedule and register csi.spiffe.io before
    # k8s-aws-bootstrap.io/csi-not-ready can ever clear - tolerate both new
    # readiness taints so it isn't blocked on itself.
    - key: node.cilium.io/agent-not-ready
      operator: Exists
    - key: k8s-aws-bootstrap.io/csi-not-ready
      operator: Exists
```

- [ ] **Step 3: Render and verify**

```bash
helm dependency build charts/spire
helm template test charts/spire | grep -B2 -A2 "csi-not-ready"
```

Expected: two matches, one under the `spire-agent` DaemonSet's tolerations and one under `spiffe-csi-driver`'s.

- [ ] **Step 4: Commit**

```bash
git add charts/spire/values.yaml
git commit -m "fix(spire): tolerate CNI/CSI readiness taints to avoid scheduling deadlock"
```

---

### Task 4: Raise cilium-agent scheduling priority

**Files:**
- Modify: `charts/cilium/values.yaml:255-256`

**Why:** cilium-agent currently sets no `priorityClassName`, so on a busy new node (competing for CPU/memory with everything else trying to start at once) it's preemptable like any ordinary pod — exactly the window this whole plan is trying to make safe. The vendored chart exposes a top-level `priorityClassName` field (confirmed via `grep -n priorityClassName` in `charts/cilium/charts/cilium-1.20.1.tgz:cilium/values.yaml`).

- [ ] **Step 1: Edit `charts/cilium/values.yaml`**

Current (lines 255-256):
```yaml
  # Agent (DaemonSet) Configuration
  tolerations:
```

Replace with:
```yaml
  # Agent (DaemonSet) Configuration
  # Never preempted by other pods competing for resources on a busy new node
  priorityClassName: system-node-critical
  tolerations:
```

- [ ] **Step 2: Render and verify**

```bash
helm dependency build charts/cilium
helm template test charts/cilium | grep -B5 "priorityClassName: system-node-critical" | grep -A2 "^kind: DaemonSet\|name: cilium$"
```

Expected: `priorityClassName: system-node-critical` appears in the `cilium` agent DaemonSet's pod spec (not the operator Deployment, which is a separate `priorityClassName` field this task doesn't touch).

- [ ] **Step 3: Commit**

```bash
git add charts/cilium/values.yaml
git commit -m "feat(cilium): set system-node-critical priority on cilium-agent"
```

---

### Task 5: Inject priorityClassName onto spire-agent/spiffe-csi-driver via Kyverno

**Files:**
- Create: `charts/bootstrap/templates/kyverno/kyverno-spire-priority-class-policy.yaml`

**Why a Kyverno policy instead of a values change:** confirmed by inspecting the vendored subchart templates directly — neither `spire/charts/spire-agent/templates/daemonset.yaml` nor `spire/charts/spiffe-csi-driver/templates/daemonset.yaml` has a `priorityClassName` field at all, so there's no values key to set. This repo already has a precedent for exactly this situation: `charts/bootstrap/templates/kyverno/kyverno-cnpg-on-demand-nodes-policy.yaml` mutates pods a chart doesn't let you configure directly. This task follows that same pattern.

**Interfaces:**
- Consumes: verified pod labels from Global Constraints (`spire-system` namespace; `app.kubernetes.io/name=spiffe-csi-driver`; `app.kubernetes.io/name=agent` + `app.kubernetes.io/component=default`).

- [ ] **Step 1: Create the ClusterPolicy**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: spire-priority-class
  annotations:
    policies.kyverno.io/title: SPIRE Node-Local Priority Class
    policies.kyverno.io/category: Best Practices, Reliability
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/minversion: 1.6.0
    policies.kyverno.io/description: >-
      spire-agent and spiffe-csi-driver are node-local daemons that gate
      k8s-aws-bootstrap.io/csi-not-ready (see node-readiness-healer-cronjob.yaml).
      Their upstream Helm charts don't expose priorityClassName, so this policy
      injects system-node-critical to prevent them being preempted on a busy
      new node during exactly the startup window the readiness gate protects.
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    argocd.argoproj.io/sync-wave: "4"
spec:
  rules:
  - name: add-priority-class-spiffe-csi-driver
    match:
      any:
      - resources:
          kinds:
          - Pod
          namespaces:
          - spire-system
          selector:
            matchLabels:
              app.kubernetes.io/name: spiffe-csi-driver
    mutate:
      patchStrategicMerge:
        spec:
          priorityClassName: system-node-critical
  - name: add-priority-class-spire-agent
    match:
      any:
      - resources:
          kinds:
          - Pod
          namespaces:
          - spire-system
          selector:
            matchLabels:
              app.kubernetes.io/name: agent
              app.kubernetes.io/component: default
    mutate:
      patchStrategicMerge:
        spec:
          priorityClassName: system-node-critical
```

- [ ] **Step 2: Render and verify**

```bash
helm template test charts/bootstrap -f /tmp/bootstrap-test-values.yaml --show-only templates/kyverno/kyverno-spire-priority-class-policy.yaml
```

Expected: valid YAML, one `ClusterPolicy` with the two rules above rendered verbatim (no templating errors).

```bash
helm lint charts/bootstrap -f /tmp/bootstrap-test-values.yaml
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 3: Commit**

```bash
git add charts/bootstrap/templates/kyverno/kyverno-spire-priority-class-policy.yaml
git commit -m "feat(kyverno): inject system-node-critical priority on SPIRE node daemons"
```

---

### Task 6: Create the node-readiness-healer CronJob

**Files:**
- Create: `charts/bootstrap/templates/aws/node-readiness-healer-cronjob.yaml`

**Why here:** matches where the two existing healers of this exact shape live conceptually (`pod-identity-webhook-heal-cronjob.yaml` is in `templates/aws/`); this one also depends on AWS-managed CSI state (`ebs.csi.aws.com`).

**Interfaces:**
- Consumes: taint key `k8s-aws-bootstrap.io/csi-not-ready` (Tasks 1-2); CSINode driver names `ebs.csi.aws.com`/`csi.spiffe.io`; pod labels/namespaces from Global Constraints (`aws-ebs-csi-driver` ns + `app=ebs-csi-node` + container `ebs-plugin`; `spire-system` ns + `app.kubernetes.io/name=spiffe-csi-driver` + container `spiffe-csi-driver`).
- Produces: nothing consumed by later tasks — this is the last functional piece. Task 7 (docs) describes it by name (`node-readiness-healer`) and behavior.

This task is split into three steps because the file is long: RBAC, then the CronJob/script, then verification.

- [ ] **Step 1: Write the ServiceAccount + RBAC**

Create `charts/bootstrap/templates/aws/node-readiness-healer-cronjob.yaml` starting with:

```yaml
# ---------------------------------------------------------------------------
# Self-healing CronJob: clears the k8s-aws-bootstrap.io/csi-not-ready taint
# once a new node's EBS CSI and SPIFFE CSI node plugins are actually
# registered and Ready - not just once kubelet is Ready.
# ---------------------------------------------------------------------------
# Karpenter's NodeClaim Initialized condition (see karpenter-nodepool.yaml)
# requires all startupTaints to be removed before Karpenter will consider a
# replacement node usable, which is also what gates when Karpenter is willing
# to drain the node it's replacing. This taint is registered via kubelet
# --register-with-taints at boot (karpenter-ec2nodeclass.yaml) and only
# removed here, once real readiness is confirmed:
#   - CSINode lists both ebs.csi.aws.com and csi.spiffe.io
#   - the ebs-csi-node and spiffe-csi-driver pods on that node are Ready
#
# Runs every minute (CronJob's minimum granularity) but loops internally for
# up to ~50s polling every ~10s, so reaction latency is ~10s, not 60s.
# ---------------------------------------------------------------------------
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-readiness-healer
  namespace: kube-system
  annotations:
    argocd.argoproj.io/sync-wave: "3"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-readiness-healer
  annotations:
    argocd.argoproj.io/sync-wave: "3"
rules:
# List nodes to find ones still carrying the readiness taint; patch to clear it
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch"]
# Read CSINode to check which CSI drivers are registered on each node
- apiGroups: ["storage.k8s.io"]
  resources: ["csinodes"]
  verbs: ["get"]
# Read pods to confirm ebs-csi-node/spiffe-csi-driver are Ready on each node
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-readiness-healer
  annotations:
    argocd.argoproj.io/sync-wave: "3"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-readiness-healer
subjects:
- kind: ServiceAccount
  name: node-readiness-healer
  namespace: kube-system
```

- [ ] **Step 2: Verify the RBAC block renders**

```bash
helm template test charts/bootstrap -f /tmp/bootstrap-test-values.yaml --show-only templates/aws/node-readiness-healer-cronjob.yaml
```

Expected: at this point the file only has the four RBAC resources above (no CronJob yet) — should render as valid YAML with no errors. This intermediate check exists so a syntax mistake in the RBAC block is caught before adding ~100 more lines of CronJob/script.

- [ ] **Step 3: Append the CronJob**

Append to the same file, after the `ClusterRoleBinding`:

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: node-readiness-healer
  namespace: kube-system
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  # CronJob's minimum granularity is 1 minute; the script itself loops
  # internally every ~10s so real reaction latency is ~10s, not 60s.
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 90
      ttlSecondsAfterFinished: 120
      template:
        metadata:
          labels:
            app.kubernetes.io/name: node-readiness-healer
        spec:
          serviceAccountName: node-readiness-healer
          restartPolicy: Never
          containers:
          - name: healer
            # renovate: datasource=docker depName=alpine/k8s
            image: alpine/k8s:1.36.0
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                memory: 64Mi
            command:
            - sh
            - -c
            - |
              set -e

              END=$(( $(date +%s) + 45 ))

              while [ "$(date +%s)" -lt "$END" ]; do
                NODES=$(kubectl get nodes -o json | \
                  jq -r '.items[] | select((.spec.taints // []) | any(.key == "k8s-aws-bootstrap.io/csi-not-ready")) | .metadata.name')

                if [ -n "$NODES" ]; then
                  echo "$NODES" | while read -r node; do
                    [ -z "$node" ] && continue

                    echo "Checking readiness for node $node..."

                    DRIVERS=$(kubectl get csinode "$node" -o jsonpath='{.spec.drivers[*].name}' 2>/dev/null || true)

                    HAS_EBS=false
                    HAS_SPIFFE=false
                    case " $DRIVERS " in *" ebs.csi.aws.com "*) HAS_EBS=true ;; esac
                    case " $DRIVERS " in *" csi.spiffe.io "*) HAS_SPIFFE=true ;; esac

                    if [ "$HAS_EBS" != "true" ] || [ "$HAS_SPIFFE" != "true" ]; then
                      echo "  -> CSINode drivers not fully registered yet (drivers: ${DRIVERS:-none}). Skipping."
                      continue
                    fi

                    EBS_READY=$(kubectl get pods -n aws-ebs-csi-driver -l app=ebs-csi-node \
                      --field-selector spec.nodeName="$node" \
                      -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="ebs-plugin")].ready}' 2>/dev/null || true)
                    SPIFFE_READY=$(kubectl get pods -n spire-system -l app.kubernetes.io/name=spiffe-csi-driver \
                      --field-selector spec.nodeName="$node" \
                      -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="spiffe-csi-driver")].ready}' 2>/dev/null || true)

                    if [ "$EBS_READY" != "true" ] || [ "$SPIFFE_READY" != "true" ]; then
                      echo "  -> Driver pods not Ready yet (ebs=$EBS_READY, spiffe=$SPIFFE_READY). Skipping."
                      continue
                    fi

                    echo "  -> Node $node is ready. Clearing k8s-aws-bootstrap.io/csi-not-ready taint."

                    REMAINING_TAINTS=$(kubectl get node "$node" -o json | \
                      jq -c '[.spec.taints[]? | select(.key != "k8s-aws-bootstrap.io/csi-not-ready")]')
                    kubectl patch node "$node" --type=merge -p "{\"spec\":{\"taints\":${REMAINING_TAINTS}}}"

                    echo "  -> Taint cleared on $node."
                  done
                fi

                sleep 10
              done

              echo "node-readiness-healer: loop window elapsed, exiting."
          # Schedule on control-plane / system nodes (always available)
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                - matchExpressions:
                  - key: node-type
                    operator: In
                    values:
                    - system
                    - control-plane
          tolerations:
          - key: CriticalAddonsOnly
            operator: Exists
          - key: node.cilium.io/agent-not-ready
            operator: Exists
          # System-pool nodes get this taint at boot too (shared
          # EC2NodeClass/userData) - the healer must tolerate the very
          # taint it's responsible for clearing on other nodes.
          - key: k8s-aws-bootstrap.io/csi-not-ready
            operator: Exists
```

- [ ] **Step 4: Render, then syntax-check the extracted shell script**

```bash
helm template test charts/bootstrap -f /tmp/bootstrap-test-values.yaml --show-only templates/aws/node-readiness-healer-cronjob.yaml > /tmp/healer-rendered.yaml
```

Expected: renders with no errors — one ServiceAccount, one ClusterRole, one ClusterRoleBinding, one CronJob.

Extract just the script body and run it through `sh -n` (POSIX syntax-check only, doesn't execute):

```bash
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/healer-rendered.yaml')))
cronjob = [d for d in docs if d and d.get('kind') == 'CronJob'][0]
script = cronjob['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['command'][2]
open('/tmp/healer-script.sh', 'w').write(script)
"
sh -n /tmp/healer-script.sh
echo "exit code: $?"
```

Expected: `exit code: 0` — no syntax errors. (If `pyyaml` isn't available, `pip install pyyaml` first, or eyeball the extracted block with `sed -n '/command:/,/affinity:/p' /tmp/healer-rendered.yaml`.)

- [ ] **Step 5: Commit**

```bash
git add charts/bootstrap/templates/aws/node-readiness-healer-cronjob.yaml
git commit -m "feat(node-readiness-healer): clear csi-not-ready taint once EBS/SPIFFE CSI are ready"
```

---

### Task 7: Document the readiness gate and the future-improvement note

**Files:**
- Modify: `docs/node-scheduling-guide.md`

**Interfaces:**
- Consumes: taint names and healer name from Tasks 1-6 (documented, not re-derived).

- [ ] **Step 1: Add a new section after "## DaemonSet Workloads" (currently ends at line 74)**

Insert:
```markdown
## Node Readiness Gate

New Karpenter nodes carry two `NoSchedule` startup taints until real CSI/CNI readiness is confirmed, not just kubelet Ready:

- `node.cilium.io/agent-not-ready` — cleared by Cilium itself once cilium-agent is healthy on the node.
- `k8s-aws-bootstrap.io/csi-not-ready` — cleared by the `node-readiness-healer` CronJob (`kube-system`) once the node's `CSINode` object lists both `ebs.csi.aws.com` and `csi.spiffe.io`, and the `ebs-csi-node`/`spiffe-csi-driver` pods on that node are Ready.

Both taints are listed in each Karpenter NodePool's `startupTaints`
(`karpenter-nodepool.yaml`, `karpenter-nodepool-system.yaml`), so Karpenter's
own `NodeClaim` `Initialized` condition — and therefore its create-before-delete
disruption sequencing for drift/expiration/consolidation-replace — now waits
for them, not just for kubelet.

Check taint state on a node:
```bash
kubectl describe node <node> | grep -A5 "Taints:"
```

Check the healer's recent activity:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=node-readiness-healer --tail=50
```

### Future Improvement (not implemented)

This mechanism only protects **Karpenter-initiated** disruption (drift,
expiration, consolidation-replace) — Karpenter launches the replacement node
and waits for it to reach `Initialized` before draining the node it's
replacing. A **manual** `kubectl delete node` / cordon+drain (e.g. to force an
immediate k3s version rollout) bypasses that sequencing entirely, since the
termination isn't a Karpenter disruption decision — Karpenter can't delay a
manual eviction to wait for a replacement it didn't initiate. The readiness
taints still help in that case (evicted pods sit safely `Pending` instead of
landing on a broken node and hitting CSI attach failures), but the outage
window isn't fully eliminated. Closing it fully would need either a real
Karpenter *drift* trigger for version rollouts, or a scripted rotation
procedure that waits for the new node's `Initialized` condition before
draining the old one. Not designed further here.
```

- [ ] **Step 2: Commit**

```bash
git add docs/node-scheduling-guide.md
git commit -m "docs: document the node readiness gate and manual-rotation limitation"
```

---

### Task 8: Live-cluster validation

Not a code change — a verification checklist to run after the above is deployed via ArgoCD (this is a GitOps repo; there's no CI test suite, so this is the actual test plan per `docs/superpowers/specs/2026-09-04-node-readiness-gate-design.md`).

- [ ] **Step 1: Confirm ArgoCD synced cleanly**

```bash
kubectl get application -n argocd | grep -E "bootstrap|cilium|aws-ebs-csi-driver|spire"
```

Expected: all `Synced`/`Healthy`.

- [ ] **Step 2: Trigger a Karpenter-driven node replacement**

```bash
kubectl get nodes -l node-type=karpenter-managed
kubectl delete node <one-karpenter-managed-node>
```

- [ ] **Step 3: Watch the replacement node's taints and NodeClaim status**

```bash
watch kubectl get nodeclaims -o wide
```

Expected: the new `NodeClaim`'s `Initialized` condition (`kubectl get nodeclaim <name> -o jsonpath='{.status.conditions}'`) stays `False` until both taints clear — check with:

```bash
kubectl describe node <new-node> | grep -A5 "Taints:"
```

- [ ] **Step 4: Confirm no application pods land on the node while tainted**

```bash
kubectl get pods -A --field-selector spec.nodeName=<new-node> -o wide
```

Expected: only pods tolerating the readiness taints are present (spire-agent, spiffe-csi-driver, ebs-csi-node, cilium-agent, kube-proxy-equivalent, node-readiness-healer if it landed there) — no StatefulSet/Deployment application pods until the taints clear.

- [ ] **Step 5: Confirm the healer clears the taint promptly once ready**

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=node-readiness-healer --tail=50 -f
```

Expected: within roughly a minute of the `ebs-csi-node`/`spiffe-csi-driver` pods on the new node reaching Ready, a log line `Node <new-node> is ready. Clearing k8s-aws-bootstrap.io/csi-not-ready taint.` followed by `Taint cleared`.

- [ ] **Step 6: Confirm spire-agent/spiffe-csi-driver aren't stuck (Task 3 fix)**

```bash
kubectl get pods -n spire-system -o wide --field-selector spec.nodeName=<new-node>
```

Expected: both `Running`/`Ready` well before `k8s-aws-bootstrap.io/csi-not-ready` clears (they shouldn't be blocked by the taint they're gating).
