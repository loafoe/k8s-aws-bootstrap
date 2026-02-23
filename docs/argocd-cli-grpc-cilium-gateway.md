# ArgoCD CLI gRPC with Cilium Gateway API

This document explains why the ArgoCD CLI fails with a 404 when using a Cilium Gateway API setup, and the exact changes required to fix it.

## Environment

- Cilium 1.16+ with Gateway API enabled
- Shared `platform` Gateway (TLS termination, wildcard cert)
- ArgoCD running in `--insecure` mode (HTTP/1.1 on port 8080)
- No `BackendTLSPolicy` support (unavailable in Cilium ≤ 1.15, and not needed for this fix)

## Symptom

```
argocd login --username admin --grpc-web --password "..." argocd.example.com

FATA rpc error: code = Unknown desc = POST http://argocd.example.com/session.SessionService/Create
     failed with status code 404
```

Or without `--grpc-web` (native gRPC):

```
FATA rpc error: code = Unimplemented desc =
```

The ArgoCD web UI works fine. Only the CLI is broken.

## Root Cause

Three compounding issues in the Cilium Envoy → ArgoCD path:

### 1. No ALPN on the TLS listener

By default (`enable-gateway-api-alpn: false`), Cilium's Envoy does not advertise ALPN protocols on its TLS listener. The gRPC protocol **requires** HTTP/2, and HTTP/2 over TLS requires ALPN negotiation of `h2`. Without it, gRPC clients fall back to HTTP/1.1 and the call fails.

You can confirm this with:

```bash
curl -sv --http2 https://argocd.example.com/... 2>&1 | grep "ALPN"
# ALPN: server did not agree on a protocol. Uses default.
```

### 2. Wrong upstream protocol for the ArgoCD cluster

Cilium generates a `CiliumEnvoyConfig` (CEC) for each Gateway. By default, every backend cluster uses `useDownstreamProtocolConfig`, which means Envoy mirrors whatever protocol the downstream client used. This sounds correct, but it interacts badly with the `grpc_web` Envoy filter (see below).

The CEC cluster entry looks like:

```yaml
typedExtensionProtocolOptions:
  envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
    useDownstreamProtocolConfig:
      http2ProtocolOptions: {}
```

With `enable-gateway-api-app-protocol: true` and `appProtocol: kubernetes.io/h2c` on the service port, Cilium instead generates:

```yaml
typedExtensionProtocolOptions:
  envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
    explicitHttpConfig:
      http2ProtocolOptions: {}   # explicit h2c upstream
```

### 3. The `grpc_web` Envoy filter breaks gRPC-Web → HTTP/1.1 upstream

Cilium always installs the `envoy.filters.http.grpc_web` filter on every listener. This filter converts gRPC-Web (HTTP/1.1 framing) into native gRPC (HTTP/2 framing) before the request is forwarded upstream. The upstream cluster then needs to speak HTTP/2 (h2c). ArgoCD in `--insecure` mode only speaks HTTP/1.1, so the converted request arrives malformed and ArgoCD returns 404.

This is why `--grpc-web` does not help — the filter converts it anyway and the upstream can't handle it.

### Summary

| Layer | Default behaviour | Problem |
|---|---|---|
| TLS listener | No ALPN | gRPC client can't negotiate HTTP/2 |
| Upstream cluster | `useDownstreamProtocolConfig` | `grpc_web` filter forces HTTP/2 upstream; ArgoCD only speaks HTTP/1.1 |
| Route | Single HTTPRoute → port 80 | No dedicated gRPC path with h2c upstream |

## Fix

Three changes are required.

### 1. Enable ALPN and appProtocol in Cilium

In the Cilium Helm values (`gatewayAPI` section):

```yaml
gatewayAPI:
  enabled: true
  enableAlpn: true          # advertise h2,http/1.1 on TLS listeners
  enableAppProtocol: true   # respect appProtocol on service ports
```

This maps to `cilium-config` keys:
- `enable-gateway-api-alpn: "true"`
- `enable-gateway-api-app-protocol: "true"`

The Cilium **operator** must be restarted to pick up these values.

### 2. Set `appProtocol: kubernetes.io/h2c` on the ArgoCD service

In the ArgoCD Helm values:

```yaml
server:
  service:
    servicePortHttpsAppProtocol: kubernetes.io/h2c
```

This sets `appProtocol: kubernetes.io/h2c` on the `https` (port 443) service port. With `enableAppProtocol: true` in Cilium, this causes the generated CEC cluster to use `explicitHttpConfig: http2ProtocolOptions` (h2c) instead of `useDownstreamProtocolConfig`. ArgoCD in insecure mode does speak h2c, so the upstream connection succeeds.

### 3. Add a GRPCRoute for ArgoCD

A `GRPCRoute` with a `Content-Type: application/grpc.*` header match routes gRPC traffic to port 443 (h2c upstream), while the existing `HTTPRoute` continues to serve browser traffic on port 80 (HTTP/1.1 upstream).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: argocd-grpc-route
  namespace: argocd
spec:
  parentRefs:
    - name: platform
      namespace: kube-system
      sectionName: https
  hostnames:
    - argocd.example.com
  rules:
    - matches:
        - headers:
          - name: Content-Type
            type: RegularExpression
            value: "application/grpc.*"
      backendRefs:
        - name: argocd-server
          port: 443
```

The header match ensures this route takes precedence over the catch-all HTTPRoute `prefix: /`. Envoy evaluates more-specific matches first.

## Resulting Envoy Configuration

After all three changes, the CEC contains:

**Route config** — gRPC traffic matched first:
```
Content-Type: application/grpc.* → cluster argocd:argocd-server:443  (h2c)
prefix: /                         → cluster argocd:argocd-server:80   (HTTP/1.1)
```

**Cluster for port 443** (h2c):
```yaml
explicitHttpConfig:
  http2ProtocolOptions: {}
```

**Cluster for port 80** (HTTP/1.1, browser traffic unaffected):
```yaml
explicitHttpConfig:
  httpProtocolOptions: {}
```

**TLS listener** (ALPN enabled):
```yaml
commonTlsContext:
  alpnProtocols: ["h2,http/1.1"]
```

## Working Login Command

```bash
argocd login argocd.example.com \
  --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d)"
```

No `--grpc-web` flag needed. The TLS warning prompt (`WARNING: server is not configured with TLS`) can be suppressed with `--insecure`.

## What Does NOT Work

- **Patching `cilium-config` directly** — ArgoCD manages this ConfigMap and reverts it on the next sync. The fix must go into the Cilium Helm values in the ArgoCD Application.
- **Patching the `CiliumEnvoyConfig` directly** — Cilium's gateway controller regenerates the CEC on every Gateway/Route reconciliation. Manual patches are immediately overwritten.
- **`--grpc-web` flag** — Does not bypass the `grpc_web` Envoy filter issue; the filter is always present on the listener and converts the request regardless.
- **`TLSRoute` / `TCPRoute` passthrough** — Not supported by Cilium's Gateway API implementation (only `HTTPRoute` and `GRPCRoute` are available).
