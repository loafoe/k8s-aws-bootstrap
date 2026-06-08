# Hubble L7 Flow Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Cilium export Gateway API / Envoy L7 (HTTP) access logs to a rotated host file on each node, via the Hubble static flow exporter, configured through GitOps.

**Architecture:** Add a `hubble.export.static` block to `charts/cilium/values.yaml` filtered to L7 AccessLog events, writing to the chart-default tmpfs path with native lumberjack rotation. ArgoCD syncs the cilium app; the agent DaemonSet rolls to pick up the exporter. Verification is empirical against the live `dip-ce-k3s-eu` cluster — there is no unit-test framework; the "test" is observing real exported records.

**Tech Stack:** Cilium 1.19.4 Helm chart, ArgoCD (app-of-apps), kubectl context `dip-ce-k3s-eu` (kubeconfig `/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml`).

**Repo:** `/Users/andy/DEV/Personal/k8s-aws-bootstrap`

---

## CRITICAL: filter value must be verified, not assumed

The spec uses `event_type` `129` for L7/AccessLog. This value is **not yet
confirmed against the Cilium 1.19.4 flow proto**. A wrong value produces a
**silently empty file** — the worst failure mode (looks configured, captures
nothing). Task 1 verifies the correct value empirically BEFORE we commit the
filter. Do not skip it.

---

### Task 1: Verify the correct L7 filter value empirically

**Files:** none (investigation only)

- [ ] **Step 1: Confirm the kubectl context works**

Run:
```bash
export KUBECONFIG=/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml
kubectl get nodes
```
Expected: 5 nodes listed (1 master, 4 workers), all `Ready`.

- [ ] **Step 2: Determine the AccessLog event_type number from the running agent**

Hubble flow `event_type.type` is the monitor API message type. Confirm the
AccessLog value the running Cilium build uses:
```bash
export KUBECONFIG=/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml
AGENT=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
# Drive an L7 request through the gateway first so a record exists:
curl -sk https://argocd.dip-ce-k3s-eu.hsp.philips.com/ -o /dev/null
# Observe an L7 flow as JSON and read its event_type:
kubectl exec -n kube-system $AGENT -c cilium-agent -- \
  hubble observe --type l7 --last 1 -o json 2>/dev/null | python3 -m json.tool | grep -A3 event_type
```
Expected: a JSON object containing `"event_type": {"type": <N>}`. Record `<N>`.
The Cilium constant for L7/AccessLog is conventionally `129`; **use whatever
`<N>` this command actually reports.** If `hubble observe --type l7` returns
nothing (export not on yet, and live L7 capture may be empty), fall back to the
documented monitor API value `129` but flag it for re-verification in Task 4.

- [ ] **Step 3: Record the verified value**

Note the confirmed `event_type.type` for L7 to use in Task 2's allowList.
Default to `129` only if Step 2 could not produce a live record.

---

### Task 2: Add the static exporter to the Cilium values

**Files:**
- Modify: `charts/cilium/values.yaml` (inside the existing `hubble:` block, sibling to `metrics:`)

- [ ] **Step 1: Add the export block**

In `charts/cilium/values.yaml`, add the following as a child of `hubble:`
(place it after the `metrics:` block, matching surrounding indentation — `hubble:`
is nested under the top-level `cilium:` key, so `export:` sits at the same
indent level as `metrics:`):

```yaml
    # Hubble Flow Export — Gateway API / Envoy L7 (HTTP) access logs.
    # Static exporter is bound to the agent lifecycle and rotates natively.
    # The file is tailed off-node by a logs collector (configured separately).
    export:
      static:
        enabled: true
        filePath: /var/run/cilium/hubble/events.log
        # <N> = the AccessLog (L7/HTTP) event_type verified in Task 1 (default 129).
        # Excludes L3/L4 flow noise so the file holds only access logs.
        allowList:
          - '{"event_type":[{"type":<N>}]}'
        fileMaxSizeMb: 50
        fileMaxBackups: 5
        fileCompress: true
```
Replace `<N>` with the value confirmed in Task 1.

- [ ] **Step 2: Validate YAML + Helm templating locally**

Run:
```bash
cd /Users/andy/DEV/Personal/k8s-aws-bootstrap
helm template charts/cilium 2>&1 | grep -A6 "hubble-export\|export-file-path\|events.log" | head -30
```
Expected: the rendered cilium-config ConfigMap shows the export keys
(`hubble-export-file-path: /var/run/cilium/hubble/events.log`,
`hubble-export-file-max-size-mb: "50"`, `hubble-export-file-max-backups: "5"`,
`hubble-export-allowlist` containing the event_type filter). If `helm template`
errors on missing required values, render with the same release values ArgoCD
uses (check `charts/bootstrap/templates/cilium/cilium-app.yaml` for the values
path) instead of the bare chart.

