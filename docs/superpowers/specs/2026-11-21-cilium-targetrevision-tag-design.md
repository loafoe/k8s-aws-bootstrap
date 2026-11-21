# Pin wrapper-chart `targetRevision` to a minted tag instead of `HEAD` (cilium pilot)

**Date:** 2026-11-21
**Status:** Implemented and fully rolled out 2026-11-21 (PRs #370-#438). All 20 current `charts/*` Applications pinned off `HEAD` onto a tag shaped `<chart>-<upstreamVersion>-<wrapperVersion>` (e.g. `cilium-1.20.5-0.1.5`), or `<chart>-<wrapperVersion>` for a chart with more than one dependency. Neither workflow needs `RENOVATE_TOKEN` (dropped in #374). Two real bugs were caught and fixed after this was first "done": a final review caught the automated chain being unable to fire at all under `GITHUB_TOKEN` (#384); the user caught the tag format itself being wrong twice over (dependency-version-only silently misses wrapper-only fixes; wrapper-version-only is correct but unreadable) before landing on the combined shape (#420). See Outcome below.
**Author:** Project Architect & Planner

## Context

Every child `Application` the `bootstrap` chart renders currently sets
`spec.source.targetRevision: HEAD` (confirmed across all ~20 templates under
`charts/bootstrap/templates/`, e.g. `cilium/cilium-app.yaml:14`). Argo CD therefore always syncs
each app from whatever commit `main` happens to be at, with no per-app, immutable, auditable
pin — even though the chart already has exactly this pattern for apps sourced from genuinely
external repos (`crossplane-providers-aws-app.yaml` → `targetRevision: 0.0.44`,
`crossplane-functions-app.yaml` → `0.0.19`, and `common-bootstrap-app.yaml`'s
`crossplaneCompositions.targetRevision: v0.0.58`, all bumped by Renovate via a
`# renovate: datasource=... depName=...` comment, because the tag already exists in the
*external* repo before the bump PR merges).

The ask: when Renovate bumps `charts/cilium`'s vendored dependency (e.g. to `1.20.5`), mint a
tag `cilium-1.20.5` at the exact commit that bump landed on, and point the `cilium` Application's
`targetRevision` at that tag instead of `HEAD` — the same pattern as the crossplane/common-bootstrap
apps above, but for a dependency that lives inside this monorepo rather than in an external repo.

## Verification findings

- **Renovate PRs for `charts/cilium` are two commits before merge, one after.** Renovate opens
  the branch with a bump-only commit (`Chart.yaml`'s dependency `version:`); `.github/workflows/helm-deps.yaml`
  (triggered by the Renovate workflow run) pushes a second commit to the same branch with
  `Chart.lock` and the re-vendored `.tgz`. `scripts/check-chart-deps.sh` gates the PR red until
  that second commit lands.
- **Merge lands as a single, isolated, single-parent commit in practice.** Verified directly:
  `git show --no-patch --format="%H %P" 88cc0f2` → one parent; the commit message is
  `chore(deps): update helm release cilium to v1.20.5 (#359)` (GitHub's squash-merge title
  format) and `git show --stat` shows it touches only `charts/cilium/{Chart.yaml,Chart.lock,charts/*.tgz}`.
  This is what a squash merge produces — the Renovate commit and the helm-deps commit collapse
  into one.
- **But `main` also receives commits outside any PR.** `.github/workflows/helm-deps.yaml` also
  iterates `main` directly (not just open `renovate/*` branches) and pushes a re-vendor fixup
  commit straight to `main` when something was left out of sync — seen in history as `dc33399`
  ("re-vendor charts left out of sync by failed helm-deps runs") and `b2f98ce` ("reconcile stale
  wrapper chart versions"), neither of which has a `(#NNN)` suffix. Any tagging logic has to
  treat these the same as a merged PR's commit(s) — it cannot assume "one PR = one commit" or
  gate on PR metadata at all.
- **Rebase merge would not collapse the two commits.** GitHub's rebase-merge replays each
  original commit onto `main` with a new SHA (parent changed → SHA changes even for an identical
  diff). A rebase-merged cilium bump would therefore land as two separate commits on `main`: one
  where `Chart.yaml` says `1.20.5` but `Chart.lock`/the vendored `.tgz` still say `1.20.4`
  (transiently inconsistent), and one where they agree. Tagging the first of those would mint an
  immutable tag at a commit Argo CD cannot actually render correctly.
- **Confirmed (2026-11-21, follow-up session): `main` has no branch protection at all**
  (`gh api repos/loafoe/k8s-aws-bootstrap/branches/main/protection` → `404 Branch not protected`),
  and **all three merge methods are allowed** (`allow_squash_merge`, `allow_rebase_merge`,
  `allow_merge_commit` all `true`). Squash-only behaviour seen in history so far is habit, not an
  enforced constraint — nothing stops a merge-commit merge, and nothing stops a force-push or
  history rewrite on `main` by anyone with write access. This hardens two things that were
  previously "open questions" into confirmed, must-handle cases; see the revised detection logic
  below and the Forgejo-portability section.
- **Repointing `targetRevision` also touches rendered golden output.** `tests/render/golden/{k3s,k3s-dualstack}.yaml`
  include the full rendered `cilium` `Application` manifest, so any template edit to
  `cilium-app.yaml` must regenerate them via `scripts/check-bootstrap-render.sh --update`
  (`.github/workflows/bootstrap-render.yaml` already gates on this for any `charts/**` change —
  no new mechanism needed, just the existing one firing as designed).

## Decision

### Why pre-merge tagging (tag the Renovate branch itself) is rejected outright

Squash and rebase both mint a SHA on `main` that never existed on the Renovate branch. A tag cut
before merge either dangles (squash collapses it away) or points at the wrong object (rebase
replays it under a new SHA). The tag must be cut by inspecting `main` itself, strictly after
merge.

### Tagging workflow: tag-existence-driven, not before/after-driven

Revised during implementation planning (2026-11-21) to a simpler and more robust rule than the
original before/after walk: **evaluate current state, not a push's delta.** On `push: branches:
[main]` (after `actions/checkout` lands the workflow on `main`'s current tip), for each chart
directory under `charts/*/Chart.yaml` that declares a `dependencies:` block, reusing the
dependency-version-extraction logic already in `scripts/check-chart-deps.sh`'s `dump_deps()`:

1. Read the chart's current dependency version(s) from `Chart.yaml` at the current checkout.
2. Compute the tag name: `<chart>-<version>` (e.g. `cilium-1.20.5`), or
   `<chart>-<depName>-<version>` if the wrapper ever vendors more than one dependency (none do
   today).
3. **If that tag already exists, stop — no-op.** This is the entire idempotency rule, and it is
   also what makes the detection correct when a version bump and its vendoring fix land in *two
   separate pushes* rather than one (the real recovery path seen in history as `dc33399`/`b2f98ce`,
   where `helm-deps.yaml` re-vendors `main` directly outside any PR): the push that only bumps
   `Chart.yaml` does not yet pass the vendoring check below, so it mints nothing; the *later* push
   that fixes vendoring sees no `Chart.yaml` change of its own, but still finds the tag missing and
   mints it then. A before/after-walk scoped to each push's own commit range would miss this,
   because the version-changing commit and the vendoring-fix commit never share a single push's
   range.
4. If the tag does not exist, require `scripts/check-chart-deps.sh <dir>` to pass at the current
   checkout — i.e. the vendored `.tgz`/`Chart.lock` must actually agree with `Chart.yaml` — before
   tagging anything. If it does not pass yet, skip quietly; a later push (the vendoring fix) will
   retry this same check.
5. Tag the **most recent commit reachable from the current tip via `git log --first-parent -1 --
   <chart-dir>`** — i.e. the latest commit that touched that chart directory along `main`'s own
   lineage. `--first-parent` matters for the same reason noted below: a merge-commit merge (now
   confirmed allowed on this repo) must not have its absorbed side-branch commits mistaken for
   points `main` actually passed through; walking only first-parent history skips straight to the
   merge commit itself, the one state `main` really held.
6. A version string reappearing unchanged at a different, later commit (e.g. a deliberate
   rollback forward to a version that was already tagged once before) is **not** treated as a
   collision requiring special handling: the same upstream dependency version renders the same
   vendored chart content either way, so reusing the existing tag's target is correct, not stale.
   No SHA-mismatch check is needed as a result — this removes a failure mode the original
   before/after design would have had to handle explicitly.

This also means the detection script needs no event-derived input at all (no `before`/`after`
SHAs) — it only needs to run with the working tree checked out at `main`'s current tip, which is
what `actions/checkout` already does by default on a `push` trigger, and is equally true under
any CI system. One less GitHub-specific input than even the earlier revision had; see Forgejo
portability below.

This logic is chart-agnostic by construction — it is written once against `charts/*`, not
specifically against `cilium`.

### Adopting the tag: a second, separately reviewed PR — never a direct push

Once `cilium-1.20.5` exists, a small bot step (same `gh pr create` pattern `helm-deps.yaml`
already uses for its branch pushes, but with `pull-requests: write` instead of pushing to `main`)
opens a PR that changes `charts/bootstrap/templates/cilium/cilium-app.yaml`'s
`targetRevision: HEAD` → `targetRevision: cilium-1.20.5`. This PR runs through the existing
`chart-version-check` and `bootstrap-render` CI (which will fail red until the golden files are
regenerated, exactly as it already does for any Application-template edit), and a human merges
it — same as any other `targetRevision` bump today.

This is **not** auto-merged. `cilium`'s `syncPolicy` is `automated` + `selfHeal: true`
(`cilium-app.yaml:80-82`), so an unreviewed direct push would deploy to every cluster instantly.
Keeping this a normal PR preserves the manual-approval pattern already used for sensitive live
changes elsewhere (e.g. the fleet `HelmApplication` bumps in `[[fleet-release]]`-style manual
apply).

The loop then repeats: next bump → `1.20.6` lands on `main` → `cilium-1.20.6` minted → a new bot
PR repoints `targetRevision` from `cilium-1.20.5` to `cilium-1.20.6` → human merges. Structurally
identical to how `common-bootstrap`'s OCI `targetRevision` is bumped by Renovate today; the bot
step stands in for Renovate only because Renovate cannot target a tag that doesn't exist until
after our own merge.

### Forgejo portability: isolate the core from the glue

This repo is GitHub-only today (`[[repos-and-tagging]]`: k8s-aws-bootstrap tags push to `origin`
(GitHub) only), but k3s-on-ec2 already pushes tags to both GitHub and this user's Forgejo
instance, and workflow logic has moved between forges before in this environment. Confidence
that this survives a rewrite to Forgejo Actions depends entirely on where the forge-specific
surface area sits, so the design deliberately draws the line as follows:

**Portable core (plain git + bash, zero forge API calls, zero event-payload fields):**
- `scripts/mint-chart-tags.sh` — takes no event-derived input at all, not even `before`/`after`
  SHAs; it only reads the working tree at whatever commit is checked out. Internally it only runs
  `git log --first-parent`, `git tag -a`, `git push`, `git show-ref --tags`, and the existing
  `scripts/check-chart-deps.sh`. None of this is GitHub-specific; it runs unmodified under Forgejo
  Actions, under `act`, or from a developer's shell, triggered by nothing more forge-specific than
  "run this after a checkout of `main`'s tip." This is also why `github.event.commits[]` was
  rejected above in favour of tag-existence-driven detection — using the webhook payload's commit
  list, or even its `before`/`after` fields, would have smuggled a forge-specific assumption into
  logic that otherwise has none.
- The `check-chart-deps.sh` vendoring gate and the tag-existence idempotency rule are pure
  git/bash as well.

**Forge-specific glue (the only things a Forgejo rewrite actually touches):**
- The triggering YAML (`on: push: branches: [main]`) — syntax is already compatible; Forgejo
  Actions implements the same workflow schema. No change expected, but unverified against this
  user's specific Forgejo/Gitea Actions version.
- `actions/checkout`, `azure/setup-helm` — ordinary marketplace actions; Forgejo's `act_runner` can
  run most unmodified GitHub Actions, including `actions/checkout`. Expected to need no change
  beyond runner network access to fetch them (or a local mirror, if the Forgejo runner is
  air-gapped from github.com).
- **`gh pr create` / `gh api` — the one real rewrite.** The `gh` CLI only talks to GitHub; Forgejo
  has its own REST API (Gitea-compatible, not GitHub-compatible) and its own CLI (`tea`). The
  "open a PR with this diff" step is already scoped as a single, separate, thin wrapper around
  the portable core's output — it does not reach into the detection/tagging logic at all — so the
  rewrite cost is bounded to swapping that one call for `tea pr create` or a raw `curl` against
  `/api/v1/repos/{owner}/{repo}/pulls`, not touching `mint-chart-tags.sh`.
- The one-time human verification of branch-protection/merge-method settings (delivery plan #1)
  is a `gh api` call too, but it is not part of the shipped automation — it is a pre-flight check
  run once by a person, so it carries no ongoing portability cost.

**Confidence, stated plainly:** the detection/tagging logic itself (the part that has to be
*correct*, not just syntactically valid — the squash/rebase/merge-commit/direct-push/split-across-
pushes handling) is forge-agnostic by construction, takes no event-payload input at all, and does
not need to be re-reasoned about in a Forgejo rewrite. What would need re-verifying on a real
Forgejo instance before trusting it there: that `actions/checkout` behaves identically under
`act_runner`. What would need rewriting outright: the single PR-opening call. Nothing in this
design currently depends on a GitHub-only capability that has no Forgejo equivalent at all — the
gap is CLI/API surface, not missing functionality.

### Scope: generic mechanism, incremental rollout

The tagging workflow is written generically against `charts/*` (no extra cost to limit it to
cilium). The actual migration off `HEAD` — editing an `*-app.yaml` template — is rolled out one
Application at a time, independently reviewable. **Cilium first**, as asked.

## Options considered

| Option | Description | Verdict |
|---|---|---|
| **A. Tag post-merge, per-commit, gated on vendoring consistency; adopt via a second bot-opened PR** | Described above | **Chosen.** Correct under squash, rebase, and direct-to-`main` pushes alike; keeps the live-sync-affecting edit under human review |
| B. Tag + auto-repoint `targetRevision` in the same bot push, straight to `main` | Fully hands-off | Rejected — `cilium`'s `automated`/`selfHeal: true` sync policy means an unreviewed push deploys instantly, with no CI gate in the loop |
| C. Have Renovate tag the branch commit itself, pre-merge | Tag minted before merge | Rejected — squash/rebase both change the SHA that lands on `main`, so the tag dangles or points at the wrong commit |
| D. Tag at the push's final commit unconditionally, no vendoring check | Simpler detection | Rejected — on a rebase-merged PR this can tag the commit where `Chart.yaml` and the vendored artifacts disagree, minting a broken immutable tag |

## Delivery plan (not started)

| # | Task | Acceptance |
|---|---|---|
| 1 | ~~Confirm branch-protection / allowed merge methods~~ — **done 2026-11-21**: `main` has no branch protection (`404 Branch not protected`); `allow_squash_merge`/`allow_rebase_merge`/`allow_merge_commit` are all `true`. Decide: disable merge-commit at the repo settings level, or rely on the `--first-parent` handling in the Decision section | Either the repo setting changes, or a written decision to rely on `--first-parent` instead, with the reasoning recorded here |
| 2 | `scripts/mint-chart-tags.sh` — the tag-existence-driven, vendoring-gated detection logic from the Decision section, built on `check-chart-deps.sh`'s version-extraction helpers. Takes no event-derived input, only the current checkout, so it is directly runnable under Forgejo Actions or a shell later | Run against the real history (checking out `a7c580e`, `badec6c`, `88cc0f2` in turn) produces exactly `cilium-1.20.4`, `cilium-1.20.3`, `cilium-1.20.5` at those SHAs, nothing else |
| 3 | `.github/workflows/mint-chart-tags.yaml` on `push: [main]`, checking out `main`, calling the script, pushing any new tags | Re-running on an unchanged tip creates nothing (every tag already exists) |
| 4 | `.github/workflows/bump-app-tag.yaml` (or extend the above) — on a new tag matching `cilium-*`, open a PR editing `cilium-app.yaml`'s `targetRevision` via `gh pr create` (the one forge-coupled call, kept as a thin wrapper separate from step 2's script), running `scripts/check-bootstrap-render.sh --update` for the golden files in the same commit | PR is green on `chart-version-check` + `bootstrap-render`, diff is exactly the `targetRevision` line plus regenerated goldens |
| 5 | Merge that first PR by hand, migrating `cilium` off `HEAD` | `cilium` Application's `targetRevision` in Argo CD shows `cilium-1.20.5` (or whatever the latest tag is by then), not `HEAD` |
| 6 | Decide and document whether any other wrapper chart gets migrated next, or whether cilium stays the only pilot for now | Written decision, not a silent default |

## Assumptions & open questions

- **Resolved:** squash was habit, not an enforced constraint — confirmed no branch protection and
  all three merge methods allowed. Handled in the Decision section by evaluating current state
  (tag-existence-driven, `git log --first-parent -1 -- <dir>`) instead of trusting
  `github.event.commits[]` or even `before`/`after`, so a merge-commit merge no longer needs the
  repo setting changed to be handled correctly — though disabling it is still the simpler option
  if there's no reason to keep it available.
- **Open, specific to today's question:** `actions/checkout`'s behaviour under Forgejo's
  `act_runner` is expected to be unchanged, but not verified against this user's actual Forgejo
  instance. First step of any real rewrite: confirm a plain `actions/checkout@vN` step works on a
  Forgejo-Actions-enabled test repo before porting `mint-chart-tags.sh` over — low risk, since the
  script itself takes no event-derived input to begin with.
- **Assumed:** cilium is a representative pilot — every wrapper chart under `charts/*` vendors
  exactly one dependency today, so the `<chart>-<version>` tag name stays unambiguous without the
  `<depName>` fallback actually being exercised yet.
- **Open:** whether the second ("adopt the tag") PR should eventually be allowed to auto-merge for
  apps that are low-risk enough, once the pattern has proven itself on cilium. Deliberately left
  as manual-merge-only in this design.

## Outcome (2026-11-21)

Real rollout surfaced three things this design didn't anticipate, all fixed in follow-up PRs:

- **`git tag -a`/`git commit` in CI need an explicit identity** (`actions/checkout` doesn't set
  one). Fixed in #371 by configuring `github-actions[bot]` before either script runs.
- **Pushing any ref (tag or branch) to a commit whose `.github/workflows/**` content differs from
  the current default branch requires more than `contents: write`** under the default
  `GITHUB_TOKEN` — hit immediately by `argocd`'s tag, whose target commit predates later edits to
  `bootstrap-render.yaml`. This is a one-time backfill problem, not a recurring one: a *future*
  push's own commit always matches main's current workflow files, so it cannot recur once the
  repo's chart history is caught up. After two wrong turns (an invalid `workflows:` permissions
  key, which GitHub silently rejects the whole workflow file for — zero jobs scheduled, not a job
  failure; then widening scope via `RENOVATE_TOKEN`, which the user rejected — no workflow should
  need a shared secret's broader scope just to cover a one-time historical edge case), the actual
  fix was to **not** solve it in CI at all: `set -e` was also wrapping the tag/push in a way that let one chart's
  failure abort every chart sorted after it alphabetically (including `cilium` itself, sorted
  after `argocd`) — fixed by isolating each chart's tag+push so one failure can't block the rest
  — and the remaining old-history backfill was pushed directly with repo-owner `gh`/git
  credentials from outside CI, a one-time operation, not a workflow concern.
- **Correction (superseded by the finding below): the "old commits don't fire push:tags:"
  explanation first written here was wrong.** Three probe tags at the current tip fired a
  `bump-app-tag.yaml` run instantly, while 11 backfilled historical tags fired none, and that
  pattern looked at the time like it was about commit age. A follow-up, more targeted probe
  (a disposable temporary workflow pushing a tag at a brand-new commit, using the same
  `GITHUB_TOKEN`-backed credentials `mint-chart-tags.yaml` itself uses) proved otherwise: that
  tag, at a fresh commit, *also* did not fire `bump-app-tag.yaml`. **The real cause is GitHub's
  documented anti-recursion rule — a ref pushed using the default `GITHUB_TOKEN` does not start
  new workflow runs at all**, regardless of how old or new the target commit is. This is not a
  one-time backfill quirk; it meant the automated chain could never have worked for any real
  future chart bump either, since `mint-chart-tags.yaml`'s own tag pushes use that same token.
  Caught by a fresh-context final review before it shipped silently broken.
  **Fix:** `mint-chart-tags.sh` now calls `bump-app-tag.sh` directly, in-process, once its own
  tagging loop is fully done (not mid-loop — `bump-app-tag.sh` switches branches, which would
  corrupt the loop's own `git log --first-parent` results for every chart evaluated after it).
  `bump-app-tag.yaml`'s own `push: tags:` trigger is left in place and still fires normally for a
  human manually pushing a tag with personal credentials — confirmed by the same probe process.

Net effect: the design's core detection/tagging logic held up on real history on the first try
(including the untested multi-dependency fallback for `cloudnative-pg`, and the targetRevision
PR's expected file bundle), but the cross-workflow trigger the two-workflow architecture depended
on turned out not to exist under `GITHUB_TOKEN` at all — the single most important thing the
final review caught. The fix collapses to one workflow doing both steps per chart, which is also
simpler than the two-workflow handoff this design originally specified.

**Full rollout (2026-11-21):** after the fix above, all 20 current `charts/*` Applications were
migrated off `HEAD` in one session (cilium was the pilot; the other 19 followed once the user
asked to pin everything rather than wait for each chart's next natural bump). `bump-app-tag.sh`
also picked up two more fixes found while rolling out the remaining charts: it now resolves a
tag's chart name against the real `charts/*` directory list (longest-prefix match) instead of a
shape-guessing regex, so both the two-dependency case (`cloudnative-pg-cloudnative-pg-0.29.2`) and
an otherwise-ambiguous case (`spire-crds-0.6.1` vs. chart `spire`) resolve correctly; and it
allows a leading `v` in the version portion (`cert-manager-v1.21.3`), matching the `v?` handling
`check-chart-version-bump.sh` already does elsewhere.

**The tag format went through three iterations in one session, caught by two different
reviewers:**

1. `<chart>-<dependencyVersion>` (the original design, e.g. `cilium-1.20.5`) — rolled out first.
   A fresh-context final review caught **Critical #2**: tagging by the vendored dependency's
   version means a hand-authored wrapper-only fix (`values.yaml`/templates, no dependency bump)
   never mints a new tag, so once an Application is pinned, that kind of fix would silently
   never deploy — a real regression from `HEAD`-tracking's always-current behaviour. This is not
   a hypothetical: 6 of the 12 commits preceding this work to `charts/cilium` alone were exactly
   that shape of fix.
2. `<chart>-<wrapperVersion>` (e.g. `cilium-0.1.5`) — the fix for (1), since
   `bump-chart-version.sh` bumps the wrapper's own version on every change, dependency bump or
   hand-authored fix alike. Correct, and rolled out to all 20 charts. The user caught the real
   problem with *this* shape immediately on seeing it live: the tag is opaque bookkeeping, and
   `targetRevision` in the Argo CD UI no longer shows which upstream version is actually running
   — a legitimate operational regression of its own, just a different one than (1)'s.
3. `<chart>-<dependencyVersion>-<wrapperVersion>` (e.g. `cilium-1.20.5-0.1.5`) — combines both:
   readable upstream version leads, wrapper version suffix means neither (1)'s nor (2)'s problem
   recurs. Falls back to `<chart>-<wrapperVersion>` alone for a chart with zero or more than one
   dependency (no single upstream version to lead with — `cloudnative-pg` today).

Each iteration required re-tagging and re-opening the targetRevision PR for every already-pinned
chart, which is exactly the cost the per-app `targetRevision` pin is supposed to make cheap and
safe to pay: every re-tag pointed at the *same* commit as before, so every repoint PR's diff was
a one-line `targetRevision` change plus the bootstrap chart's own version bump and golden-file
regen — reviewable, revertible, and never a surprise to Argo CD (the rendered manifest never
changed, only the pin's bookkeeping did).

**Other real-world findings from the full rollout, not caught until actually running it live:**
- The repo had "Allow GitHub Actions to create and approve pull requests" disabled, so even
  after fixing the `GITHUB_TOKEN` anti-recursion issue, `gh pr create` from inside a CI job
  failed outright with `GraphQL: GitHub Actions is not permitted to create or approve pull
  requests`. This is a one-click repo setting (Settings → Actions → General → Workflow
  permissions), not something fixable in script code; the user enabled it directly.
- Historical tags whose target commit predates a recent `.github/workflows/**` edit on the
  default branch still can't be pushed under the default token (the same restriction found
  earlier), and this recurs every time a new workflow-file-touching commit lands — not a
  one-off. Resolved the same way each time: push the stragglers directly with repo-owner
  credentials, outside CI, since it only ever affects a one-time backfill, never a real future
  bump (whose own commit always matches main's current workflow files).
