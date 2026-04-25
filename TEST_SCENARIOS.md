# Test Scenarios — github-deployments-demo

End-to-end test plan untuk validate semua workflow + edge cases.

**Estimated time:** 60-90 menit untuk full run.

---

## Pre-flight checklist

Sebelum mulai test:

```bash
cd /Users/adhan/ctlyst/github-deployments-demo
git checkout main
git pull
```

**1. GitHub repo settings:**
- [ ] Settings → Actions → General → Workflow permissions = **either OK**:
  - "Read and write permissions" (simpler, more permissive)
  - "Read repository contents and packages permissions" (restricted, recommended — workflows declare explicit `permissions:`)
- [ ] **"Allow GitHub Actions to create and approve pull requests"** = ✅ checked
- [ ] `.github/approvers.yml` production list contains your GitHub login

> Note: All v6 workflows declare explicit `permissions:` blocks, so restricted default works fine. The restricted option is more secure (no accidental write for unrelated workflows added later).

**2. Clean state (optional, kalau mau fresh start):**

```bash
# Delete all tags
git tag -l 'v*' | xargs -I {} git push origin --delete {} 2>/dev/null
git tag -l 'v*' | xargs git tag -d 2>/dev/null

# Close pending issues
gh issue list --label pending-prod-deploy --json number --jq '.[].number' \
  | xargs -I {} gh issue close {} --reason not_planned 2>/dev/null

# Delete releases
gh release list --json tagName --jq '.[].tagName' \
  | xargs -I {} gh release delete {} --yes --cleanup-tag 2>/dev/null

# Delete hotfix/release branches
git branch -r | grep -E 'origin/(hotfix|release)/' | sed 's|origin/||' \
  | xargs -I {} git push origin --delete {} 2>/dev/null
```

**3. Add baseline commits untuk material changelog:**

```bash
echo "" >> README.md && git commit -am "feat: baseline commit 1"
echo "" >> README.md && git commit -am "fix: baseline commit 2"
echo "" >> README.md && git commit -am "refactor: baseline commit 3"
git push origin main
```

---

## Drill 1 — Regular cycle (Happy path)

### 1.1 Dev deploy

**Action:**
- Actions → **Release** → Run workflow
  - target: `dev`
  - from: (blank)
  - bump: `patch`

**Expected:**
- Run-name: `DEV | from=main`
- Jobs: setup ✅ → build ✅ → deploy ✅ → changelog ✅ → deployment-record ✅ → notify ✅ (other jobs skipped)
- Step Summary: changelog dengan 3 commit di atas
- Deployments page: env=`development` muncul, badge hijau

**Verify:**
- [ ] Run sukses (semua hijau)
- [ ] Run-name match
- [ ] Changelog di Step Summary
- [ ] `/deployments` page punya environment "development"

### 1.2 Stg cut (pertama)

**Action:**
- Actions → **Release** → Run workflow
  - target: `stg`
  - from: (blank)
  - bump: `patch`

**Expected:**
- Run-name: `STG | from=main`
- Setup log: `Version: v0.0.1 | Image: v0.0.1-rc-arm`
- Tag step: `RC tag: v0.0.1-rc → <sha>`
- Tag created: `v0.0.1-rc` (lightweight)

**Verify:**
- [ ] Run sukses
- [ ] Tags page: `v0.0.1-rc` ada
- [ ] Deployments page: env=`staging` muncul
- [ ] Step Summary: changelog (last 20 commits, no previous deploy)

### 1.3 Stg re-cut (rolling RC)

**Action:**

```bash
echo "" >> README.md && git commit -am "fix: qa feedback"
git push origin main
```

- Actions → **Release** → Run workflow → target=`stg` → Run

**Expected:**
- Same RC tag `v0.0.1-rc` force-pushed ke commit baru
- Stg deployment baru (commit yang lebih baru)
- Step summary: changelog "1 commit since last stg deploy"

**Verify:**
- [ ] Tag `v0.0.1-rc` masih ada (not deleted)
- [ ] `git log v0.0.1-rc -1` shows new commit (after force-push)
- [ ] Deployments page env=staging history accumulate (2 entries now)

### 1.4 Prod-build (manual lock day 11)

**Action:**
- Actions → **Release** → Run workflow
  - target: `prod-build`
  - from: (blank — auto-detect)
  - bump: `patch`

**Expected:**
- Setup log: `Auto-detected latest RC tag: v0.0.1-rc`
- Stg freshness guard: ✅ pass (stg fresh, matches main)
- Run-name: `PROD | from=v0.0.1-rc | action: BUILD`
- Issue opened: `Awaiting approval: v0.0.1 → production`

**Verify:**
- [ ] Run sukses
- [ ] Issue opened with label `pending-prod-deploy`
- [ ] Issue body: deployment metadata table + changelog + approval commands + `<!-- release-meta -->` block

