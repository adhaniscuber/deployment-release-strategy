# Handoff Context — Claude Code

Quick context dump untuk Claude Code session resume. Copy-paste opening prompt:
> Please read HANDOFF.md first, then summarize what's done and ask which next step to focus on.

---

## What this repo is

**Demo for v6 release strategy.** Validates the orchestration logic (workflows, GitHub APIs, approval flow) without actual infrastructure. Build and deploy steps are simulated with `echo + sleep`. All other logic is production-grade.

The strategy is meant to replace legacy multi-workflow release setups with a clean 3-workflow pattern. This repo is the test ground.

---

## Strategy v6 in 1 minute

**3 workflows:**
1. `prepare-branch.yml` — bikin `hotfix/vX.Y.Z` atau `release/vX.Y.Z` branch dari latest GA tag
2. `release.yml` — 5 target (`dev`, `stg`, `prod-build`, `prod-deploy`, `rollback`)
3. `on-approve.yml` — handle `/approve` di issue, dispatch chain via `repository_dispatch`

**Tag scheme (plain semver):**
- Dev: no git tag, image `dev-<sha7>-arm`
- Stg (RC): `vX.Y.Z-rc` rolling lightweight tag
- Prod-deploy (GA): `vX.Y.Z` annotated permanent tag
- 2 git tag per cycle (~60/year)

**Approval:** issue `/approve` (no paid GitHub Environments)

**Real user traceability:** chain dispatch via `repository_dispatch` dengan `client_payload.triggered_by` — run-name show approver, bukan `github-actions` bot.

**Key innovations:**
- Manual prod-build trigger (engineer-controlled "lock" point)
- GitHub Deployments API untuk env state + auto-changelog
- Stg freshness guard (block prod-build kalau stg stale, skip for hotfix/cherrypick)
- Auto-detect latest RC tag if `from` blank
- Latest badge promotion saat rollback

---

## Current state

**Branch:** `main` (mungkin ada commits ahead of origin — push if needed)

**Files:**
```
.github/
├── workflows/
│   ├── prepare-branch.yml          # 154 lines, no customization needed
│   ├── release.yml                 # ~700 lines, simulated build/deploy
│   ├── on-approve.yml              # ~250 lines
│   └── deploy.yml                  # legacy single-target stub (can delete)
└── approvers.yml                   # production: [adhaniscuber]

ADOPTION.md                         # adoption guide for other repos
TEST_SCENARIOS.md                   # 23 manual drills
HANDOFF.md                          # this file
README.md                           # demo intro

tests/
├── e2e-test.sh                     # automated bash runner using gh CLI
└── README.md                       # how to use tests
```

**Drilled status:**
- Drill 1 regular cycle ✅
- Drill 2 hotfix ✅
- Drill 3 rollback ✅ (last fix: promote target as Latest)
- Drill 4 cherry-pick — belum sempat full
- Drill 5 negative tests — belum sempat

---

## Last completed work (chronological)

1. 3 workflow files created (prepare-branch, release, on-approve)
2. Iterative bug fixes during testing:
   - sed delimiter conflict (`|` vs alternation) → switched to `#`
   - `git rev-parse` annotated tag returning tag OID → `^{commit}` fix
   - origin/main fallback to local stale → strict origin/main with fail-fast
   - Permission denied for `createDispatchEvent` (needs `contents: write`)
   - GA tag conflict guard
   - Rollback authorization guard
3. Refactor `workflow_dispatch` → dual trigger (`workflow_dispatch + repository_dispatch`) untuk hide chain-only inputs (`release_type`, `triggered_by`)
4. Run-name UX iterations (drop `by:`, attempted tag info but reverted — no `replace()` in expressions)
5. **Stg freshness guard** — 3 checks before prod-build:
   - Block if no staging deployment ever
   - Block if RC tag commit ≠ stg deploy SHA
   - Block if main has commits past stg deploy (skip for hotfix/cherrypick)
