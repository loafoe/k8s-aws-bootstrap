# Prometheus Retention

`kps-prometheus` (the `kube-prometheus-stack` chart) sets explicit retention
bounds rather than relying on upstream defaults: **14 days, or 40GB,
whichever is reached first**, on a 50Gi volume. Both the period and the size
cap can be changed per cluster from the Argo CD UI without a Git change.

## Why a size cap, not just a time bound

Prometheus deletes whole persisted blocks to honour `retention.size`. With
no size bound, the only limit on disk usage is the volume itself, and the
failure mode when it fills is `ENOSPC` (the WAL replay/compaction crashing),
not "oldest data dropped". The 40GB cap is what makes raising the retention
period safe: it stops the disk from ever filling, trading retention length
for disk safety instead of crashing.

The cap only works because the volume is large enough to hold it:
Prometheus recommends keeping `retention.size` at **80-85% of the allocated
volume**, because compaction keeps the source blocks and the new compacted
block on disk at the same time, so usage transiently exceeds the cap. 40GB
on a 50Gi volume is exactly 80% — raising the cap without raising the volume
returns to the original disk-full failure, so change the pair together.

## Feature flag (`charts/bootstrap/values.yaml`)

```yaml
features:
  kubePrometheusStack:
    enabled: true
    grafana:
      enabled: false
    # Empty = use the kube-prometheus-stack chart defaults (14d / 40GB / 50Gi).
    # Set any of these to override per cluster from the Argo CD UI.
    prometheus:
      retention: ""
      retentionSize: ""
      storageSize: ""
```

Leaving all three empty (the default) uses the `kube-prometheus-stack`
chart's own defaults — `retention: "14d"`, `retentionSize: "40GB"`,
`storageSpec...storage: 50Gi` — set in
`charts/kube-prometheus-stack/values.yaml`. Each override is passed through
to the child `Application/kube-prometheus-stack` only when non-empty; an
empty value never reaches the `Prometheus` custom resource.

### Preconditions

- The `bootstrap` Application tracks a chart release containing this flag.
- `Application/kube-prometheus-stack` is `Synced`/`Healthy`.
- Raising `retentionSize` beyond 40GB on the default 50Gi volume breaks the
  80% rule above — raise `storageSize` in the same change (see
  "Resizing the volume" below).

### Enable an override (Argo CD UI)

1. Open the Argo CD UI and select the **`bootstrap`** application
   (namespace `argocd`).
2. Open its **Parameters** panel (Helm parameters), or use
   **Edit → Application YAML** if your Argo CD version only exposes
   parameters read-only.
3. Add a Helm parameter, e.g. to shorten retention to 7 days:

   | Name | Value |
   |---|---|
   | `features.kubePrometheusStack.prometheus.retention` | `7d` |

   YAML-editor equivalent — merge into `spec.source.helm.valuesObject`:

   ```yaml
   features:
     kubePrometheusStack:
       prometheus:
         retention: "7d"
   ```

4. Save, then **Sync** the `bootstrap` application (auto-sync off means this
   click is required), followed by `Application/kube-prometheus-stack`.
5. No pod restart is required: this cluster runs Prometheus v3.15.1, where
   the operator writes retention into the generated config, and the
   config-reloader sidecar reloads the running server automatically.

### Verify

The operator's input (`Prometheus.spec`) is not what Prometheus actually
reads on this version — since v3.11 the operator writes retention into the
**generated config file**, not the container args, so check both:

```bash
# the operator's input
kubectl -n prometheus get prometheus kps-prometheus \
  -o jsonpath='{.spec.retention} {.spec.retentionSize}{"\n"}'   # e.g. 7d 40GB

# what Prometheus actually reads
kubectl -n prometheus get secret prometheus-kps-prometheus \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep -A4 'retention:'
```

Grepping the StatefulSet's container args (`kubectl ... get sts -o yaml |
grep retention`) proves nothing on this Prometheus version — it is not where
the value lives.

### Disable (revert to chart defaults)

Remove the parameter, or set it back to `""`, then sync `bootstrap` and
`kube-prometheus-stack`. The chart's own defaults (14d / 40GB / 50Gi) apply
again.

## Resizing the volume

`storageSize` changes `Prometheus.spec.storage.volumeClaimTemplate`, which
the operator copies into `StatefulSet.spec.volumeClaimTemplates` — an
**immutable** field. Growing the PVC itself is online (`gp3-encrypted` has
`allowVolumeExpansion: true`), but the StatefulSet's template has to be
recreated to pick up a new value:

```bash
# 1. expand the live PVC first, and wait for capacity to catch up
kubectl -n prometheus patch pvc <prometheus-pvc-name> \
  -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'
kubectl -n prometheus get pvc -w

# 2. once the chart change has synced, recreate the StatefulSet so its
#    (immutable) volumeClaimTemplates matches — the running pod is adopted,
#    not killed
kubectl -n prometheus delete statefulset kps-prometheus --cascade=orphan
kubectl -n prometheus rollout status statefulset/kps-prometheus
```

Doing this in the other order (chart first, PVC later) leaves a window
where the template says the new size and the claim says the old one, and
the operator keeps failing that update. PVCs cannot shrink, so prefer not
reverting a volume increase.

## Caveats

- An Argo CD UI parameter is drift relative to the IaC that creates
  `Application/bootstrap` (Pulumi/SSM). A re-provisioning `pulumi up` may
  reconcile it away. Promote any lasting choice into the Pulumi/SSM
  bootstrap values if it should survive re-provisioning.
- If ingest grows, 14 days of blocks can exceed 40GB; the size cap then
  binds first and effective retention silently drops below 14d. That is the
  intended "whichever is reached first" behaviour, but watch
  `prometheus_tsdb_storage_blocks_bytes` against the 40GB cap and the oldest
  block's age (`prometheus_tsdb_lowest_timestamp`) against the retention
  period if this matters for your cluster.
- Do not use `retentionPercentage`: if it is set, Prometheus ignores
  `retention.size` entirely, and it silently changes effective retention
  whenever the PVC is resized.

### CLI fallback

The `argocd` CLI is documented as broken behind the Cilium Gateway API setup
used here (see [`argocd-cli-grpc-cilium-gateway.md`](argocd-cli-grpc-cilium-gateway.md)),
so prefer the UI or `kubectl`. If you must patch the Application directly,
a JSON Patch `add` on `/spec/source/helm/parameters` **replaces the entire
existing parameter list** — the UI path avoids that footgun. A merge-safe
patch appends instead of overwriting; read the Application first so you
know the index to use, e.g.:

```bash
kubectl -n argocd patch application bootstrap --type=json -p \
  '[{"op":"add","path":"/spec/source/helm/parameters/-","value":{"name":"features.kubePrometheusStack.prometheus.retention","value":"7d"}}]'
```