- [ ] **Step 3: Commit**

```bash
cd /Users/andy/DEV/Personal/k8s-aws-bootstrap
git add charts/cilium/values.yaml docs/superpowers/specs/2026-06-08-hubble-l7-flow-export-design.md docs/superpowers/plans/2026-06-08-hubble-l7-flow-export.md
git commit -m "feat(cilium): export L7 Gateway API access logs via Hubble static exporter

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Sync via ArgoCD and roll the agent

**Files:** none (deploy)

- [ ] **Step 1: Push and let ArgoCD sync (or sync manually)**

If ArgoCD auto-syncs the cilium app on git push, push the branch/commit per the
repo's normal flow. Otherwise trigger a sync:
```bash
export KUBECONFIG=/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml
kubectl -n argocd get application | grep -i cilium
# If using argocd CLI / manual sync, sync the cilium application here.
```
Expected: cilium Application reaches `Synced` / `Healthy`.

- [ ] **Step 2: Confirm the cilium-config ConfigMap has the export keys live**

Run:
```bash
export KUBECONFIG=/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml
kubectl get configmap cilium-config -n kube-system -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print('\n'.join(f'{k}={v}' for k,v in d.items() if 'export' in k.lower()))"
```
Expected: `hubble-export-file-path`, `hubble-export-file-max-size-mb=50`,
`hubble-export-file-max-backups=5`, and the allowlist key are present.

- [ ] **Step 3: Roll the agent if it did not restart automatically**

The agent must restart to start the static exporter. Confirm pod age dropped;
if not:
```bash
export KUBECONFIG=/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml
kubectl rollout restart daemonset cilium -n kube-system
kubectl rollout status daemonset cilium -n kube-system --timeout=300s
```
Expected: DaemonSet rolls out, all 5 pods Ready.

---

### Task 4: Verify access logs are captured (the real test)

**Files:** none (verification)

- [ ] **Step 1: Generate Gateway API traffic**

Run:
```bash
curl -sk https://argocd.dip-ce-k3s-eu.hsp.philips.com/ -o /dev/null -w "%{http_code}\n"
curl -sk https://argocd.dip-ce-k3s-eu.hsp.philips.com/api/version -o /dev/null -w "%{http_code}\n"
```
Expected: HTTP status codes returned (e.g. 200/307/404 — any response proves the
request traversed the Cilium Envoy gateway).

- [ ] **Step 2: Confirm the export file exists and contains L7 records**

Run (the export file is written on the node that handled the request; check a
few agent pods):
```bash
export KUBECONFIG=/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml
for p in $(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $p ==="
  kubectl exec -n kube-system $p -c cilium-agent -- sh -c 'ls -la /var/run/cilium/hubble/ 2>/dev/null; tail -n 2 /var/run/cilium/hubble/events.log 2>/dev/null'
done
```
Expected: `events.log` exists on at least one node and the tailed lines are JSON
flow records with `"Type":"L7"` and an `"http"` object (method, url, code,
headers). **If the file exists but is empty or contains only non-L7 records, the
`event_type` filter value from Task 1 is wrong** — return to Task 1 Step 2, find
the correct value from a live `-o json` record, and update the allowList in
Task 2.

- [ ] **Step 3: Confirm rotation settings are in effect**

Run:
```bash
export KUBECONFIG=/Users/andy/DEV/Personal/pulumi/k3s-on-ec2/dip-ce-k3s-eu.yaml
AGENT=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system $AGENT -c cilium-agent -- ls -la /var/run/cilium/hubble/
```
Expected: `events.log` present (rotated `events-*.log.gz` siblings will appear
only after 50 MB is reached — not expected immediately; this step just confirms
the directory and active file exist).

---

## Self-Review notes

- **Spec coverage:** static exporter (Task 2), L7-only filter (Task 1+2),
  chart-default path (Task 2), rotation 50MB×5 gzip (Task 2), GitOps source of
  truth (Task 2 edits values.yaml, Task 3 syncs via ArgoCD), empirical
  verification incl. the filter-value risk called out in the spec (Tasks 1 & 4).
- **Out of scope (per spec):** the logs collector DaemonSet on dip — not in this plan.
- **No code tests:** this is a config/deploy change; verification is live-cluster
  observation, which is the appropriate "test" here.
```
