# App-of-Apps Redesign for Selective Reconciliation

**Date:** 2026-05-12  
**Status:** Approved  
**Author:** Andy + Claude

## Problem

Every commit to k8s-aws-bootstrap triggers full manifest regeneration for all 63 templates. ArgoCD reconciles ALL applications even when only one component changed. This causes:

- Controller memory pressure (OOMKilled at 1Gi)
- Slow sync times
- Poor developer experience when iterating on single components

## Solution

Restructure from single monolithic Helm chart to App-of-Apps pattern with thin wrapper subcharts. Each component sources from this repo, enabling `manifest-generate-paths` annotation to scope reconciliation.

## Architecture

### Directory Structure

```
charts/
├── bootstrap/                    # Parent chart (slim)
│   ├── Chart.yaml               
│   ├── values.yaml              # Feature flags, defaults
│   └── templates/
│       ├── _helpers.tpl         # Shared template functions
│       ├── cilium-app.yaml      # Renders Application CR for cilium
│       ├── argocd-app.yaml      # Renders Application CR for argocd
│       ├── crossplane-app.yaml  # ...etc
│       └── ...
│
├── cilium/                       # Thin wrapper subchart
│   ├── Chart.yaml               # Depends on helm.cilium.io/cilium
│   └── values.yaml              # Static defaults/customizations
│
├── argocd/                       # Thin wrapper subchart
│   ├── Chart.yaml               # Depends on oci://ghcr.io/argoproj/argo-helm
│   └── values.yaml
│
├── crossplane/
├── cert-manager/
├── spiffe/
└── ...                           # ~15 component subcharts
```

### Data Flow

```
Pulumi → SSM → Master UserData → bootstrap HelmApplication
                                          ↓
                              charts/bootstrap renders Application CRs
                                          ↓
              ┌─────────────────────┬─────────────────────┬─────────────
              ↓                     ↓                     ↓
         charts/cilium        charts/argocd       charts/crossplane
         (wrapper subchart)   (wrapper subchart)  (wrapper subchart)
              ↓                     ↓                     ↓
         helm.cilium.io        oci://ghcr.io/...   charts.crossplane.io
         (external dep)        (external dep)      (external dep)
```

### Wrapper Subchart Structure

Each thin wrapper:

```yaml
# charts/cilium/Chart.yaml
apiVersion: v2
name: cilium
version: 0.1.0
dependencies:
  - name: cilium
    version: "1.19.3"
    repository: "https://helm.cilium.io/"
```

```yaml
# charts/cilium/values.yaml
cilium:
  # Static defaults and customizations
  kubeProxyReplacement: true
  gatewayAPI:
    enabled: true
  resources:
    limits:
      memory: 384Mi
```

### Values Injection

Parent chart computes dynamic values and passes them to child Applications:

```yaml
# charts/bootstrap/templates/cilium-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/manifest-generate-paths: /charts/cilium
spec:
  source:
    repoURL: https://github.com/loafoe/k8s-aws-bootstrap
    path: charts/cilium
    helm:
      valuesObject:
        cilium:
          k8sServiceHost: {{ .Values.environmentConfig.bootstrap.clusterHost }}
          k8sServicePort: "6443"
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
```

### Sync-Wave Preservation

Current waves (0-22) preserved via annotations on each Application CR:

| Wave | Components |
|------|------------|
| 0 | cilium, gateway-api CRDs |
| 1 | crossplane, crossplane-functions |
| 3-5 | cert-manager, kyverno, external-secrets |
| 7-10 | AWS components, argocd |
| 13+ | spiffe, kube-prometheus-stack, platform addons |

### Feature Flags

Conditional rendering in parent chart (unchanged):

```yaml
# charts/bootstrap/templates/spiffe-app.yaml
{{- if .Values.features.spiffe.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spire
  annotations:
    argocd.argoproj.io/sync-wave: "13"
    argocd.argoproj.io/manifest-generate-paths: /charts/spiffe
spec:
  # ...
{{- end }}
```

## Constraints Preserved

| Constraint | How Preserved |
|------------|---------------|
| Single source of truth | All components in one repo |
| Shared values injection | Parent passes `environmentConfig` to children |
| Sync-wave ordering | Annotations on Application CRs |
| Feature flags | Conditional rendering in parent |
| Drop-in replacement | Pulumi unchanged, same values structure |

## Benefits

| Metric | Before | After |
|--------|--------|-------|
| Reconciliation scope | All 63 templates | Only affected component |
| Controller memory | High pressure | Reduced |
| Sync time | Slow (full re-eval) | Fast (single app) |
| Developer iteration | Change one, wait for all | Change one, reconcile one |

## Migration Path

Incremental migration, each phase is a working state:

1. **Phase 1:** Create wrapper subcharts for pilot components (cilium, argocd, crossplane)
2. **Phase 2:** Update parent to render Applications pointing to subcharts
3. **Phase 3:** Test on non-production cluster
4. **Phase 4:** Migrate remaining ~12 components
5. **Phase 5:** Remove old inline valuesObject templates

## Components to Migrate

Based on current `charts/bootstrap/templates/` structure:

| Directory | Sync Wave | External Chart Source |
|-----------|-----------|----------------------|
| cilium | 0 | https://helm.cilium.io/ |
| crds/gateway-api | 0 | (raw CRDs) |
| crossplane | 1 | https://charts.crossplane.io/stable |
| crossplane-functions | 1 | oci://ghcr.io/philips-software/helm-charts |
| crossplane-providers | 18 | oci://ghcr.io/philips-software/helm-charts |
| cert-manager | 3 | https://charts.jetstack.io |
| kyverno | 4 | https://kyverno.github.io/kyverno |
| eso | 5 | https://charts.external-secrets.io |
| aws/ebs-csi | 7 | https://kubernetes-sigs.github.io/aws-ebs-csi-driver/ |
| aws/load-balancer-controller | 6 | https://aws.github.io/eks-charts |
| aws/external-dns | 6 | https://kubernetes-sigs.github.io/external-dns/ |
| aws/snapshot-controller | 7 | (raw manifests or chart) |
| aws/pod-identity-webhook | 4 | (raw manifests) |
| argo-cd | 10 | oci://ghcr.io/argoproj/argo-helm |
| spiffe | 13 | https://spiffe.github.io/helm-charts-hardened/ |
| karpenter | 12 | oci://public.ecr.aws/karpenter |
| kube-prometheus-stack | 21 | https://prometheus-community.github.io/helm-charts |
| hsp-aws-platform/* | 14-22 | various |
| gateway-api | 17-19 | (raw manifests + config) |

## Future Path

This structure enables future migration to ApplicationSet if desired:
- Each subchart directory becomes an ApplicationSet target
- Git generator scans `charts/*/Chart.yaml`
- Cluster Secret provides values (minor Pulumi change)

## Non-Chart Components

Some components are raw manifests (CRDs, webhook configs) rather than Helm charts:

- **gateway-api CRDs:** Keep as raw manifests in `charts/gateway-api-crds/templates/`
- **pod-identity-webhook:** Keep as raw manifests in `charts/pod-identity-webhook/templates/`
- **snapshot-controller:** Keep as raw manifests or wrap if chart available

These still benefit from selective reconciliation via `manifest-generate-paths`.

## Risks

| Risk | Mitigation |
|------|------------|
| Wrapper subchart adds indirection | Keep wrappers thin, mostly just Chart.yaml + values.yaml |
| Helm dependency updates | Renovate annotations work the same in subchart Chart.yaml |
| Testing complexity | Each subchart can be tested independently with `helm template` |
