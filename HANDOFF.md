# Handoff Context — Claude Code

Quick context dump untuk Claude Code session. Copy-paste ke prompt awal kalau perlu.

---

## Project overview

**Goal:** Replace 9-workflow legacy release strategy di `voila-pos-web` dengan 3-workflow v6 strategy.

**2 repos:**

| Repo | Purpose |
|---|---|
| `/Users/adhan/ctlyst/github-deployments-demo` | Demo (echo+sleep stubs). All orchestration real. Test ground untuk validate strategy. |
| `/Users/adhan/ctlyst/voila-pos-web` | Production app. v6 workflows ada di `.github/workflows-proposed/`, belum cutover. Legacy 9 workflows masih jalan di `.github/workflows/`. |

---

## Strategy v6 in 1 minute

**3 workflows:**
1. `prepare-branch.yml` — bikin hotfix/release branch dari latest GA tag
2. `release.yml` — 5 target (`dev`, `stg`, `prod-build`, `prod-deploy`, `rollback`)
3. `on-approve.yml` — handle `/approve` di issue, dispatch chain via `repository_dispatch`

**Tag scheme (plain semver):**
- Dev: no git tag, image `dev-<sha7>-arm`
- Stg (RC): `vX.Y.Z-rc` rolling lightweight tag
- Prod-deploy (GA): `vX.Y.Z` annotated permanent tag
- Total 2 git tag per cycle (60/year)

**Approval:** issue `/approve` (no paid GitHub Environments)

**Real user traceability:** chain dispatch via `repository_dispatch` dengan `client_payload.triggered_by` — run-name show approver, bukan `github-actions` bot.

**Key innovation:**
- Manual prod-build trigger (engineer-controlled "lock" point)
- GitHub Deployments API untuk env state + auto-changelog
- Stg freshness guard (block prod-build kalau stg stale)

---

## Current state

### Demo repo (`github-deployments-demo`)

**Branch:** `main` (probably ahead of origin — push if needed)

**Files siap:**
```
.github/
├── workflows/
│   ├── prepare-branch.yml          # 154 lines, no customization needed
│   ├── release.yml                 # 700+ lines, simulated build/deploy
│   └── on-approve.yml              # ~250 lines
└── approvers.yml                   # production: [adhaniscuber]

ADOPTION.md                         # full guide for adopting in other repos
TEST_SCENARIOS.md                   # 23 manual drills
tests/
├── e2e-test.sh                     # automated bash runner using gh CLI
└── README.md                       # how to use tests
HANDOFF.md                          # this file
```

**State drilled (sebagian):**
- Drill 1 regular cycle ✅
- Drill 2 hotfix ✅
- Drill 3 rollback ✅ (last fix: promote target as Latest)
- Drill 4 cherry-pick — belum sempat full
- Drill 5 negative tests — belum sempat

### Production repo (`voila-pos-web`)

**Status:** v6 workflows di `.github/workflows-proposed/`, **belum cutover** ke `.github/workflows/`.

**Files:**
```
.github/
├── workflows/                      # legacy 9 workflows, masih jalan
└── workflows-proposed/
    ├── CONCEPT.md                  # v6 final concept doc
    ├── README.md                   # migration plan
    ├── prepare-branch.yml
    ├── release.yml                 # mostly aligned with demo, ada beberapa
    │                               #   improvements yang BELUM di-port balik
    │                               #   (sed delimiter fix, ^{commit} dereferencing,
    │                               #    auto-detect RC, stg freshness guard, etc)
    └── on-approve.yml
```

**Catatan:** Per user request, voila-pos-web belum di-update lagi setelah refactor `repository_dispatch`. Demo repo udah ahead.

**Latest legacy GA tag:** `v3.2.1-prod` (or thereabouts — 735 total releases)

---

## Last completed work (chronological)

1. CONCEPT.md v6 finalized
2. 3 workflow files written (proposed)
3. Demo repo created + workflows adapted (echo+sleep stubs)
4. Iterative testing + bug fixes:
   - sed delimiter conflict (`|` vs alternation) → fix
   - `git rev-parse` annotated tag returning tag OID → `^{commit}` fix
   - origin/main fallback to local stale → strict origin/main
   - Permission denied for createDispatchEvent (needs contents:write)
   - GA tag conflict guard
   - Rollback authorization guard
   - "Cannot resolve ref" error message clarification
5. Refactor workflow_dispatch → dual trigger (workflow_dispatch + repository_dispatch) untuk hide chain-only inputs
6. Run-name UX feedback iterations (drop `by:`, add tag info, then revert tag info due to no `replace()` function)
7. Stg freshness guard (3 checks, block prod-build kalau stg stale, skip for hotfix/cherrypick)
8. Latest badge promotion saat rollback
9. Auto-detect latest RC for prod-build/prod-deploy if `from` empty
10. Migration support untuk legacy `-prod` suffix
11. ADOPTION.md guide
12. TEST_SCENARIOS.md (23 drills)
13. tests/e2e-test.sh + README
14. Cleanup deployments via API

