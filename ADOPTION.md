# Release Strategy v6 — Adoption Guide

A complete release strategy for deploying any application via GitHub Actions, featuring:

- **3 workflows** consolidating the entire release lifecycle (vs many separate ones)
- **Plain semver tags** — minimal git tag pollution (~30/year vs hundreds)
- **GitHub Deployments API** for environment state tracking + auto-changelog
- **Issue-based approval** (`/approve`) — no paid GitHub Environments required
- **Real user traceability** in chain dispatches (no `github-actions` bot in run-names)
- **Manual prod-build trigger** — engineer-controlled "lock" point for releases
- **Rollback workflow** with image reuse + Release annotations

This guide walks you through adopting the strategy in your own repo.

---

## Table of contents

1. [What you're getting](#what-youre-getting)
2. [Architecture](#architecture)
3. [Tag strategy](#tag-strategy)
4. [Sprint flow](#sprint-flow)
5. [Files to copy](#files-to-copy)
6. [Customization checklist](#customization-checklist)
7. [GitHub repo settings](#github-repo-settings)
8. [Validation drill](#validation-drill)
9. [Migrating from existing workflows](#migrating-from-existing-workflows)
10. [Troubleshooting](#troubleshooting)
11. [FAQ](#faq)

---

## What you're getting

### 3 workflow files

| File | Trigger | Purpose |
|---|---|---|
| `prepare-branch.yml` | `workflow_dispatch` | Bootstrap `hotfix/` or `release/` branch from latest GA tag |
| `release.yml` | `workflow_dispatch` + `repository_dispatch` | 5-target deploy: dev / stg / prod-build / prod-deploy / rollback |
| `on-approve.yml` | `issue_comment` | Handle `/approve` and `/reject` on prod approval issues |

### 1 config file

| File | Purpose |
|---|---|
| `approvers.yml` | Production approvers list (single source of truth for `/approve` gate + rollback authorization) |

### Engineer mental model

> "Mau kirim kode ke env mana?"

| Scenario | Entry point |
|---|---|
| Test di dev | Actions → **Release** → `target=dev` |
| Regular release | `target=stg` → (day 11) `target=prod-build` → `/approve` di issue |
| Hotfix | **Prepare Branch** → push fix → `target=stg from=hotfix/...` → `target=prod-build` → `/approve` |
| Cherry-pick release | **Prepare Branch** → cherry-pick → `target=stg from=release/...` → `target=prod-build` → `/approve` |
| Rollback prod | `target=rollback from=<previous-GA>` |

---

## Architecture

```
Engineer dispatch
       │
       ▼
┌──────────────────┐
│ prepare-branch   │  (optional, only for hotfix/cherrypick)
│ → hotfix/vX.Y.Z  │
│ → release/vX.Y.Z │
└────────┬─────────┘
         │
         ▼
┌──────────────────────────────────────────┐
│ release.yml (workflow_dispatch)          │
│                                          │
│  target=dev  → build + deploy dev        │
│  target=stg  → build + deploy stg + RC   │
│  target=prod-build → build prod + issue  │
│  target=rollback → reuse image + deploy  │
└────────┬─────────────────────────────────┘
         │ (manual)         (chain via /approve)
         │                       ▲
         │                       │
         │       ┌───────────────┴──────┐
         │       │ on-approve.yml       │
         │       │ /approve → dispatch  │
         │       └───────────────┬──────┘
         │                       │
         ▼                       ▼
   ┌─────────────────────────────────────┐
   │ release.yml target=prod-deploy      │
   │  (workflow_dispatch OR              │
   │   repository_dispatch from chain)   │
   │                                     │
   │  → retag image                      │
   │  → helm upgrade                     │
   │  → create GA tag                    │
   │  → publish GitHub Release           │
   │  → close approval issue             │
   └─────────────────────────────────────┘
```

---

## Tag strategy

Plain semver, no suffix on GA. Total **2 permanent git tags per release cycle**.

| Stage | Git tag | Image tag | GitHub Deployment | GitHub Release |
|---|---|---|---|---|
| Dev | — | `dev-<sha7>-<arch>` | env=development | — |
| Stg (RC) | `vX.Y.Z-rc` (rolling) | `vX.Y.Z-rc-<arch>` | env=staging | — |
| Prod-build | — (reuse RC tag) | `vX.Y.Z-prod-<arch>` | — | — |
| Prod-deploy (GA) | `vX.Y.Z` (annotated, permanent) | `vX.Y.Z-<arch>` | env=production | ✅ Published |
| Rollback | — | (reuse existing) | env=production (old SHA) | _(annotated)_ |

**Examples:**

```
v0.0.3-rc      ← rolling, force-pushed during stg iterations
v0.0.3         ← annotated GA, permanent
v0.0.4         ← hotfix GA
v0.1.0         ← cherry-pick GA
```

**After 6 months** (~20 cycles + 10 hotfixes): ~60 tags total. Clean.

---

## Sprint flow

Generic 10-day sprint mapping. Adjust to your team rhythm.

```
Day 0-7   Development time
─────────────────────────────────────────────
  Engineer dispatch dev N times:
    target=dev from=main
      → build dev image
      → deploy dev cluster
      → GitHub Deployment record (env=development)
      → changelog auto-generated since last dev deploy

  No git tag, no issue.


Day 8     Stg cut — all features go to stg
─────────────────────────────────────────────
  target=stg from=main
    → compute version (latest_GA + bump)
    → create RC tag vX.Y.Z-rc (lightweight, rolling)
    → build stg image
    → deploy stg cluster
    → GitHub Deployment record (env=staging)


Day 8-10  QA feedback iterations
─────────────────────────────────────────────
  Bug → fix on main → re-cut stg
    target=stg from=main (same dispatch)
      → vX.Y.Z-rc force-push to new commit
      → rebuild + redeploy stg


Day 11    QA sign-off → "lock" the release
─────────────────────────────────────────────
  target=prod-build from=vX.Y.Z-rc
    → build prod image (different vault values from stg)
    → open issue "Awaiting approval: vX.Y.Z → production"
    → body includes changelog since last prod deploy

  RC tag pointer must NOT change after this.


Day 12    Approver /approve → deploy
─────────────────────────────────────────────
  Approver comments /approve on issue
    → on-approve.yml dispatches via repository_dispatch
    → release.yml target=prod-deploy (chain)
      → retag prod image to GA image
      → helm upgrade prod
      → create GA tag vX.Y.Z (annotated)
      → publish GitHub Release with changelog
      → close approval issue

  If bug found → target=rollback from=<previous-GA>
    → reuse old image + helm upgrade
    → annotate Releases (current = rolled-back, target = re-activated)
```

---

## Files to copy

### 1. `.github/workflows/prepare-branch.yml`

Source: copy from this demo repo. **No customization needed** — purely git operations.

### 2. `.github/workflows/release.yml`

Source: copy from this demo repo. **Heavy customization needed** — replace simulated build/deploy with your actual infrastructure code.

### 3. `.github/workflows/on-approve.yml`

Source: copy from this demo repo. **No customization needed** unless you want to change approval label name.

### 4. `.github/approvers.yml`

Create new with your team's GitHub logins.

```yaml
# .github/approvers.yml
production:
  - alice
  - bob
  - tech-lead-username
```

---

## Customization checklist

The demo `release.yml` simulates build/deploy with `echo + sleep`. For real adoption, replace these jobs with your actual infrastructure code.

### Required customizations

#### Job: `build` (line ~466)

Replace simulation with your real build steps. Common pattern:

```yaml
build:
  name: "Build · ${{ needs.setup.outputs.image_tag }}"
  needs: setup
  if: contains(fromJSON('["dev","stg","prod-build"]'), needs.setup.outputs.target)
  runs-on: <YOUR-RUNNER>
  steps:
    - name: Checkout at target commit
      uses: actions/checkout@v4
      with:
        ref: ${{ needs.setup.outputs.commit_sha }}

    # ─── REPLACE THIS BLOCK ───────────────────────────────
    - name: Configure registry auth (ECR / GHCR / ACR / etc)
      # ...

    - name: Fetch secrets (Vault / AWS Secrets Manager / etc)
      # Use needs.setup.outputs.app_env to pick env-specific path
      # e.g. "${APP_ENV}/data/myapp"

    - name: Build and push image
      uses: docker/build-push-action@v6
      with:
        context: .
        push: true
        tags: |
          <YOUR-REGISTRY>/<APP>:${{ needs.setup.outputs.image_tag }}
          <YOUR-REGISTRY>/<APP>:${{ needs.setup.outputs.app_env }}-latest
    # ──────────────────────────────────────────────────────
```

#### Job: `retag` (line ~530)

Customize for your registry. Common implementations:

- **AWS ECR**: `aws ecr batch-get-image` + `aws ecr put-image` (in demo template)
- **GHCR**: `docker pull` + `docker tag` + `docker push`
- **GCR/Artifact Registry**: `gcloud artifacts docker tags add`
- **ACR**: `az acr import` with new tag

#### Job: `rollback-verify` (line ~588)

Replace simulation with actual existence check:

```yaml
- name: Verify rollback image exists
  env:
    IMAGE_TAG: ${{ needs.setup.outputs.image_tag }}
  run: |
    # Example for ECR:
    aws ecr describe-images \
      --repository-name "<APP>" \
      --image-ids imageTag="$IMAGE_TAG" \
      || { echo "::error::Image not found"; exit 1; }
```

#### Job: `deploy` (line ~620)

Replace simulation with your deploy mechanism:

- **Helm**: `helm upgrade --atomic --wait --timeout 10m ...`
- **kubectl**: `kubectl apply -f ...` then `kubectl rollout status`
- **AWS ECS**: `aws ecs update-service ...`
- **Pulumi/Terraform**: `pulumi up` / `terraform apply`

```yaml
deploy:
  name: "Deploy · ${{ needs.setup.outputs.app_env }}"
  needs: [setup, build, retag, rollback-verify]
  if: |
    always()
    && needs.setup.result == 'success'
    && contains(fromJSON('["dev","stg","prod-deploy","rollback"]'), needs.setup.outputs.target)
    && (
      (needs.setup.outputs.target == 'dev' && needs.build.result == 'success') ||
      (needs.setup.outputs.target == 'stg' && needs.build.result == 'success') ||
      (needs.setup.outputs.target == 'prod-deploy' && needs.retag.result == 'success') ||
      (needs.setup.outputs.target == 'rollback' && needs.rollback-verify.result == 'success')
    )
  runs-on: <YOUR-DEPLOY-RUNNER>
  steps:
    - name: Checkout
      uses: actions/checkout@v4
      with:
        ref: ${{ needs.setup.outputs.commit_sha }}

    # ─── REPLACE THIS BLOCK ───────────────────────────────
    - name: Configure cloud credentials
      # ...

    - name: Deploy
      env:
        APP_ENV: ${{ needs.setup.outputs.app_env }}
        IMAGE_TAG: ${{ needs.setup.outputs.image_tag }}
      run: |
        helm upgrade <APP>-${APP_ENV} <chart> \
          --install --atomic --wait \
          --namespace <YOUR-NAMESPACE-PATTERN> \
          --set image.tag=${IMAGE_TAG}
    # ──────────────────────────────────────────────────────
```

#### Step: Setup → "Resolve environment config" (line ~250)

Update environment mapping to your infra:

```bash
case "$TARGET" in
  dev)
    APP_ENV="development"
    DEPLOYMENT_ENV="development"
    # Add your infra-specific outputs:
    CLUSTER="<dev-cluster-name>"
    NAMESPACE="<app>-dev"
    VAULT_PATH="development/data/<app>"
    ;;
  stg)
    APP_ENV="staging"
    DEPLOYMENT_ENV="staging"
    CLUSTER="<stg-cluster-name>"
    NAMESPACE="<app>-stg"
    VAULT_PATH="staging/data/<app>"
    ;;
  prod-build)
    APP_ENV="production"
    DEPLOYMENT_ENV=""              # no deployment record (build only)
    CLUSTER=""                     # no cluster
    NAMESPACE=""
    VAULT_PATH="production/data/<app>"
    ;;
  prod-deploy|rollback)
    APP_ENV="production"
    DEPLOYMENT_ENV="production"
    CLUSTER="<prod-cluster-name>"
    NAMESPACE="<app>-prod"
    VAULT_PATH=""                  # no vault fetch (image already built)
    ;;
esac
```

Then add corresponding outputs to setup job and use them in build/deploy.

### Optional customizations

#### Mattermost / Slack notifications

The `notify` job (line ~1100) currently logs to `$GITHUB_STEP_SUMMARY`. Add webhook step:

```yaml
- name: Send Mattermost notification
  if: ${{ secrets.MATTERMOST_WEBHOOK_URL != '' }}
  env:
    WEBHOOK_URL: ${{ secrets.MATTERMOST_WEBHOOK_URL }}
    STATUS: ${{ steps.status.outputs.status }}
    # ... other env vars
  run: |
    MSG=$(cat <<EOF
    $EMOJI **$ACTION** — \`$VERSION\`
    By @$TRIGGERED_BY · ${COMMIT_COUNT} commits
    [View run]($RUN_URL)
    EOF
    )
    PAYLOAD=$(jq -n --arg text "$MSG" '{text: $text}')
    curl -sS -X POST -H 'Content-Type: application/json' \
      -d "$PAYLOAD" "$WEBHOOK_URL" || echo "::warning::Notify failed"
```

#### Multi-platform builds (arm64 + amd64)

Add `platform` input to `release.yml` `workflow_dispatch.inputs`:

```yaml
platform:
  description: "Image platform"
  required: false
  type: choice
  options: [arm64, amd64]
  default: arm64
```

Then propagate to setup job + use in image tag (`platform_suffix`).

#### Vault drift check

Add a separate `vault-diff-check.yml` workflow that compares dev/stg/prod vault values, run pre-flight before stg cut.

---

## GitHub repo settings

### Required

1. **Workflow permissions:**
   Settings → Actions → General → Workflow permissions:
   - ✅ **Read and write permissions**
   - ✅ **Allow GitHub Actions to create and approve pull requests**

   Without this: tag push fails, workflow chain dispatch fails.

2. **Secrets (`Settings → Secrets and variables → Actions → New secret`):**

   | Secret | Used for |
   |---|---|
   | `GITHUB_TOKEN` | _Auto-provided._ Default token works for most operations. |
   | `<YOUR_REGISTRY_AUTH>` | Image registry login (e.g., `ECR_PASSWORD`, `DOCKER_HUB_TOKEN`) |
   | `<YOUR_CLOUD_KEY>` / `<YOUR_CLOUD_SECRET>` | Cloud provider credentials |
   | `VAULT_TOKEN` | If using HashiCorp Vault |
   | `MATTERMOST_WEBHOOK_URL` | Optional, for notifications |
   | `PAT_TOKEN` | Optional, only if `GITHUB_TOKEN` permissions insufficient (e.g., to trigger workflows on protected branches) |

3. **Variables (`Settings → Secrets and variables → Actions → Variables`):**

   | Variable | Used for |
   |---|---|
   | `VAULT_HOST` | If using Vault |
   | _(any other infra-specific config)_ | |

### Recommended

4. **Branch protection on `main`:**
   - Require PR review before merge
   - Require status checks to pass
   - Optionally: require linear history

5. **ECR/registry lifecycle policy:**

   Set retention rules per tag pattern:

   | Tag pattern | Retention |
   |---|---|
   | `v*` (GA images, no suffix) | **Min 1 year** |
   | `v*-prod-*` (prod-build interim) | 90 days |
   | `v*-rc-*` (RC images) | 90 days |
   | `dev-*` | 30 days |
   | `*-latest-*` (pointers) | No retention (force-pushed) |

---

## Validation drill

After adoption, run these drills to validate the setup:

### Drill 1 — Regular cycle

```
1. Add 2-3 dummy commits to main
2. Actions → Release → target=dev → Run
   ✓ Verify dev deployment record + changelog
3. Actions → Release → target=stg, bump=patch → Run
   ✓ Verify v0.0.1-rc tag created, stg deployed
4. Actions → Release → target=prod-build, from=v0.0.1-rc → Run
   ✓ Verify issue "Awaiting approval: v0.0.1 → production" opened
5. Comment /approve on the issue
   ✓ Verify chain dispatch, GA tag v0.0.1, Release published, issue closed
```

### Drill 2 — Hotfix

```
1. Actions → Prepare Branch → kind=hotfix → Run
   ✓ Verify hotfix/v0.0.2 branch created from v0.0.1
2. Push fix commit to hotfix/v0.0.2
3. Actions → Release → target=stg, from=hotfix/v0.0.2 → Run
   ✓ Verify run-name: HOTFIX | from=hotfix/v0.0.2 | tag=v0.0.2-rc
4. Actions → Release → target=prod-build, from=v0.0.2-rc → Run
   ✓ Verify issue title: "Awaiting approval: v0.0.2 → production · HOTFIX"
5. /approve
   ✓ Verify Release: "v0.0.2 · HOTFIX" with 🚨 badge
```

### Drill 3 — Rollback

```
Prerequisite: at least 2 GA releases exist
1. Actions → Release → target=rollback, from=v0.0.1 → Run
   ✓ Verify guard authorization (only approvers.production can trigger)
   ✓ Verify Release v0.0.2 annotated with rollback note
   ✓ Verify Release v0.0.1 marked as Latest
   ✓ Verify deployment record env=production with old SHA
```

### Drill 4 — Cherry-pick

```
1. Actions → Prepare Branch → kind=release → Run
   ✓ Verify release/v0.1.0 created
2. Cherry-pick commits to release/v0.1.0
3. Actions → Release → target=stg, from=release/v0.1.0 → Run
   ✓ Verify run-name: STG | from=release/v0.1.0 | tag=v0.1.0-rc | mode: CHERRYPICK
4. Continue: prod-build → /approve → prod-deploy
   ✓ Verify Release: "v0.1.0 · CHERRYPICK" with 🍒 badge
```

---

## Migrating from existing workflows

### Phase 1 — Parallel (validation)

Keep existing workflows running. Copy new files with `-v2` suffix:

```bash
.github/workflows/release-v2.yml
.github/workflows/prepare-branch-v2.yml
.github/workflows/on-approve-v2.yml
```

Adjust internal references:
- `on-approve-v2.yml`: `event_type: 'release'` → use unique type like `'release-v2'`
- `release-v2.yml`: `repository_dispatch.types: [release]` → `[release-v2]`

Run drills 1-4 above. Validate without affecting prod traffic.

### Phase 2 — Cutover

When confident:

```bash
# Rename
mv .github/workflows/release-v2.yml .github/workflows/release.yml
mv .github/workflows/prepare-branch-v2.yml .github/workflows/prepare-branch.yml
mv .github/workflows/on-approve-v2.yml .github/workflows/on-approve.yml

# Restore event_type
sed -i 's/release-v2/release/g' .github/workflows/release.yml .github/workflows/on-approve.yml

# Archive old workflows
mkdir -p .github/workflows-archive
mv .github/workflows/<OLD-WORKFLOW-1>.yml .github/workflows-archive/
# ...
```

Close any pending issues from old convention. Update team playbook.

### Phase 3 — Cleanup

After 1+ sprint stable:

- Delete `workflows-archive/`
- Optionally clean up old git tags (legacy `-preview`, `-prod` suffixes)
- Add scheduled `rc-reminder.yml` if "forgotten RC" is a real concern

---

## Troubleshooting

### "Resource not accessible by integration" (403)

**Cause:** Workflow lacks required permissions for an API call.

**Fix:** Check the API endpoint's required permission. Common ones:

| API | Permission |
|---|---|
| `createDeployment` | `deployments: write` |
| `createDispatchEvent` (repository_dispatch) | `contents: write` |
| `createWorkflowDispatch` | `actions: write` |
| `createIssue` / `createComment` | `issues: write` |
| Tag push | `contents: write` |

Add to workflow `permissions:` block.

### "No ref found for: <SHA>" when creating deployment

**Cause:** `git rev-parse v1.0.0` on annotated tag returns the tag object OID, not commit SHA.

**Fix:** Always dereference with `^{commit}`:

```bash
SHA=$(git rev-parse --verify "$REF^{commit}" 2>/dev/null \
  || git rev-parse --verify "origin/$REF^{commit}" 2>/dev/null)
```

### "fatal: not a git repository" in `gh` CLI step

**Cause:** Job runs without `actions/checkout` step. `gh` CLI infers repo from `.git`.

**Fix:** Add `actions/checkout@v4` step before `gh` calls, OR set `GH_REPO=${{ github.repository }}` env var.

### "ambiguous argument 'hotfix/v0.0.2': unknown revision"

**Cause:** Branch only exists at `origin/hotfix/v0.0.2` (remote-tracking), not local.

**Fix:** Try both forms:

```bash
SHA=$(git rev-parse --verify "$REF" 2>/dev/null \
  || git rev-parse --verify "origin/$REF" 2>/dev/null)
```

### sed: "unknown option to `s`" with pipe alternation

**Cause:** sed delimiter `|` conflicts with regex alternation operator `|`.

**Fix:** Use a different delimiter, e.g. `#`:

```bash
sed -E 's#^(hotfix|release)/##'
#      ^                    ^^
```

### Run-name shows old format after workflow update

**Cause:** Re-running an existing workflow run uses the YAML at original trigger time (pinned).

**Fix:** Dispatch a fresh run instead of re-running. Workflow YAML is locked per run.

### Latest release badge stays on rolled-back version

**Cause:** GitHub auto-picks Latest based on semver, not deployment state.

**Fix:** In `rollback-finalize` job, use `gh release edit <target> --latest` to explicitly promote the restored release to Latest.

---

## FAQ

**Q: Why manual prod-build instead of auto-trigger after stg?**

A: During QA iteration (day 8-10), stg is re-cut multiple times. If prod-build auto-runs each time, you waste 15-20min build × N iterations. Manual = engineer explicit "this is the lock point".

Risk: forgotten RC. Mitigate with optional scheduled reminder workflow that pings if RC tag exists > 5 days without prod-build.

**Q: Why `repository_dispatch` for chain instead of `workflow_dispatch`?**

A: `workflow_dispatch.inputs` are visible in the manual dispatch UI form. We don't want `release_type` and `triggered_by` cluttering the form (engineer never sets these manually). `repository_dispatch.client_payload` is invisible — keeps the form clean.

**Q: Why plain semver, not `v1.0.0-prod`?**

A: Standard SemVer is tooling-friendly (Go modules, Docker tags, package managers all expect plain `vX.Y.Z`). Suffix-less GA implies "this is the final release" without verbose notation.

**Q: What if my repo doesn't have GitHub Deployments yet?**

A: First run will create them. The `/deployments` page returns 404 until at least 1 deployment exists; after first dispatch it activates.

**Q: Can I run this on private repos?**

A: Yes. All features used are free for private repos:
- GitHub Issues, Releases, Deployments, Tags = free
- `repository_dispatch`, `workflow_dispatch` = free
- `issue_comment` events = free
- Avoid GitHub Environments (paid feature) — we use `/approve` issues instead

**Q: Multi-repo deploys?**

A: This pattern is single-repo. For multi-repo (e.g., monorepo or shared release flow), adapt by using `actions/github-script` to dispatch to other repos. Each downstream repo can run its own version of this workflow set.

**Q: How do I handle environments with different deploy mechanisms?**

A: The `setup` job's "Resolve environment config" step is the single source of truth for env→infra mapping. Add per-env outputs (cluster, deploy command, etc) and reference them in `deploy` job conditionals.

**Q: Audit trail — who did what?**

A: Multiple sources combine:
- **GitHub Actions runs** — actor + timestamp + duration
- **GitHub Deployments tab** — environment state per commit
- **Approval issues** — comment thread is the audit log
- **GitHub Releases** — annotated GA tag with `Release-Type` + `Triggered-By` metadata
- **Mattermost notifications** (optional) — realtime broadcast

---

## Reference: this demo repo

- Repo: `<your-org>/github-deployments-demo`
- Source for all 3 workflow files
- Includes simulated build/deploy (echo + sleep) — **replace with real infra code in your adoption**
- All orchestration logic (job graph, conditions, API calls) is identical to production

For a real production reference, see: `<your-internal-template-repo>` (replace with your org's real adoption).

---

## Credits

This strategy was developed and refined over multiple iterations with feedback from real release pain points:

- 9 legacy workflows → 3 unified
- ~735 release tags → cleaner ~30/year
- Manual changelog → auto-generated via Deployments API
- 3 approval gates → 1 (prod only)
- Bot user attribution → real engineer in chain runs

License: adopt freely.
