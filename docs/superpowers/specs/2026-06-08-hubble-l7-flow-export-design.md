# Hubble L7 Flow Export (Gateway API / Envoy access logs)

**Date:** 2026-06-08
**Cluster:** dip-ce-k3s-eu
**Status:** Design approved, pending spec review

## Problem

Cilium's Envoy (running as the external `cilium-envoy` DaemonSet) emits L7/HTTP
access logs for Gateway API traffic, but it ships them over a Unix domain socket
to the cilium-agent (Hubble) — **not** to stdout. Pod-stdout log scraping
therefore never sees Gateway API access logs.

The warning observed in `cilium-envoy` logs:

```
Logging to /var/run/cilium/envoy/sockets/access_log.sock failed: No such file or directory
```

was diagnosed as **benign and transient**: it fires only during a cilium-agent
restart, when the agent briefly tears down and recreates `access_log.sock`. The
socket exists in steady state (`srw-rw---- root:1337`), and zero occurrences were
seen in steady-state operation. This is not the problem being solved — it merely
surfaced the question of how to capture the L7 access logs.

## Goal

Make Cilium emit Gateway API / Envoy L7 access logs to a host file on each node,
with bounded disk usage (rotation), so that a log collector can tail and ship
them. **The collector itself is out of scope** — it will be configured
separately (mirroring the rpi homelab's `k8s-monitoring-alloy-logs` DaemonSet,
which does not yet exist on dip-ce-k3s-eu).

## Current state (evidence)

- Cilium 1.19.4, `external-envoy-proxy: true`, Gateway API enabled, Hubble enabled.
- `hubble observe --type l7` returns nothing today; no Hubble export flags set.
- **No log collector exists on dip-ce-k3s-eu** (checked every namespace/DaemonSet).
  The only Alloy here is `custom-alloy` — a metrics-only StatefulSet shipping OTLP
  to `otlp-gateway.rpi.loafoe.com`.
- The logs DaemonSet `k8s-monitoring-alloy-logs` lives on the **rpi** cluster, not dip.

## Decision

Use Cilium's **Hubble static flow exporter** (bound to agent lifecycle, native
lumberjack-style rotation built in). Source of truth:
`charts/cilium/values.yaml` (GitOps) — no live patching.

### Approved choices

| Decision | Choice | Rationale |
|---|---|---|
| Exporter type | **Static** | Simplest; rotation built in. Dynamic (ConfigMap-reconfigurable) not needed for a fixed "capture L7" filter. Trade-off: filter changes require an agent rollout — acceptable. |
| Filter | **L7 only** (`event_type` 129 = AccessLog) | Gateway API access logs are the L7/HTTP flow records. Unfiltered export captures all L3/L4 flows on every node — huge volume that drowns the access logs. |
| File path | **`/var/run/cilium/hubble/events.log`** (chart default) | tmpfs/RAM-backed, already mounted into the agent. Ephemeral (lost on reboot) is fine since a collector will ship off-node promptly. |
| Rotation | **50 MB × 5 backups, gzip** | ~250 MB/node ceiling, bounded RAM use. |

## Change

Add to the `hubble:` block in `charts/cilium/values.yaml`:

```yaml
hubble:
  export:
    static:
      enabled: true
      filePath: /var/run/cilium/hubble/events.log
      # 129 = AccessLog (L7/HTTP) monitor event — the Gateway API / Envoy
      # access logs. Excludes L3/L4 flow noise.
      allowList:
        - '{"event_type":[{"type":129}]}'
      fileMaxSizeMb: 50
      fileMaxBackups: 5
      fileCompress: true
```

## Rollout & verification

1. Commit values change; let ArgoCD sync the cilium app (`charts/bootstrap/templates/cilium/cilium-app.yaml`).
2. Cilium agent rolls (DaemonSet restart) to pick up the static exporter.
3. Drive some Gateway API traffic (e.g. curl an HTTPRoute host such as
   `argocd.dip-ce-k3s-eu.hsp.philips.com`).
4. Verify the file is being written on a node, via the agent pod:
   ```bash
   kubectl exec -n kube-system <cilium-pod> -c cilium-agent -- \
     tail -n 5 /var/run/cilium/hubble/events.log
   ```
   Expect JSONL records with `"Type":"L7"` / HTTP method, path, status, source/dest.
5. Confirm rotation works over time (rotated `.gz` siblings appear after 50 MB).

## Out of scope / follow-up

- **Log collector on dip-ce-k3s-eu.** A logs Alloy DaemonSet (port of rpi's
  `k8s-monitoring-alloy-logs`) is needed to tail `/var/run/cilium/hubble/events.log`
  via hostPath and ship to Loki/OTLP. Tracked separately.
- If persistence-before-collector becomes a requirement, revisit moving the file
  to a disk-backed host path (`/var/log/cilium/`) via `extraHostPathMounts`.
```
