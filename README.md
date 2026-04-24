# Release Strategy Demo — v6 adapted

Demo repo untuk test full voila-pos-web v6 release workflow di environment tanpa AWS/Vault/Helm. Build & deploy di-stub (echo + sleep), sisanya real.

## Files

| File | Purpose |
|---|---|
| `.github/workflows/prepare-branch.yml` | Bootstrap hotfix/release branch from latest GA tag |
| `.github/workflows/release.yml` | 5-target release workflow (dev/stg/prod-build/prod-deploy/rollback) |
| `.github/workflows/on-approve.yml` | Handle `/approve` and `/reject` on prod approval issues |
| `.github/approvers.yml` | Production approvers list |
| `.github/workflows/deploy.yml` | _(legacy simple single-target demo, can delete)_ |

## What's real vs simulated

**Real:**
- Run-name expression (informative titles)
- Version compute (plain semver, RC/GA tags)
- Release type classification (auto-detect from branch prefix)
- Git tag creation (RC rolling force-push, GA annotated)
- GitHub Deployments API (record + changelog source)
- Changelog generation (since last deployment of same env)
- GitHub Issue (open / close / comment)
- GitHub Release (publish with changelog)
- `/approve` & `/reject` parsing + authorization
- Chain dispatch (on-approve → release.yml prod-deploy)
- Rollback annotations on Releases

**Simulated (echo + sleep):**
- Build image (no Docker, no ECR)
- Retag ECR image
- Rollback-verify (always pass)
- Helm deploy

## Prerequisites

1. **Enable Actions write permission:**  
   Settings → Actions → General → Workflow permissions → select **"Read and write permissions"**.  
   Also check **"Allow GitHub Actions to create and approve pull requests"**.  
   Without this, tag push + workflow dispatch chain will fail.

2. **Your GitHub login is already in `approvers.yml`** (`adhaniscuber`). Adjust if testing as different user.

## Full end-to-end drill

### 1. Regular cycle (dev → stg → prod-build → approve → prod-deploy)

```bash
# Add some commits to main first (for changelog material)
echo "" >> README.md && git commit -am "feat: demo commit 1"
echo "" >> README.md && git commit -am "fix: demo commit 2"
git push

# Actions → Release → Run workflow → target=dev → Run
# Expected run-name: DEV | from=main | by:adhaniscuber
```

Verify:
- Actions Summary tab shows changelog
- `/deployments` page shows **development** environment active

```bash
# Actions → Release → target=stg, bump=patch → Run
# Expected run-name: STG | from=main | by:adhaniscuber
```

Verify:
- Tags page shows `v0.0.1-rc`
- Deployments page shows **staging** environment active
- Changelog in Summary

```bash
# Simulate stg re-cut after bug fix
echo "" >> README.md && git commit -am "fix: qa feedback"
git push
# Actions → Release → target=stg → Run
# Expected: v0.0.1-rc force-pushed to new commit (rolling RC)
```

```bash
# Actions → Release → target=prod-build, from=v0.0.1-rc → Run
# Expected:
#   - Run-name: PROD | from=v0.0.1-rc | by:adhaniscuber | action: BUILD
#   - Opens issue "Awaiting approval: v0.0.1 → production"
```

Open the issue — verify body has:
- Deployment metadata table (RC tag, release type, commit, etc)
- Changelog section
- Approval command table
- Hidden `<!-- release-meta -->` block

```bash
# In the issue, comment: /approve
# Expected: on-approve.yml fires, dispatches release.yml target=prod-deploy
```

Verify:
- Actions tab shows new run `PROD | from=v0.0.1-rc | by:adhaniscuber | action: DEPLOY`
- GA tag `v0.0.1` created (annotated with release-type metadata)
- GitHub Release `v0.0.1` published with changelog
- Issue closed with "✅ Deployed" comment
- Deployments page shows **production** active

### 2. Hotfix flow

```bash
# Actions → Prepare Branch → kind=hotfix → Run
# Expected: creates hotfix/v0.0.2 branch from v0.0.1

# Push a fix commit to the new branch
git fetch
git checkout hotfix/v0.0.2
echo "" >> README.md && git commit -am "fix: demo hotfix"
git push

# Actions → Release → target=stg, from=hotfix/v0.0.2 → Run
# Expected run-name: HOTFIX | from=hotfix/v0.0.2 | by:adhaniscuber

# Actions → Release → target=prod-build, from=v0.0.2-rc → Run
# Expected: issue "Awaiting approval: v0.0.2 → production · HOTFIX"

# /approve in issue
# Expected: GA tag v0.0.2, Release "v0.0.2 · HOTFIX" with 🚨 badge
```

### 3. Rollback

```bash
# Needs at least 2 GA releases
# Actions → Release → target=rollback, from=v0.0.1 → Run
# Expected:
#   - Guard: rejects if your login not in approvers.yml production list
#   - Release v0.0.2 (current) annotated with rollback note
#   - Release v0.0.1 (target) annotated with re-activation note
#   - Deployment record created (env=production, old SHA)
```

### 4. Cherry-pick release

```bash
# Actions → Prepare Branch → kind=release → Run
# Expected: creates release/v0.1.0 branch from v0.0.2

# Cherry-pick specific commits
git fetch
git checkout release/v0.1.0
git cherry-pick <some-sha-from-main>
git push

# Actions → Release → target=stg, from=release/v0.1.0
# Expected run-name: STG | from=release/v0.1.0 | by:adhaniscuber | mode: CHERRYPICK
# Flow continues: prod-build → /approve → prod-deploy
# Expected: Release "v0.1.0 · CHERRYPICK" with 🍒 badge
```

## Troubleshooting

**"Workflow not triggered after /approve":**  
Settings → Actions → General → Workflow permissions → **"Read and write permissions"**.

**"Tag push failed":**  
Same as above — needs write permission.

**"createWorkflowDispatch permission denied":**  
Workflow needs `actions: write` — already set in on-approve.yml.

## Clean up for fresh drill

```bash
# Delete tags
git tag -l 'v*' | xargs -I {} git push origin --delete {}
git tag -l 'v*' | xargs git tag -d 2>/dev/null

# Close all pending issues
gh issue list --label pending-prod-deploy --json number --jq '.[].number' \
  | xargs -I {} gh issue close {} --reason not_planned

# Delete all Releases
gh release list --json tagName --jq '.[].tagName' \
  | xargs -I {} gh release delete {} --yes --cleanup-tag

# Delete hotfix/release branches
git branch -r | grep -E 'origin/(hotfix|release)/' | sed 's|origin/||' \
  | xargs -I {} git push origin --delete {}

# Note: GitHub Deployments cannot be bulk-deleted via UI.
# They remain in history — that's expected behavior.
```

## Differences from voila-pos-web production

This demo removes:
- AWS ECR authentication
- HashiCorp Vault secret fetch
- Self-hosted runners (`voila-highload-runner`, `voila-runner`)
- Docker container build image
- envsubst Dockerfile
- Helm chart deploy
- Mattermost webhook
- PAT_TOKEN (uses GITHUB_TOKEN instead — sufficient for demo)

All orchestration logic (job graph, conditions, API calls, tag/release flow) is **identical** to production.