### 1.5 Approve & deploy (chain)

**Action:**
- Open the issue → comment `/approve`

**Expected:**
- Workflow "Approval Handler" runs (sukses)
- Run-name: `APPROVED | Awaiting approval: v0.0.1 → production | by:adhaniscuber`
- New "Release" run dispatched: `PROD | from=v0.0.1-rc | by:adhaniscuber | action: DEPLOY`
- GA tag created: `v0.0.1` (annotated)
- GitHub Release published: `v0.0.1`
- Issue closed dengan comment ✅
- Deployments page: env=`production` aktif

**Verify:**
- [ ] Approval Handler run sukses
- [ ] Chain Release run sukses (semua jobs)
- [ ] Tag `v0.0.1` ada (annotated — `git cat-file -p v0.0.1` tunjukin metadata)
- [ ] GitHub Release `v0.0.1` published with changelog
- [ ] Issue closed
- [ ] Deployments page punya env=production

---

## Drill 2 — Hotfix flow

### 2.1 Prepare hotfix branch

**Action:**
- Actions → **Prepare Branch** → Run workflow
  - kind: `hotfix`
  - base: (blank — auto-detect)

**Expected:**
- Setup log: `Base: v0.0.1 (auto-detected)`
- Branch created: `hotfix/v0.0.2`

**Verify:**
- [ ] Branch `hotfix/v0.0.2` ada di remote (`git fetch && git branch -r | grep hotfix`)
- [ ] Branch HEAD = commit dari `v0.0.1` tag

### 2.2 Push fix ke hotfix branch

**Action:**

```bash
git fetch
git checkout hotfix/v0.0.2
echo "" >> README.md && git commit -am "fix: critical hotfix"
git push origin hotfix/v0.0.2
```

### 2.3 Stg cut from hotfix

**Action:**
- Actions → **Release** → Run workflow
  - target: `stg`
  - from: `hotfix/v0.0.2`

**Expected:**
- Setup log: `Release type: hotfix`
- Run-name: `HOTFIX | from=hotfix/v0.0.2`
- Tag created: `v0.0.2-rc`

**Verify:**
- [ ] Run-name says HOTFIX
- [ ] Tag `v0.0.2-rc` ada

### 2.4 Prod-build for hotfix

**Action:**
- Actions → **Release** → Run workflow
  - target: `prod-build`
  - from: (blank)

**Expected:**
- Auto-detect picks `v0.0.2-rc` (latest semver)
- Release type: `hotfix` (auto-detected from branch ancestry)
- Stg freshness: skip main check (hotfix release)
- Run-name: `HOTFIX | from=v0.0.2-rc | action: BUILD`
- Issue opened: `Awaiting approval: v0.0.2 → production · HOTFIX`

**Verify:**
- [ ] Issue title has `· HOTFIX` suffix
- [ ] Issue body says `Release type: hotfix`

### 2.5 Approve & deploy hotfix

**Action:**
- `/approve` di issue

**Expected:**
- Chain Release: `HOTFIX | from=v0.0.2-rc | by:adhaniscuber | action: DEPLOY`
- GA tag `v0.0.2` annotated dengan `Release-Type: hotfix`
- Release title: `v0.0.2 · HOTFIX`
- Release body has 🚨 badge: `> **🚨 Hotfix release**`

**Verify:**
- [ ] Release `v0.0.2 · HOTFIX` dengan badge
- [ ] Tag `v0.0.2` annotated (`git cat-file -p v0.0.2 | grep Release-Type` = hotfix)

---

## Drill 3 — Rollback

**Prerequisites:** ≥ 2 GA releases (v0.0.1 dan v0.0.2 dari drill 1+2).

### 3.1 Rollback prod ke v0.0.1

**Action:**
- Actions → **Release** → Run workflow
  - target: `rollback`
  - from: `v0.0.1`

**Expected:**
- Setup log: `@adhaniscuber authorized for rollback`
- Run-name: `ROLLBACK | from=v0.0.1 | action: ROLLBACK`
- Jobs: setup ✅ → rollback-verify ✅ → deploy ✅ → changelog ✅ → deployment-record ✅ → rollback-finalize ✅ → notify ✅
- Release `v0.0.2` body has annotation: `⚠️ Rolled back to v0.0.1`
- Release `v0.0.1` body has annotation: `🔄 Re-activated via rollback`
- Release `v0.0.1` marked as **Latest** (badge moves)
- New deployment record env=production di commit v0.0.1

**Verify:**
- [ ] Release v0.0.2 punya rollback annotation
- [ ] Release v0.0.1 marked "Latest" (badge sebelumnya di v0.0.2)
- [ ] Deployments tab production: latest entry = v0.0.1 commit

### 3.2 Negative — unauthorized rollback