---

## Known quirks

### Sandbox `.git/*.lock` issue

Selama session, sandbox sering bikin commit tapi gagal cleanup `.git/HEAD.lock`, `.git/index.lock`, `.git/objects/maintenance.lock`. Setiap user push manual perlu:

```bash
rm -f .git/HEAD.lock .git/objects/maintenance.lock .git/index.lock
git push
```

Di Claude Code (terminal asli), masalah ini **ga terjadi** karena akses native filesystem. Lock files cleanup automatic.

### GitHub Actions expression limitations

GitHub Actions expressions **don't have** `replace()`, `substring`, regex, or arithmetic. Only: `contains`, `startsWith`, `endsWith`, `format`, `join`, `toJSON`, `fromJSON`, `hashFiles`.

Implication: run-name can't show "tag=v0.0.1-rc" computed from RC tag input. Engineer reads tag from branch name pattern instead.

### GitHub Deployments deletion

UI doesn't show delete button, but API does:
```bash
# Must mark inactive first
gh api -X POST "repos/$REPO/deployments/$ID/statuses" -f state=inactive
gh api -X DELETE "repos/$REPO/deployments/$ID"
```

Already implemented in `tests/e2e-test.sh` cleanup function.

### Run-name pinned per dispatch

Re-running existing workflow run uses YAML at original trigger time (pinned). To get new YAML, **dispatch fresh run** (not "Re-run failed jobs").

---

## Possible next steps

### Option 1 — Validate demo end-to-end

Run all drills from `TEST_SCENARIOS.md` or `tests/e2e-test.sh`. Document any failures. Fix.

### Option 2 — Port latest demo improvements back to voila-pos-web

Demo repo got many improvements after voila-pos-web `workflows-proposed/` was last touched. Port:
- Dual trigger (workflow_dispatch + repository_dispatch)
- Auto-detect latest RC
- Stg freshness guard (with hotfix/cherrypick skip)
- Latest badge promotion
- Migration regex for legacy -prod tag
- `^{commit}` dereferencing
- sed delimiter fix
- Better error messages

Target: `voila-pos-web/.github/workflows-proposed/release.yml` and friends.

### Option 3 — Cutover voila-pos-web to v6

Apply workflows-proposed to .github/workflows/ in voila-pos-web. Migration plan di `voila-pos-web/.github/workflows-proposed/README.md`.

Steps:
1. Validate demo works (Option 1)
2. Port latest changes (Option 2)
3. Phase 1 parallel deploy (-v3 suffix)
4. Drill semua flow di voila-pos-web
5. Phase 2 cutover (rename, archive legacy)
6. Phase 3 cleanup

### Option 4 — Add features

- Mattermost notifications (already scaffolded, needs hook)
- Multi-platform (arm64 + amd64) for voila-pos-web
- Vault drift check workflow
- Scheduled "forgotten RC" reminder (cron)

---

## Quick commands

### Push pending commits
```bash
cd /Users/adhan/ctlyst/github-deployments-demo
rm -f .git/HEAD.lock .git/objects/maintenance.lock .git/index.lock
git push origin main
```

### Run automated tests
```bash
chmod +x tests/e2e-test.sh
./tests/e2e-test.sh                 # full ~10 min
./tests/e2e-test.sh --only=drill1   # specific
./tests/e2e-test.sh --cleanup-only  # reset state
```

### Manual cleanup
```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
git tag -l 'v*' | xargs -I {} git push origin --delete {}
git tag -l 'v*' | xargs git tag -d
gh issue list --label pending-prod-deploy --json number --jq '.[].number' \
  | xargs -I {} gh issue close {} --reason not_planned
gh release list --json tagName --jq '.[].tagName' \
  | xargs -I {} gh release delete {} --yes --cleanup-tag
git branch -r | grep -E 'origin/(hotfix|release)/' | sed 's|origin/||' \
  | xargs -I {} git push origin --delete {}
gh api "repos/$REPO/deployments?per_page=100" --paginate --jq '.[].id' | while read -r ID; do
  gh api -X POST "repos/$REPO/deployments/$ID/statuses" -f state=inactive >/dev/null 2>&1
  gh api -X DELETE "repos/$REPO/deployments/$ID"
done
```

---

## User context

**User:** Wirya Ramadhan (@adhaniscuber on GitHub)

**Style preferences:**
- Simple, concrete answers (avoid over-engineering)
- Casual Bahasa Indonesia mixed with technical English
- Tables and short bullet points over prose
- Block-and-decide UX (strict guards over warnings)
- Don't propose multiple options when one is clearly better

**Past pain points to avoid:**
- Don't generate too many "options A/B/C" — user gets lost
- Don't assume things, ask if uncertain
- Don't add features user didn't ask for
- Always commit work-in-progress (sandbox can't push, user does it)
