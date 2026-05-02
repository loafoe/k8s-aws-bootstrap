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