6. Latest badge promotion saat rollback (`gh release edit --latest`)
7. Auto-detect latest RC for prod-build/prod-deploy if `from` blank
8. Migration support untuk legacy `-prod` suffix tags (regex `(-prod)?$`)
9. ADOPTION.md guide
10. TEST_SCENARIOS.md (23 drills)
11. tests/e2e-test.sh + README
12. Cleanup deployments via API (mark inactive → delete)

---

## Known quirks

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

### Annotated tags need `^{commit}`

`git rev-parse v1.0.0` on annotated tag returns the tag object OID (not commit SHA). GitHub Deployments API rejects with 422 "No ref found".

Always use `git rev-parse v1.0.0^{commit}` to dereference. Already applied in setup job.

### Run-name pinned per dispatch

Re-running existing workflow run uses YAML at original trigger time (pinned). To get new YAML, **dispatch fresh run** (not "Re-run failed jobs").

---

## Possible next steps

### Option 1 — Validate demo end-to-end

Run all drills from `TEST_SCENARIOS.md` or use automated `tests/e2e-test.sh`. Document any failures. Fix issues found.

### Option 2 — Complete remaining drills

Drill 4 (cherry-pick) and Drill 5 (negative tests) belum sempat dijalankan full. Worth running to validate the recent fixes (auto-detect, freshness guard).

### Option 3 — Add features

- Mattermost / Slack notifications (currently scaffolded as commented-out step)
- Multi-platform support (arm64 + amd64) — extend `platform` input
- Vault drift check workflow (separate, called pre-flight before stg)
- Scheduled "forgotten RC" reminder (cron weekly)

### Option 4 — Polish docs

- Update README.md to reflect latest state
- Add screenshots to ADOPTION.md
- Translate ADOPTION.md to Indonesian (parts of it already mixed)

---

## Quick commands

### Push pending commits
```bash
git push origin main
```

### Run automated tests
```bash
chmod +x tests/e2e-test.sh
./tests/e2e-test.sh                 # full ~10 min
./tests/e2e-test.sh --only=drill1   # specific drill
./tests/e2e-test.sh --cleanup-only  # reset state only
```

### Manual cleanup (full reset)
```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# Delete tags
git tag -l 'v*' | xargs -I {} git push origin --delete {}
git tag -l 'v*' | xargs git tag -d

# Close pending issues
gh issue list --label pending-prod-deploy --json number --jq '.[].number' \
  | xargs -I {} gh issue close {} --reason not_planned

# Delete releases
gh release list --json tagName --jq '.[].tagName' \
  | xargs -I {} gh release delete {} --yes --cleanup-tag

# Delete hotfix/release branches
git branch -r | grep -E 'origin/(hotfix|release)/' | sed 's|origin/||' \
  | xargs -I {} git push origin --delete {}

# Delete deployments (API only — UI doesn't have delete button)
gh api "repos/$REPO/deployments?per_page=100" --paginate --jq '.[].id' | while read -r ID; do
  gh api -X POST "repos/$REPO/deployments/$ID/statuses" -f state=inactive >/dev/null 2>&1
  gh api -X DELETE "repos/$REPO/deployments/$ID"
done
```

### Add dummy commits for testing
```bash
echo "" >> README.md && git commit -am "feat: test commit 1"
echo "" >> README.md && git commit -am "fix: test commit 2"
git push
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
- Always commit work-in-progress (so user can push from terminal)

---

## Reading order for context

1. **HANDOFF.md** (this file) — overview + state
2. **ADOPTION.md** — full strategy explanation + customization checklist
3. **TEST_SCENARIOS.md** — 23 manual test drills
4. **tests/README.md** — automated test usage
5. **.github/workflows/release.yml** — main workflow (~700 lines, well-commented)
6. **.github/workflows/on-approve.yml** — approval handler (~250 lines)
7. **.github/workflows/prepare-branch.yml** — branch bootstrap (~150 lines)