**Setup:** Pastikan `approvers.yml` production list **tidak** include user kamu (temporary edit), atau test sebagai user lain.

**Action:**
- Actions → **Release** → Run workflow → target=`rollback`, from=`v0.0.1`

**Expected:**
- Setup `Guard · rollback authorization` step fails
- Error: `@<user> not authorized for rollback`

**Verify:**
- [ ] Workflow fails di guard step (early termination)
- [ ] No deployment record created
- [ ] No annotation di Releases

**Cleanup:** Restore `approvers.yml` kalau tadi di-edit.

---

## Drill 4 — Cherry-pick release

### 4.1 Prepare release branch

**Action:**
- Actions → **Prepare Branch** → Run workflow
  - kind: `release`
  - base: (blank)

**Expected:**
- Branch created: `release/v0.1.0` (atau `v0.0.3` kalau v0.0.2 latest — depend on bump)

**Verify:**
- [ ] Branch `release/v0.1.0` exists at remote

### 4.2 Cherry-pick commit

**Action:**

```bash
# Tambah commit di main dulu
git checkout main
echo "feature" >> README.md && git commit -am "feat: cherry-pick candidate"
git push origin main
SHA_TO_PICK=$(git rev-parse HEAD)

# Cherry-pick ke release branch
git fetch
git checkout release/v0.1.0
git cherry-pick "$SHA_TO_PICK"
git push origin release/v0.1.0
```

### 4.3 Stg cut from release branch

**Action:**
- Actions → **Release** → Run workflow
  - target: `stg`
  - from: `release/v0.1.0`

**Expected:**
- Setup log: `Release type: cherrypick`
- Run-name: `STG | from=release/v0.1.0 | mode: CHERRYPICK`
- Tag `v0.1.0-rc` created

### 4.4 Prod-build for cherry-pick

**Action:**
- Actions → **Release** → Run workflow → target=`prod-build`, from=(blank)

**Expected:**
- Auto-detect: `v0.1.0-rc`
- Release type: `cherrypick`
- Stg freshness skip main check (cherrypick release)
- Issue: `Awaiting approval: v0.1.0 → production · CHERRYPICK`

**Verify:**
- [ ] Issue title has `· CHERRYPICK`

### 4.5 Approve & deploy cherry-pick

**Action:** `/approve` in issue

**Expected:**
- Chain run: `PROD | from=v0.1.0-rc | by:adhaniscuber | action: DEPLOY | mode: CHERRYPICK`
- Tag `v0.1.0` annotated dengan `Release-Type: cherrypick`
- Release `v0.1.0 · CHERRYPICK` dengan badge 🍒

**Verify:**
- [ ] Release `v0.1.0 · CHERRYPICK` dengan 🍒 badge

---

## Drill 5 — Negative tests (edge cases)

### 5.1 Prod-build tanpa stg deployment

**Setup:** Repo fresh tanpa pernah deploy stg (atau delete semua deployment env=staging via API).

**Action:** Actions → **Release** → target=`prod-build`, from=(blank)

**Expected:**
- Auto-detect possibly fails kalau ga ada RC tag, OR
- Stg freshness guard fails: `::error::No staging deployment found. Cut stg first before prod-build`

**Verify:**
- [ ] Workflow blocks dengan error message yang clear
- [ ] No issue created
- [ ] No image build

### 5.2 Stg stale (main moved past)

**Setup:**
- Cut stg sukses (e.g., commit A)
- Push 5 commits baru ke main:

```bash
for i in 1 2 3 4 5; do
  echo "" >> README.md && git commit -am "feat: post-stg commit $i"
done
git push origin main
```

**Action:** Actions → **Release** → target=`prod-build`, from=(blank)

**Expected:**
- Stg freshness guard fails:
  ```
  🛑 Stale staging — prod-build blocked
  main has 5 commits past last staging deployment.
  ```
- Step Summary tab shows table dengan instruksi fix

**Verify:**
- [ ] Workflow blocks
- [ ] Step Summary punya prominent warning
- [ ] Engineer can re-cut stg (target=stg) lalu retry prod-build

### 5.3 Unauthorized /approve

**Setup:** Open issue (e.g., dari drill 1.4), but comment dari user yang BUKAN approver.

**Action:**
- Buat dummy account / pakai bot, comment `/approve` di issue

**Expected:**
- Approval Handler run shows authorization fail
- Bot comments di issue: `⛔ @<user> not authorized to /approve production deployments`
- No chain dispatch

**Verify:**
- [ ] Refusal comment posted
- [ ] No new Release run
- [ ] Issue stays open

### 5.4 GA tag already exists

**Setup:** GA tag `v0.0.1` sudah ada (dari drill 1).

**Action:**
- Manually re-trigger prod-deploy untuk `v0.0.1-rc` (e.g., dispatch repository_dispatch via gh CLI):

