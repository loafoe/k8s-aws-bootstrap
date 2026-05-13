# Descheduler Design

Add the Kubernetes descheduler to complement Karpenter, addressing scenarios where pods accumulate on overloaded nodes and crashloop without automated intervention.

## Problem

Karpenter manages node provisioning and consolidation but doesn't intervene when:
- Pods crashloop due to resource pressure on a node
- Nodes become overloaded over time through gradual pod accumulation
- Topology spread constraints are violated after initial scheduling

The recent incident on obs-us-east-ct demonstrated this gap: 7 pods crashlooped repeatedly, requiring manual eviction.

## Solution

Deploy the kubernetes-sigs/descheduler as an opt-out feature (enabled by default) using the existing thin wrapper Helm chart pattern.

## Chart Structure

```
charts/descheduler/
├── Chart.yaml          # Wrapper depending on upstream descheduler
└── values.yaml         # Strategy configuration

charts/bootstrap/templates/descheduler/
├── namespace.yaml      # descheduler namespace
└── descheduler-app.yaml  # ArgoCD Application
```

## Feature Flag

In `charts/bootstrap/values.yaml`:

```yaml
features:
  descheduler:
    enabled: true  # default on
```

## Strategies

Three strategies enabled:

### RemovePodsHavingTooManyRestarts
Evicts pods exceeding 5 restarts. Applies to **all namespaces** including system namespaces — crashlooping system pods need intervention.

```yaml
- name: RemovePodsHavingTooManyRestarts
  args:
    podRestartThreshold: 5
    includingInitContainers: true
```

### LowNodeUtilization
Rebalances pods from overutilized nodes (>70% CPU/memory) to underutilized nodes (<30%). Conservative thresholds avoid fighting Karpenter's consolidation.

Excludes namespaces: `kube-system`, `karpenter`, `argocd`, `cert-manager`

```yaml
- name: LowNodeUtilization
  args:
    thresholds:
      cpu: 30
      memory: 30
    targetThresholds:
      cpu: 70
      memory: 70
```

### RemovePodsViolatingTopologySpreadConstraint
Enforces topology spread constraints after initial scheduling. Ready for workloads that define TSCs.

Excludes namespaces: `kube-system`, `karpenter`

## Strategies Not Included

- **RemoveDuplicates** — conflicts with Karpenter's consolidation (causes churn)
- **HighNodeUtilization** — redundant with Karpenter's `WhenEmptyOrUnderutilized` consolidation

## Deployment Configuration

**Mode:** Deployment with `--descheduling-interval=5m` (continuous monitoring, not CronJob)

**Scheduling:**
- Tolerates `CriticalAddonsOnly` taint
- Node affinity for system/non-Karpenter nodes
- Single replica

**Resources:**
```yaml
resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    memory: 128Mi
```

## Eviction Safety

Built-in protections (defaults):
- Respects PodDisruptionBudgets
- Won't evict pods without ownerReferences
- Won't evict DaemonSet pods
- Won't evict pods with local storage

## Files to Create/Modify

1. `charts/descheduler/Chart.yaml` — thin wrapper chart
2. `charts/descheduler/values.yaml` — strategy configuration
3. `charts/bootstrap/values.yaml` — add feature flag
4. `charts/bootstrap/templates/descheduler/namespace.yaml` — namespace
5. `charts/bootstrap/templates/descheduler/descheduler-app.yaml` — ArgoCD Application
