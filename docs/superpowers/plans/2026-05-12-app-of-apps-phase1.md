# App-of-Apps Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create wrapper subcharts for cilium, argocd, and crossplane; update parent chart to point to them with manifest-generate-paths annotations.

**Architecture:** Each component gets a thin wrapper subchart that declares the upstream chart as a dependency. Parent chart renders Application CRs pointing to subchart paths in this repo. Dynamic values (clusterHost, clusterFqdn) passed via valuesObject.

**Tech Stack:** Helm 3, ArgoCD Applications, YAML

---

## File Structure

**New files to create:**
- `charts/cilium/Chart.yaml` - wrapper declaring helm.cilium.io dependency
- `charts/cilium/values.yaml` - static cilium configuration
- `charts/argocd/Chart.yaml` - wrapper declaring argo-helm dependency  
- `charts/argocd/values.yaml` - static argocd configuration
- `charts/crossplane/Chart.yaml` - wrapper declaring crossplane dependency
- `charts/crossplane/values.yaml` - static crossplane configuration

**Files to modify:**
- `charts/bootstrap/templates/cilium/cilium-app.yaml` - point to subchart, add manifest-generate-paths
- `charts/bootstrap/templates/argo-cd/argocd-app.yaml` - point to subchart, add manifest-generate-paths
- `charts/bootstrap/templates/crossplane/crossplane-app.yaml` - point to subchart, add manifest-generate-paths

---

### Task 1: Create Cilium Wrapper Subchart

**Files:**
- Create: `charts/cilium/Chart.yaml`
- Create: `charts/cilium/values.yaml`

- [ ] **Step 1: Create charts/cilium directory**

```bash
mkdir -p charts/cilium
```

- [ ] **Step 2: Create Chart.yaml with dependency**

Create `charts/cilium/Chart.yaml`:
```yaml
apiVersion: v2
name: cilium
version: 0.1.0
description: Thin wrapper for Cilium CNI
dependencies:
  - name: cilium
    # renovate: datasource=helm registryUrl=https://helm.cilium.io depName=cilium
    version: "1.19.3"
    repository: "https://helm.cilium.io/"
```

- [ ] **Step 3: Create values.yaml with static config**

Create `charts/cilium/values.yaml` with all static values (non-templated) from current cilium-app.yaml. Dynamic values like `k8sServiceHost` will be passed from parent.

- [ ] **Step 4: Build dependencies**

```bash
cd charts/cilium && helm dependency build
```

Expected: `Chart.lock` created, `charts/cilium-1.19.3.tgz` downloaded

- [ ] **Step 5: Verify template renders**

```bash
helm template test charts/cilium --set cilium.k8sServiceHost=test.example.com | head -50
```

Expected: Valid YAML output with cilium resources

- [ ] **Step 6: Commit**

```bash
git add charts/cilium/
git commit -m "feat: add cilium wrapper subchart"
```

---

### Task 2: Update Cilium Application CR

**Files:**
- Modify: `charts/bootstrap/templates/cilium/cilium-app.yaml`

- [ ] **Step 1: Update source to point to subchart**

Change `source` from external helm repo to local path:
```yaml
spec:
  source:
    repoURL: https://github.com/loafoe/k8s-aws-bootstrap
    path: charts/cilium
    targetRevision: HEAD
    helm:
      valuesObject:
        cilium:
          # Only dynamic values here
          k8sServiceHost: "{{ .Values.environmentConfig.bootstrap.clusterHost }}"
          k8sServicePort: "6443"
          # ... other dynamic values
```

- [ ] **Step 2: Add manifest-generate-paths annotation**

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/manifest-generate-paths: /charts/cilium
```

- [ ] **Step 3: Verify bootstrap chart renders**

```bash
helm template test charts/bootstrap -f charts/bootstrap/values.yaml \
  --set environmentConfig.bootstrap.clusterHost=test.example.com \
  --set environmentConfig.bootstrap.clusterFqdn=test.example.com \
  --set environmentConfig.bootstrap.ipv4ClusterCIDR=10.42.0.0/16 \
  | grep -A 30 "name: cilium"