```bash
gh api repos/adhaniscuber/deployment-release-strategy/dispatches \
  -X POST \
  -f event_type=release \
  -f 'client_payload[target]=prod-deploy' \
  -f 'client_payload[from]=v0.0.1-rc' \
  -f 'client_payload[release_type]=regular' \
  -f 'client_payload[triggered_by]=adhaniscuber'
```

**Expected:**
- Setup `Guard · GA tag must not exist` fails
- Error: `GA tag v0.0.1 already exists.`

**Verify:**
- [ ] Workflow blocks
- [ ] No double Release published

### 5.5 Rollback to non-existent tag

**Action:** Actions → **Release** → target=`rollback`, from=`v9.9.9`

**Expected:**
- Setup compute version step fails: `GA tag v9.9.9 does not exist`

**Verify:**
- [ ] Workflow blocks
- [ ] Clear error message

### 5.6 Reject /reject

**Setup:** Open issue from prod-build, comment `/reject not enough QA time`.

**Expected:**
- Approval Handler run-name: `REJECTED | Awaiting approval: vX.Y.Z → production | by:adhaniscuber`
- Comment posted: "🚫 Rejected by @adhaniscuber at <time>. Reason: not enough QA time"
- Issue closed `not_planned`
- RC tag remains (engineer can re-cut)

**Verify:**
- [ ] Issue closed dengan reason "not planned"
- [ ] Reject comment dengan alasan
- [ ] No prod-deploy chain triggered

---

## Drill 6 — Multi-platform (skip kalau demo)

**Note:** Demo ga support multi-platform. Skip section ini di demo. Untuk voila-pos-web production (yang ada `platform` input).

---

## Verification dashboard summary

Setelah semua drill selesai, cek di GitHub UI:

### Tags page
```
v0.0.1
v0.0.1-rc
v0.0.2
v0.0.2-rc
v0.1.0
v0.1.0-rc
```
6 tags total (3 GA + 3 RC).

### Releases page
- v0.1.0 · CHERRYPICK 🍒 (Latest, kalau v0.1.0 di-deploy after rollback)
- v0.0.1 (Latest, jika rollback active dan belum ada deploy lebih baru)
- v0.0.2 · HOTFIX 🚨 (annotated dengan rollback note)
- v0.0.1 (annotated dengan re-activation note)

### Deployments page
3 environments aktif: development, staging, production
History per env memperlihatkan progression timeline.

### Closed issues (label pending-prod-deploy)
- 4 closed issues (3 approved + 1 rejected)
- Setiap issue punya comment thread audit

---

## Cleanup setelah test selesai

```bash
cd /Users/adhan/ctlyst/github-deployments-demo

# Delete tags (kecuali kalau mau keep history)
git tag -l 'v*' | xargs -I {} git push origin --delete {}
git tag -l 'v*' | xargs git tag -d 2>/dev/null

# Delete branches
git branch -r | grep -E 'origin/(hotfix|release)/' | sed 's|origin/||' \
  | xargs -I {} git push origin --delete {}

# Close pending issues
gh issue list --label pending-prod-deploy --json number --jq '.[].number' \
  | xargs -I {} gh issue close {} --reason not_planned 2>/dev/null

# Delete all releases
gh release list --json tagName --jq '.[].tagName' \
  | xargs -I {} gh release delete {} --yes --cleanup-tag 2>/dev/null

# Note: Deployments cannot be bulk-deleted via API. They remain as history.
```

---

## Test result template

Salin ke spreadsheet atau issue:

| Drill | Step | Status | Notes |
|---|---|---|---|
| 1.1 | Dev deploy | ✅ Pass / ❌ Fail | |
| 1.2 | Stg cut | | |
| 1.3 | Stg re-cut | | |
| 1.4 | Prod-build | | |
| 1.5 | Approve & deploy | | |
| 2.1 | Prepare hotfix branch | | |
| 2.2 | Push fix | | |
| 2.3 | Stg from hotfix | | |
| 2.4 | Prod-build hotfix | | |
| 2.5 | Approve hotfix | | |
| 3.1 | Rollback to v0.0.1 | | |
| 3.2 | Unauthorized rollback | | |
| 4.1 | Prepare release branch | | |
| 4.2 | Cherry-pick commit | | |
| 4.3 | Stg cherrypick | | |
| 4.4 | Prod-build cherrypick | | |
| 4.5 | Approve cherrypick | | |
| 5.1 | Prod-build no stg | | |
| 5.2 | Stg stale | | |
| 5.3 | Unauthorized approve | | |
| 5.4 | GA tag exists | | |
| 5.5 | Rollback non-existent | | |
| 5.6 | Reject | | |

Total drills: **23**. Estimasi waktu per drill: ~3-5 menit. Total ~60-90 menit dengan workflow run time.
