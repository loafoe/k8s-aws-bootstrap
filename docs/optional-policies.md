# Optional Kyverno Policies

Some Kyverno guardrails are shipped by the `bootstrap` chart but rendered only
when explicitly enabled, so a fresh cluster starts without their background
scans, `PolicyReport`s, or admission cost. They can be switched on per
cluster without a Git change, via an Argo CD Application parameter.

## require-image-digest

`ValidatingPolicy/require-image-digest` requires every Pod container image to
be pinned by its immutable `@sha256:` digest, rather than a mutable tag. It
is `Audit`-only — nothing is ever denied — but most upstream images this
chart deploys are tag-pinned, so leaving it on by default would be a
permanent source of report noise.

Feature flag (`charts/bootstrap/values.yaml`):

```yaml
features:
  kyverno:
    # Optional Kyverno guardrails, off by default. Enable per cluster.
    requireImageDigest:
      enabled: false   # default
```

### Preconditions

- The `bootstrap` Application tracks a chart release containing this flag.
- The `kyverno` Application is `Synced`/`Healthy` — it owns the
  `policies.kyverno.io/v1` CRDs the policy depends on.

### Enable (Argo CD UI)

1. Open the Argo CD UI and select the **`bootstrap`** application
   (namespace `argocd`).
2. Open its **Parameters** panel (Helm parameters), or use
   **Edit → Application YAML** if your Argo CD version only exposes
   parameters read-only.
3. Add a Helm parameter:

   | Name | Value |
   |---|---|
   | `features.kyverno.requireImageDigest.enabled` | `true` |

   YAML-editor equivalent — merge into `spec.source.helm.valuesObject`:

   ```yaml
   features:
     kyverno:
       requireImageDigest:
         enabled: true
   ```

4. Save, then **Sync** the `bootstrap` application (auto-sync off means this
   click is required). The policy is `sync-wave: "4"`; a transient
   `no matches for kind "ValidatingPolicy"` on that one manifest is absorbed
   by its `SkipDryRunOnMissingResource=true` annotation.
5. Verify:

   ```bash
   kubectl get validatingpolicy require-image-digest
   kubectl get policyreport -A        # reports appear within one scan cycle
   ```

   Absence of the object before enabling (and after disabling) is the
   expected, correct state.

### Disable again

Remove the parameter, or set it back to `false`, then sync. Argo CD prunes
the `ValidatingPolicy`; existing `PolicyReport`s age out through
policy-reporter's retention.

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
  '[{"op":"add","path":"/spec/source/helm/parameters/-","value":{"name":"features.kyverno.requireImageDigest.enabled","value":"true"}}]'
```

### Caveats

- An Argo CD UI parameter is drift relative to the IaC that creates
  `Application/bootstrap` (Pulumi/SSM). A re-provisioning `pulumi up` may
  reconcile it away. Promote any lasting choice into the Pulumi/SSM
  bootstrap values if it should survive re-provisioning.
- Enabling this on a cluster whose platform images are tag-pinned will
  produce a large `PolicyReport` volume. That's expected — it's
  audit-only and purely informational.