```

Expected: Application CR with source.path=charts/cilium

- [ ] **Step 4: Commit**

```bash
git add charts/bootstrap/templates/cilium/
git commit -m "feat: point cilium app to wrapper subchart"
```

---

### Task 3: Create Crossplane Wrapper Subchart

**Files:**
- Create: `charts/crossplane/Chart.yaml`
- Create: `charts/crossplane/values.yaml`

- [ ] **Step 1: Create directory and Chart.yaml**

```bash
mkdir -p charts/crossplane
```

Create `charts/crossplane/Chart.yaml`:
```yaml
apiVersion: v2
name: crossplane
version: 0.1.0
description: Thin wrapper for Crossplane
dependencies:
  - name: crossplane
    # renovate: datasource=github-releases depName=crossplane/crossplane
    version: "v2.2.1"
    repository: "https://charts.crossplane.io/stable"
```

- [ ] **Step 2: Create values.yaml with static config**

Create `charts/crossplane/values.yaml` with static values from current crossplane-app.yaml.

- [ ] **Step 3: Build and verify**

```bash
cd charts/crossplane && helm dependency build
helm template test charts/crossplane | head -50
```

- [ ] **Step 4: Commit**

```bash
git add charts/crossplane/
git commit -m "feat: add crossplane wrapper subchart"
```

---

### Task 4: Update Crossplane Application CR

**Files:**
- Modify: `charts/bootstrap/templates/crossplane/crossplane-app.yaml`

- [ ] **Step 1: Update source and add annotation**

Update to point to subchart with manifest-generate-paths annotation.

- [ ] **Step 2: Verify and commit**

```bash
helm template test charts/bootstrap ... | grep -A 20 "name: crossplane"
git add charts/bootstrap/templates/crossplane/
git commit -m "feat: point crossplane app to wrapper subchart"
```

---

### Task 5: Create ArgoCD Wrapper Subchart

**Files:**
- Create: `charts/argocd/Chart.yaml`
- Create: `charts/argocd/values.yaml`

- [ ] **Step 1: Create directory and Chart.yaml**

Note: ArgoCD uses OCI registry, dependency format differs:
```yaml
apiVersion: v2
name: argocd
version: 0.1.0
description: Thin wrapper for Argo CD
dependencies:
  - name: argo-cd
    # renovate: datasource=docker depName=ghcr.io/argoproj/argo-helm/argo-cd
    version: "9.5.13"
    repository: "oci://ghcr.io/argoproj/argo-helm"
```

- [ ] **Step 2: Create values.yaml with static config**

- [ ] **Step 3: Build and verify**

- [ ] **Step 4: Commit**

---

### Task 6: Update ArgoCD Application CR

**Files:**
- Modify: `charts/bootstrap/templates/argo-cd/argocd-app.yaml`

- [ ] **Step 1: Update source and add annotation**

- [ ] **Step 2: Verify and commit**

---

### Task 7: Integration Test

- [ ] **Step 1: Template entire bootstrap chart**

```bash
helm template test charts/bootstrap \
  -f charts/bootstrap/values.yaml \
  --set environmentConfig.bootstrap.clusterHost=test.example.com \
  --set environmentConfig.bootstrap.clusterFqdn=test.example.com \
  --set environmentConfig.bootstrap.ipv4ClusterCIDR=10.42.0.0/16 \
  > /tmp/bootstrap-test.yaml
```

- [ ] **Step 2: Verify all three apps have correct structure**

```bash
grep -E "manifest-generate-paths|path: charts/" /tmp/bootstrap-test.yaml
```

Expected: 3 apps with manifest-generate-paths pointing to their subchart paths

- [ ] **Step 3: Push and test on cluster**

```bash
git push
```

Monitor ArgoCD for successful sync of cilium, crossplane, argocd apps.
