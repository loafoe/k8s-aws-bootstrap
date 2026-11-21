# Cilium Tag Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mint an immutable `cilium-X.Y.Z` tag the moment that version lands on `main`, then repoint the `cilium` Argo CD Application's `targetRevision` at it instead of `HEAD`, via a second bot-opened, human-merged PR.

**Architecture:** Two small, independent, forge-agnostic bash scripts, each wrapped in its own thin GitHub Actions workflow. `scripts/mint-chart-tags.sh` runs on every push to `main`, is tag-existence-driven (no event-payload input), and mints `<chart>-<version>` tags for any `charts/*` wrapper chart whose vendored dependency isn't tagged yet. `scripts/bump-app-tag.sh` runs on every new tag push, finds the Application template that sources that chart directory, and opens a PR repointing its `targetRevision`.

**Tech Stack:** bash, git, `gh` CLI, existing repo scripts (`check-chart-deps.sh`, `bump-chart-version.sh`, `check-bootstrap-render.sh`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-21-cilium-targetrevision-tag-design.md`

## Global Constraints

- Tags are annotated (`git tag -a`), matching this repo's existing tag convention (`[[repos-and-tagging]]`).
- Detection logic must take **no event-payload input** (no `before`/`after`, no `commits[]`) — only the current checkout — per the design's Forgejo-portability requirement.
- The `targetRevision` repoint is **never a direct push to `main`** — always a PR, because `cilium`'s `syncPolicy.automated.selfHeal` is `true`.
- Any edit to a `charts/bootstrap/templates/**` file must bump `charts/bootstrap/Chart.yaml`'s own `version:` in the same commit (enforced by `scripts/check-chart-version-bump.sh` in CI) and must regenerate `tests/render/golden/{k3s,k3s-dualstack}.yaml` via `scripts/check-bootstrap-render.sh --update` (enforced by `.github/workflows/bootstrap-render.yaml`).
- Reuse the existing `dump_deps()` awk pattern from `scripts/check-chart-deps.sh` for parsing a chart's `dependencies:` block rather than inventing new parsing.
- Scope to `charts/*` generically (chart-agnostic), but only migrate the `cilium` Application's template off `HEAD` in this plan — no other Application templates change.

## Review Focus

- A wrapper chart with **no** `dependencies:` block at all (e.g. a future chart that isn't a thin wrapper) must be silently skipped by `mint-chart-tags.sh`, not error.
- A tag name collision with something that **isn't** a chart-version tag (e.g. a hand-made `v0.46.0` release tag) must not be touched or mistaken for a chart tag by `bump-app-tag.sh`'s tag-push trigger — only tags matching `<existing-chart-dir>-<semver>` should proceed.
- Running `mint-chart-tags.sh` twice against an unchanged tip must be a true no-op (no duplicate tag attempts, no error) — this is the whole idempotency story, so it needs an explicit check, not just an assumption.
- The `bump-app-tag.sh` PR must bundle the `targetRevision` edit, the `bootstrap` chart's own version bump, and the regenerated golden files **in one commit** — a PR missing any one of those three fails CI, so the acceptance test must assert all three are present.
- `check-chart-deps.sh "$dir"` failing (chart not fully vendored yet) must make `mint-chart-tags.sh` skip that chart **quietly** (exit 0 overall) rather than failing the whole workflow run — a transient vendoring gap on one chart must not block tagging for every other chart in the same run.

---

### Task 1: `scripts/mint-chart-tags.sh`

**Files:**
- Create: `scripts/mint-chart-tags.sh`
- Test: manual, via `--dry-run` against real history (no automated test framework for scripts exists in this repo — `check-chart-deps.sh`/`check-chart-version-bump.sh` are themselves the tests, run directly)

**Interfaces:**
- Consumes: `scripts/check-chart-deps.sh <dir>` (exit code only), the `dump_deps()` awk body from `scripts/check-chart-deps.sh:20-30` (copy it in, matching this repo's existing convention of each script owning its own awk helpers rather than sharing a lib).
- Produces: annotated git tags named `<chart>-<version>` (or `<chart>-<depName>-<version>` when a chart has more than one dependency), pushed to `origin`. Later tasks (3/4) trigger off these tags by name pattern.

- [ ] **Step 1: Write the script**

`#!/usr/bin/env bash` / `set -euo pipefail`, `cd` to `git rev-parse --show-toplevel`, like the existing scripts. Accept one optional flag: `--dry-run` (print what would be tagged; skip `git tag`/`git push`).

For each `charts/*/Chart.yaml`:
1. `dir=$(dirname "$chart")`; `chart_name=$(basename "$dir")`.
2. Skip (continue) if `grep -q '^dependencies:' "$chart"` fails — nothing to tag.
3. Run `dump_deps "$chart"` to get `name<TAB>version` pairs; count them into `dep_count`.
4. For each pair: `tag="${chart_name}-${version}"` if `dep_count -eq 1`, else `tag="${chart_name}-${name}-${version}"`.
5. `git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1` — if it succeeds, the tag exists: print `"  ${tag}: already exists, skipping"` and continue (this is the entire idempotency rule).
6. If `! ./scripts/check-chart-deps.sh "$dir" >/dev/null 2>&1`: print `"  ${dir}: not fully vendored yet, skipping"` and continue — **do not** treat this as a failure of the overall run (no `exit 1`, no `set -e` trip here — wrap the check in an `if`, not bare).
7. `sha=$(git log --first-parent -1 --format=%H -- "$dir")`.
8. If `--dry-run`: print `"  would tag ${tag} at ${sha}"` and continue.
9. Else: `git tag -a "$tag" -m "${chart_name} ${version}" "$sha"` then `git push origin "$tag"`.

End with a summary line (`"Minted N tag(s)."` or `"No new tags."`) — matches the style of `check-chart-deps.sh`'s final echo.

- [ ] **Step 2: Make it executable**

`chmod +x scripts/mint-chart-tags.sh`

- [ ] **Step 3: Test against real history using disposable worktrees**

For each of these three known-good commits, confirm the script identifies exactly the right tag without mutating the real working tree:

```bash
for pair in "a7c580e:cilium-1.20.4" "badec6c:cilium-1.20.3" "88cc0f2:cilium-1.20.5"; do
  sha="${pair%%:*}"; want="${pair##*:}"
  git worktree add --detach /tmp/mint-test "$sha" >/dev/null
  out=$(cd /tmp/mint-test && /path/to/repo/scripts/mint-chart-tags.sh --dry-run)
  git worktree remove /tmp/mint-test --force
  echo "$sha -> $out" | grep -q "would tag $want" && echo "OK: $want" || echo "FAIL: $want"
done
```

Expected: `OK: cilium-1.20.4`, `OK: cilium-1.20.3`, `OK: cilium-1.20.5` — nothing else printed as "would tag" for any other chart dir at those commits.

- [ ] **Step 4: Test idempotency — run `--dry-run` twice against current `main` tip**

```bash
./scripts/mint-chart-tags.sh --dry-run
./scripts/mint-chart-tags.sh --dry-run
```

Expected: identical output both times; any chart whose current tag already exists upstream prints "already exists, skipping" (there won't be any yet, since no tags exist — both runs should instead print identical "would tag" lines for every current `charts/*` dependency version, proving the run is deterministic and side-effect-free).

- [ ] **Step 5: Commit**

```bash
git add scripts/mint-chart-tags.sh
git commit -m "feat: add script to mint per-chart version tags on main"
```

---

### Task 2: `.github/workflows/mint-chart-tags.yaml`

**Files:**
- Create: `.github/workflows/mint-chart-tags.yaml`

**Interfaces:**
- Consumes: `scripts/mint-chart-tags.sh` (Task 1), run with no flags (real, non-dry-run).
- Produces: pushed git tags on `origin`, which Task 4's workflow triggers on.

- [ ] **Step 1: Write the workflow**

```yaml
name: Mint Chart Tags

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  mint-tags:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Mint any missing chart version tags
        run: ./scripts/mint-chart-tags.sh
```

`fetch-depth: 0` is required: `git log --first-parent -1 -- <dir>` and `check-chart-deps.sh`'s `helm dependency list` both need full history / full working tree, not the default shallow single-commit checkout.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/mint-chart-tags.yaml
git commit -m "ci: mint per-chart version tags on every push to main"
```

- [ ] **Step 3: Push the branch and open a PR; verify in CI, not locally**

This workflow can't be meaningfully tested without actually running on GitHub (it needs `contents: write` and a real push). Open the PR for Tasks 1+2 together, confirm the `Mint Chart Tags` check appears and succeeds (it runs on the PR's own push-to-main *after merge*, not on the PR itself — note in the PR description that the real verification is "tags appear after this merges", so a follow-up look at `git ls-remote --tags origin` after merge is the acceptance check, not a CI gate on the PR).

---

### Task 3: `scripts/bump-app-tag.sh`

**Files:**
- Create: `scripts/bump-app-tag.sh`

**Interfaces:**
- Consumes: `scripts/bump-chart-version.sh <dir>` (Task existing), `scripts/check-bootstrap-render.sh --update` (existing), `gh pr create` (GitHub CLI, assumed authenticated via `GH_TOKEN` env in CI).
- Produces: a branch + pushed commit + opened PR. Later task (4) invokes this script from a workflow.

**Usage:** `./scripts/bump-app-tag.sh <tag>` where `<tag>` is e.g. `cilium-1.20.5`.

- [ ] **Step 1: Write the script**

`#!/usr/bin/env bash` / `set -euo pipefail`, `cd` to repo root.

1. `tag="$1"` (error + `exit 2` if no argument).
2. Parse `chart` and `version` out of `tag` by matching the trailing semver: `[[ "$tag" =~ ^(.+)-([0-9]+\.[0-9]+\.[0-9]+)$ ]]`; `chart="${BASH_REMATCH[1]}"`, `version="${BASH_REMATCH[2]}"`. If the regex doesn't match, or `charts/$chart/Chart.yaml` doesn't exist, print `"not a chart tag, ignoring: $tag"` and `exit 0` (not an error — tags like a future hand-made release tag must not break this).
3. Find the Application template that sources this chart: `app_file=$(grep -rlE "path: charts/${chart}\$" charts/bootstrap/templates/)`. If zero or more-than-one match, print an error and `exit 1` (ambiguous or missing is a real failure here, not a skip — unlike step 2's "not a chart tag" case, this chart dir legitimately exists and should have exactly one Application).
4. Read the current `targetRevision` value from `$app_file` (same single-line-match style as `version_of()` in `check-chart-version-bump.sh`, matching `targetRevision:` instead of `version:`). If it already equals `$tag`, print `"already pinned to $tag"` and `exit 0`.
5. Create branch `bump-app-tag/${tag}`, checked out from `origin/main`.
6. Edit `$app_file` in place: replace the `targetRevision:` line's value with `$tag` (sed/awk, single-line substitution — same anchored style as `bump-chart-version.sh`'s version-line rewrite).
7. `./scripts/bump-chart-version.sh charts/bootstrap` (the template edit is a `templates/*` change to the `bootstrap` chart, which `check-chart-version-bump.sh` requires a version bump for).
8. `./scripts/check-bootstrap-render.sh --update` (regenerate the golden files so CI is green).
9. `git add -A`, commit as `chore(bootstrap): pin ${chart} to ${tag}`, push the branch.
10. `gh pr create --title "chore(bootstrap): pin ${chart} to ${tag}" --body "..." --base main --head "bump-app-tag/${tag}"`.

- [ ] **Step 2: Make it executable**

`chmod +x scripts/bump-app-tag.sh`

- [ ] **Step 3: Dry-run test against the real repo state, without pushing**

```bash
./scripts/bump-app-tag.sh not-a-real-chart-1.2.3
```

Expected: prints `"not a chart tag, ignoring: not-a-real-chart-1.2.3"`, exits 0, no branch created (`git status` clean, `git branch` unchanged).

```bash
./scripts/bump-app-tag.sh cilium-1.20.5
```

Run this in a scratch clone (not the real working copy, since it pushes a branch and opens a real PR) — e.g. `git clone . /tmp/bump-test && cd /tmp/bump-test`. Expected: a branch `bump-app-tag/cilium-1.20.5` is pushed (to the scratch clone's own remote, or skip the final `gh pr create`/push for this manual test and inspect the local commit instead) whose diff touches exactly three things: `charts/bootstrap/templates/cilium/cilium-app.yaml`'s `targetRevision` line, `charts/bootstrap/Chart.yaml`'s `version:` line, and `tests/render/golden/{k3s,k3s-dualstack}.yaml`. Confirm with `git show --stat HEAD`.

- [ ] **Step 4: Commit**

```bash
git add scripts/bump-app-tag.sh
git commit -m "feat: add script to open a PR repointing an app's targetRevision at a new chart tag"
```

---

### Task 4: `.github/workflows/bump-app-tag.yaml`

**Files:**
- Create: `.github/workflows/bump-app-tag.yaml`

**Interfaces:**
- Consumes: `scripts/bump-app-tag.sh <tag>` (Task 3).
- Produces: nothing further downstream — this is the end of the automated chain; a human merges the PR it opens.

- [ ] **Step 1: Write the workflow**

```yaml
name: Bump App Tag

on:
  push:
    tags:
      - '*'
  workflow_dispatch:
    inputs:
      tag:
        required: true

jobs:
  bump-app-tag:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Open PR repointing targetRevision
        env:
          GH_TOKEN: ${{ secrets.RENOVATE_TOKEN }}
        run: ./scripts/bump-app-tag.sh "${{ github.event.inputs.tag || github.ref_name }}"
```

`tags: ['*']` fires on every tag push, including unrelated ones (e.g. a hand-made `v0.46.0` release tag) — this is intentional and safe, because `bump-app-tag.sh` step 2 (Task 3) already exits 0 quietly for anything that doesn't parse as `<existing-chart-dir>-<semver>`. `RENOVATE_TOKEN` is reused (already has `contents: write`/`pull-requests: write` per `.github/workflows/renovate.yaml`) rather than introducing a new secret.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/bump-app-tag.yaml
git commit -m "ci: open a PR repointing an app's targetRevision whenever a chart tag is pushed"
```

- [ ] **Step 3: Push the branch and open the combined PR for Tasks 1-4**

One PR covering `scripts/mint-chart-tags.sh`, `scripts/bump-app-tag.sh`, and both workflows — they are only meaningfully testable together (Task 2's workflow is what produces the tag Task 4's workflow reacts to). Confirm `chart-version-check` and `bootstrap-render` CI pass on the PR itself (neither script nor workflow touches `charts/**` directly, so both should be green with no changes needed).

---

### Task 5: Rollout — verify the chain end-to-end and migrate `cilium` off `HEAD`

**Files:**
- Modify: none directly — this task observes and merges automation output, per the design's "never a direct push" rule.

**Interfaces:**
- Consumes: the merged state of Tasks 1-4 on `main`.
- Produces: `charts/bootstrap/templates/cilium/cilium-app.yaml`'s `targetRevision` set to `cilium-1.20.5` (or whatever the latest tag is by the time this runs), merged via the automatically-opened PR — the first real proof the whole chain works.

- [ ] **Step 1: Merge the Tasks 1-4 PR to `main`**

- [ ] **Step 2: Watch the `Mint Chart Tags` workflow run on that merge push**

```bash
gh run list --workflow=mint-chart-tags.yaml --limit 1
```

Expected: succeeds, and `git ls-remote --tags origin | grep cilium` shows `cilium-1.20.5` pointing at the SHA of `git log --first-parent -1 --format=%H -- charts/cilium` (which should be `88cc0f2`, per the real history found during design).

- [ ] **Step 3: Watch the `Bump App Tag` workflow fire on that tag push**

```bash
gh run list --workflow=bump-app-tag.yaml --limit 1
gh pr list --search "bump-app-tag/cilium-1.20.5"
```

Expected: a PR titled `chore(bootstrap): pin cilium to cilium-1.20.5` exists, with `chart-version-check` and `bootstrap-render` both green.

- [ ] **Step 4: Review and merge that PR by hand**

Confirm the diff is exactly: `cilium-app.yaml`'s `targetRevision: HEAD` → `targetRevision: cilium-1.20.5`, `charts/bootstrap/Chart.yaml`'s version bump, and the regenerated golden files — nothing else.

- [ ] **Step 5: Verify in Argo CD**

```bash
kubectl -n argocd get application cilium -o jsonpath='{.spec.source.targetRevision}{"\n"}'
```

Expected output: `cilium-1.20.5`, not `HEAD`. Confirm the Application's sync status stays `Synced` (the rendered manifest content is unchanged, since the tag points at the exact commit `HEAD` already resolved to).

- [ ] **Step 6: Record the outcome**

Update `docs/superpowers/specs/2026-11-21-cilium-targetrevision-tag-design.md`'s Status line from "Proposed — not yet implemented" to "Implemented 2026-11-21" (or the actual date), and update the `[[cilium-tag-pinning]]` memory file to match.
