# Descheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the Kubernetes descheduler to automatically evict crashlooping pods and rebalance overloaded nodes.

**Architecture:** Thin wrapper Helm chart around upstream kubernetes-sigs/descheduler, deployed via ArgoCD Application with feature flag gating. Runs as a Deployment with continuous 5-minute descheduling interval.

**Tech Stack:** Helm, ArgoCD, kubernetes-sigs/descheduler

---

## File Structure

```
charts/descheduler/
├── Chart.yaml                    # Thin wrapper depending on upstream descheduler chart
└── values.yaml                   # Strategy configuration (profiles, thresholds, scheduling)

charts/bootstrap/
├── values.yaml                   # Add features.descheduler.enabled flag
└── templates/descheduler/
    ├── namespace.yaml            # descheduler namespace with pod-security label
    └── descheduler-app.yaml      # ArgoCD Application (conditional on feature flag)
```

---

### Task 1: Create descheduler wrapper chart

**Files:**
- Create: `charts/descheduler/Chart.yaml`

- [ ] **Step 1: Create chart directory**

Run:
```bash
mkdir -p charts/descheduler
```

- [ ] **Step 2: Create Chart.yaml**

Create `charts/descheduler/Chart.yaml`:
```yaml
apiVersion: v2
name: descheduler
version: 0.1.0
description: Thin wrapper for Kubernetes Descheduler
dependencies:
  - name: descheduler
    # renovate: datasource=helm registryUrl=https://kubernetes-sigs.github.io/descheduler depName=descheduler
    version: "0.35.1"
    repository: "https://kubernetes-sigs.github.io/descheduler"
```

- [ ] **Step 3: Commit**

Run:
```bash
git add charts/descheduler/Chart.yaml
git commit -m "feat(descheduler): add wrapper chart"
```

---

### Task 2: Configure descheduler values

**Files:**
- Create: `charts/descheduler/values.yaml`

- [ ] **Step 1: Create values.yaml with strategy configuration**

Create `charts/descheduler/values.yaml`:
```yaml
descheduler:
  kind: Deployment
  deschedulingInterval: 5m
  replicas: 1

  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      memory: 128Mi

  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: karpenter.sh/nodepool
                operator: DoesNotExist
              - key: node-type
                operator: In
                values:
                  - system
                  - control-plane

  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists

  deschedulerPolicy:
    profiles:
      - name: default
        pluginConfig:
          - name: RemovePodsHavingTooManyRestarts
            args:
              podRestartThreshold: 5
              includingInitContainers: true

          - name: LowNodeUtilization
            args:
              thresholds:
                cpu: 30
                memory: 30
              targetThresholds:
                cpu: 70
                memory: 70
              evictableNamespaces:
                exclude:
                  - kube-system
                  - karpenter
                  - argocd
                  - cert-manager

          - name: RemovePodsViolatingTopologySpreadConstraint
            args:
              evictableNamespaces:
                exclude:
                  - kube-system
                  - karpenter

        plugins:
          balance:
            enabled:
              - LowNodeUtilization
              - RemovePodsViolatingTopologySpreadConstraint
          deschedule:
            enabled:
              - RemovePodsHavingTooManyRestarts
```

- [ ] **Step 2: Commit**

Run:
```bash
git add charts/descheduler/values.yaml
git commit -m "feat(descheduler): configure strategies and scheduling"
```

---

### Task 3: Build Helm dependencies

**Files:**
- Modify: `charts/descheduler/` (adds Chart.lock and charts/)

- [ ] **Step 1: Build dependencies**

Run:
```bash
helm dependency build charts/descheduler
```

Expected: Creates `charts/descheduler/Chart.lock` and downloads chart to `charts/descheduler/charts/`

- [ ] **Step 2: Commit dependencies**

Run:
```bash
git add charts/descheduler/Chart.lock charts/descheduler/charts/
git commit -m "chore(descheduler): build helm dependencies"
```

---

### Task 4: Add feature flag to bootstrap values

**Files:**
- Modify: `charts/bootstrap/values.yaml`

- [ ] **Step 1: Add descheduler feature flag**

In `charts/bootstrap/values.yaml`, add under the `features:` section (after `kubePrometheusStack`):

```yaml
  # Descheduler for pod rebalancing
  descheduler:
    enabled: true
```

- [ ] **Step 2: Commit**

Run:
```bash
git add charts/bootstrap/values.yaml
git commit -m "feat(bootstrap): add descheduler feature flag"
```

---

### Task 5: Create descheduler namespace template

**Files:**
- Create: `charts/bootstrap/templates/descheduler/namespace.yaml`

- [ ] **Step 1: Create descheduler templates directory**

Run:
```bash
mkdir -p charts/bootstrap/templates/descheduler
```

- [ ] **Step 2: Create namespace.yaml**

Create `charts/bootstrap/templates/descheduler/namespace.yaml`:
```yaml
{{- if .Values.features.descheduler.enabled }}
apiVersion: v1
kind: Namespace
metadata:
  name: descheduler
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  labels:
    pod-security.kubernetes.io/enforce: restricted
{{- end }}
```

- [ ] **Step 3: Commit**

Run:
```bash
git add charts/bootstrap/templates/descheduler/namespace.yaml
git commit -m "feat(descheduler): add namespace template"
```

---

### Task 6: Create ArgoCD Application template

**Files:**
- Create: `charts/bootstrap/templates/descheduler/descheduler-app.yaml`

- [ ] **Step 1: Create descheduler-app.yaml**

Create `charts/bootstrap/templates/descheduler/descheduler-app.yaml`:
```yaml
{{- if .Values.features.descheduler.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: descheduler
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "21"
    argocd.argoproj.io/manifest-generate-paths: /charts/descheduler
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: {{ .Values.project }}
  source:
    repoURL: https://github.com/loafoe/k8s-aws-bootstrap
    path: charts/descheduler
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: descheduler

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - HealthCheckTimeout=10m
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 3
{{- end }}
```

- [ ] **Step 2: Commit**

Run:
```bash
git add charts/bootstrap/templates/descheduler/descheduler-app.yaml
git commit -m "feat(descheduler): add ArgoCD application template"
```

---

### Task 7: Validate Helm templates

**Files:**
- None (validation only)

- [ ] **Step 1: Template the bootstrap chart with descheduler enabled**

Run:
```bash
helm template bootstrap charts/bootstrap --set features.descheduler.enabled=true 2>&1 | grep -A 50 "kind: Application" | grep -A 50 "name: descheduler"
```

Expected: Valid YAML output showing the descheduler Application with correct namespace and sync settings

- [ ] **Step 2: Template the bootstrap chart with descheduler disabled**

Run:
```bash
helm template bootstrap charts/bootstrap --set features.descheduler.enabled=false 2>&1 | grep "descheduler" || echo "No descheduler resources (expected)"
```

Expected: "No descheduler resources (expected)" — confirms feature flag works

- [ ] **Step 3: Template the descheduler chart directly**

Run:
```bash
helm template descheduler charts/descheduler 2>&1 | head -100
```

Expected: Valid YAML output showing Deployment (not CronJob) with correct affinity and tolerations

---

### Task 8: Final review and squash commits (optional)

**Files:**
- None

- [ ] **Step 1: Review all changes**

Run:
```bash
git log --oneline HEAD~6..HEAD
git diff HEAD~6..HEAD --stat
```

- [ ] **Step 2: Push or create PR**

If ready to deploy, push to trigger ArgoCD sync or create a PR for review.
