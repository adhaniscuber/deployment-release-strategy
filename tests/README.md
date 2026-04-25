# Automated E2E Tests

Bash-based automation untuk validate v6 release strategy end-to-end.

## Prerequisites

```bash
# 1. gh CLI installed + authenticated
gh auth status

# 2. Run from repo root
cd /Users/adhan/ctlyst/github-deployments-demo

# 3. Make script executable
chmod +x tests/e2e-test.sh
```

## Usage

```bash
# Run all happy-path drills (drill 1-4) + selected negative tests (drill 5)
./tests/e2e-test.sh

# Run specific drill only
./tests/e2e-test.sh --only=drill1
./tests/e2e-test.sh --only=drill2
./tests/e2e-test.sh --only=drill3
./tests/e2e-test.sh --only=drill4
./tests/e2e-test.sh --only=drill5

# Skip cleanup after tests (inspect state manually)
./tests/e2e-test.sh --skip-cleanup

# Just clean up state (no tests)
./tests/e2e-test.sh --cleanup-only

# Help
./tests/e2e-test.sh --help
```

## What it tests

| Drill | Scenarios |
|---|---|
| **Drill 1** | dev → stg → re-cut → prod-build → /approve → prod-deploy |
| **Drill 2** | prepare hotfix → push fix → stg → prod-build → /approve → prod-deploy |
| **Drill 3** | rollback to v0.0.1, verify Latest badge moves |
| **Drill 4** | prepare release branch → cherry-pick → stg → prod-build → /approve → prod-deploy |
| **Drill 5** | negative: rollback to non-existent tag, duplicate GA tag |

## Expected runtime

| Drill | Time |
|---|---|
| Drill 1 | ~2 min (5 dispatches, polling) |
| Drill 2 | ~2 min |
| Drill 3 | ~30 sec |
| Drill 4 | ~2 min |
| Drill 5 | ~1 min |
| **Full run** | **~7-10 min** |

## Output example

```
╔═══════════════════════════════════════════════════════════╗
║  v6 Release Strategy — Automated E2E Test                ║
║  Repo: adhaniscuber/deployment-release-strategy          ║
╚═══════════════════════════════════════════════════════════╝
▸ Cleaning up state...
  ✓ Cleanup done
▸ Adding 3 dummy commits...
  ✓ added 3 dummy commits

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Drill 1 — Regular cycle (dev → stg → prod)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
▸ Step 1.1: Dispatch dev
  ✓ dev run completed (run 1234567890)
  ✓ deployment exists for env=development
▸ Step 1.2: Dispatch stg
  ✓ stg run completed (run 1234567891)
  ✓ tag 'v0.0.1-rc' exists
  ✓ deployment exists for env=staging
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Passed: 28
  Failed: 0
  Skipped: 0
```

## Limitations

**What's automated:**
- Workflow dispatches (release, prepare-branch)
- Wait for run completion
- Tag/branch existence assertions
- GitHub Release/Issue/Deployment record assertions
- /approve via comment

**What's NOT automated (still manual via TEST_SCENARIOS.md):**
- Issue body content verification (changelog format, metadata block)
- Run-name UI inspection
- Stg freshness guard test (drill 5.2 — needs precise timing)
- Unauthorized /approve (needs different user)
- Unauthorized rollback (needs approvers.yml edit)
- /reject flow (no opposite of approve auto-test)

For these, follow `TEST_SCENARIOS.md` manually.

## CI integration (optional)

Add `.github/workflows/e2e-test-cron.yml` to run weekly:

```yaml
name: E2E Test (Weekly)
on:
  schedule:
    - cron: '0 6 * * 0'  # Sunday 06:00 UTC
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: chmod +x tests/e2e-test.sh
      - run: ./tests/e2e-test.sh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

⚠️ Caution: e2e-test creates real tags/releases/deployments. CI run akan numpuk artifacts. Cleanup ensures fresh state but Deployments tetap accumulate (can't bulk-delete).

## Troubleshooting

**"Dispatch didn't start within 30s":**
- Workflow disabled? Check Actions → Release → "Enable workflow"
- Wrong branch ref? Workflow dispatched against `main`, must exist

**"Workflow timeout":**
- POLL_TIMEOUT default 180s. Increase in script if your workflows slower.
- Check Actions tab for stuck run.

**"chain dispatch didn't start":**
- Permission issue? Verify `Allow GitHub Actions to create and approve pull requests` enabled.
- on-approve.yml: check that `event_type: 'release'` matches release.yml `repository_dispatch.types: [release]`.

**Lock file issues during tests:**
- Script tidak handle git lock files. Kalau ada git operation lain bareng, bisa conflict.
- Run script standalone (no other git operations).

## Why bash + gh CLI?

- ✅ Zero dependencies (gh CLI standard)
- ✅ Cross-platform (macOS, Linux, WSL)
- ✅ Easy to read + modify
- ✅ Same workflow as manual test (just automated)

Alternative considered: Python (more robust assertions), Node.js (rich test framework), `act` (local emulation). Bash chosen for simplicity + zero install.
