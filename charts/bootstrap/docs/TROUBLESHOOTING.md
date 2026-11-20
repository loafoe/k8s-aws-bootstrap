# Crossplane Troubleshooting

## TLS CA Mismatch Between Crossplane and Functions

### Symptoms
- Functions show as INSTALLED but not HEALTHY
- Composite resources stuck in non-ready state
- Crossplane logs show TLS handshake errors when calling functions
- Errors like `certificate signed by unknown authority` or `x509: certificate has expired`

### Root Cause
Crossplane manages its own internal PKI. The crossplane pod generates a CA and stores it in `crossplane-tls-server` and `crossplane-tls-client` secrets. Functions and providers get their TLS certs signed by this CA.

A CA mismatch occurs when:
1. Crossplane core keeps its existing CA (from `crossplane-tls-server`)
2. Functions get reinstalled/upgraded, creating new `FunctionRevision` resources
3. New revisions generate fresh TLS certs, but with a **different CA**
4. Crossplane tries to verify function certs using the old CA - TLS handshake fails

This can happen after:
- Function version upgrades
- ArgoCD re-syncing the crossplane-functions Application
- Manual deletion of function pods or secrets

### Diagnosis

Compare CA fingerprints between crossplane and functions:

```bash
# Get crossplane CA fingerprint
kubectl get secret -n crossplane-system crossplane-tls-server \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | \
  openssl x509 -noout -fingerprint -sha256

# Get function CA fingerprint (repeat for each function)
kubectl get secret -n crossplane-system function-patch-and-transform-tls-server \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | \
  openssl x509 -noout -fingerprint -sha256
```

If fingerprints differ, you have a CA mismatch.

Check secret creation timestamps to understand what happened:

```bash
kubectl get secret -n crossplane-system -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp' | grep tls
```

### Fix

Restart the crossplane deployment to regenerate the CA and all dependent certs:

```bash
kubectl rollout restart deploy/crossplane -n crossplane-system
```

This will:
1. Regenerate the crossplane CA
2. Trigger function pods to restart and get new certs signed by the new CA
3. All CAs will match again

Verify functions are healthy after restart:

```bash
kubectl get functions
```

### Prevention

There is currently no built-in mechanism in crossplane to prevent this. The TLS PKI is managed internally without support for external certificate management (e.g., cert-manager).

Best practices:
- When upgrading crossplane core, also sync/restart functions
- Monitor function health status
- If automating crossplane upgrades, include a rolling restart of the crossplane deployment after function upgrades

# Argo CD Project Troubleshooting

## The root app no longer syncs: "is not permitted in project"

### Symptoms

`bootstrap` (or a child Application) fails to sync with `namespace X is not permitted in project 'k8s-aws-bootstrap'`, `resource G:K is not permitted in project ...` or `application repo ... is not permitted in project ...`.

### Root Cause

Every bootstrap Application, the root included, runs in the `k8s-aws-bootstrap` AppProject that `templates/argo-cd/appproject.yaml` renders. Argo CD checks a whole sync against the project before applying anything, so once the live project lacks a namespace or source that the root still deploys, the root cannot sync the commit that adds it back. `scripts/check-appproject.sh` (run in CI) is meant to catch this before merge.

### Fix

Sync only the AppProject. A selective sync checks only the selected resources:

```bash
argocd app sync bootstrap --resource argoproj.io:AppProject:k8s-aws-bootstrap
```

Without the CLI, add the missing entry to the live project with `kubectl edit appproject k8s-aws-bootstrap -n argocd`. The next root sync overwrites it with the rendered spec.
