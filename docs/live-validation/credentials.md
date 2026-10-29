## Credential Handling

This cluster (`dip-ce-k3s-eu`) is provisioned by the separate
[`k3s-on-ec2`](https://github.com/loafoe/k3s-on-ec2) Pulumi project, not by
this repository. A kubeconfig for it is never checked into either repo: the
one used to write this runbook lives only on the operator's machine, at a
path outside both repos, and is `.gitignore`d in `k3s-on-ec2` itself.

**Never commit, paste into an issue/PR/comment, or leave in a test fixture
in this repo**: a client certificate, private key, bearer token, or a full
kubeconfig for this or any cluster. A kubeconfig embedding a client
certificate/key is bearer credential material with no expiry — treat it the
same as a password.

### Obtaining your own credential

Run these from a checkout of `k3s-on-ec2`, not from here:

```bash
# static client-cert kubeconfig (cluster-admin-equivalent, no expiry —
# prefer the IAM path below where the cluster has IAM auth configured)
make kubeconfig STACK=dip-ce-k3s-eu

# short-lived, AWS-IAM-authenticated kubeconfig instead, where the
# aws-iam-authenticator integration described in k3s-on-ec2's README is
# deployed on the target cluster
make kubeconfig-iam STACK=dip-ce-k3s-eu
```

Both targets read the running Pulumi stack's outputs; they require AWS and
Pulumi credentials for that stack, not a copy of someone else's kubeconfig.
Prefer `make kubeconfig-iam` when available: it authenticates through
short-lived AWS IAM credentials rather than embedding a long-lived client
certificate.

Point `kubectl`/`KUBECONFIG` at whichever file that produces. Nothing in
this repository, in the agent host running live-validation checks, or in
any issue/PR should reference that file by path — only by the procedure
above.

### For an agent running the checks in this runbook

Supply the kubeconfig out-of-band: either an agent-host path outside any git
checkout, or a `KUBECONFIG` environment variable pointing at a mounted
secret. Confirm before finishing any live-validation work that no
credential material leaked into the repo:

```bash
# from a checkout of k8s-aws-bootstrap
grep -rIl --exclude-dir=.git --exclude=credentials.md -E \
  'BEGIN (RSA |EC )?PRIVATE KEY|client-certificate-data|client-key-data' .
# expect: no output. A hit on "BEGIN CERTIFICATE" alone (no matching key)
# is a public CA/leaf cert such as the SPIFFE federation bundle in
# charts/bootstrap/templates/spiffe/ — not credential material by itself.
```
