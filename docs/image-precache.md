# Image pre-cache list (`images.lock`)

`images.lock` is the generated list of every OCI reference these charts pull —
72 references at the time of writing. It exists so a cluster can be bootstrapped
against a mirror, a warmed ECR pull-through cache, or a registry allow-list
without discovering the images it needs one `ImagePullBackOff` at a time.

It is generated from the vendored charts, so it never needs a cluster:

```bash
./scripts/generate-images.sh > images.lock
```

`./scripts/check-images-lock.sh` (run by the `Images Lock` workflow) fails when
the two disagree, which is what happens on every Renovate chart bump.

## What it contains

For each chart, `helm template` is run the way ArgoCD runs it — with the values
the `Application` in `charts/bootstrap` passes — and unioned with a render from
chart defaults, so an image that only appears when a feature is enabled is still
on the list. Two things beyond plain `image:` fields are included:

- **Crossplane `package:` artifacts** (`ghcr.io/crossplane-contrib/provider-*`,
  `function-*`). Crossplane's package manager pulls these itself; they are not
  kubelet images, and leaving them out means every managed resource stays
  pending even though every pod is running.
- **The `oci://` Applications** (`common-bootstrap`, `crossplane-providers`,
  `crossplane-functions`), rendered at their pinned tags with the Application's
  values, since that is where the package registry override lives.

Helm `test` hooks are excluded — `bats` and `kubekins-e2e` only run under
`helm test`, which nothing here does.

## What it does not contain

- **Anything a CR creates at runtime.** A Crossplane composition that provisions
  a PostgreSQL cluster pulls `ghcr.io/cloudnative-pg/postgresql:<ver>`; the
  image name lives in the composition, which is not in this repo.
- **Workload images** from other repositories.
- **Per-cluster overrides** such as `features.shutdown.image`, which is included
  at its default only.

## The other half

K3s's own system images and the three charts that master userdata applies before
ArgoCD exists (cilium, argo-cd, crossplane) are the responsibility of
`loafoe/k3s-on-ec2`, which generates its own `images.lock`. Its
`docs/IMAGE_PRECACHE.md` has the union, the runtime-copy recipe, and the list of
non-image prerequisites (AMI, k3s binary, chart repos) that a pre-cached cluster
still needs on its first boot.
