#!/usr/bin/env bash
# e2e-test.sh — Automated end-to-end testing for v6 release strategy
#
# Usage:
#   ./tests/e2e-test.sh                    # run all happy-path scenarios
#   ./tests/e2e-test.sh --only=drill1      # run specific drill
#   ./tests/e2e-test.sh --cleanup-only     # just clean up state
#   ./tests/e2e-test.sh --skip-cleanup     # don't clean state after tests
#
# Prerequisites:
#   - gh CLI authenticated (gh auth status)
#   - Run from repo root
#   - Workflows already pushed to main
set -euo pipefail

# ───── Config ─────────────────────────────────────────────────────────
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
POLL_INTERVAL=5      # seconds between status polls
POLL_TIMEOUT=180     # max seconds to wait for a workflow run

ONLY=""
SKIP_CLEANUP=false
CLEANUP_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --only=*)        ONLY="${arg#--only=}" ;;
    --skip-cleanup)  SKIP_CLEANUP=true ;;
    --cleanup-only)  CLEANUP_ONLY=true ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
  esac
done

# ───── Output ─────────────────────────────────────────────────────────
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
PASS=0; FAIL=0; SKIP=0; FAILED_TESTS=()

log()       { echo "${BLUE}▸${RESET} $*"; }
ok()        { echo "  ${GREEN}✓${RESET} $*"; PASS=$((PASS+1)); }
fail()      { echo "  ${RED}✗${RESET} $*"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$*"); }
skip()      { echo "  ${YELLOW}-${RESET} $*"; SKIP=$((SKIP+1)); }
section()   { echo; echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; echo "${BLUE}$*${RESET}"; echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ───── Helpers ────────────────────────────────────────────────────────

# Dispatch workflow and return run ID (waits for run to appear)
dispatch_and_wait_for_run() {
  local workflow="$1"; shift
  local fields=("$@")

  # Get current latest run ID before dispatch
  local before_id
  before_id=$(gh run list --workflow="$workflow" --limit=1 --json databaseId --jq '.[0].databaseId // 0')

  # Dispatch
  local field_args=()
  for f in "${fields[@]}"; do field_args+=(-f "$f"); done
  gh workflow run "$workflow" --ref main "${field_args[@]}" >/dev/null

  # Poll for new run
  local elapsed=0
  while [[ $elapsed -lt 30 ]]; do
    local current_id
    current_id=$(gh run list --workflow="$workflow" --limit=1 --json databaseId --jq '.[0].databaseId // 0')
    if [[ "$current_id" -gt "$before_id" ]]; then
      echo "$current_id"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  # Caller checks for "0" sentinel; return 0 so `var=$(...)` under `set -e`
  # doesn't abort the script on timeout.
  echo "0"
}

# Wait for run to complete, return status (success/failure/cancelled)
wait_for_completion() {
  local run_id="$1"
  local elapsed=0
  while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
    local status conclusion
    read -r status conclusion < <(gh run view "$run_id" --json status,conclusion --jq '"\(.status) \(.conclusion // "")"')
    if [[ "$status" == "completed" ]]; then
      echo "$conclusion"
      return 0
    fi
    sleep $POLL_INTERVAL
    elapsed=$((elapsed+POLL_INTERVAL))
  done
  echo "timeout"
}

# Wait for chain-dispatched run (released after on-approve dispatch)
wait_for_new_run_after() {
  local workflow="$1"
  local after_ts="$2"     # epoch seconds
  local elapsed=0
  while [[ $elapsed -lt 30 ]]; do
    local run_data
    run_data=$(gh run list --workflow="$workflow" --limit=1 --json databaseId,createdAt --jq '.[0]')
    local run_id created_at
    run_id=$(echo "$run_data" | jq -r '.databaseId')
    created_at=$(echo "$run_data" | jq -r '.createdAt')
    local created_ts
    # NOTE: -u is critical on macOS — without it, `date -j -f` parses the
    # timestamp as local time even though the input has a Z suffix.
    created_ts=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || \
                 date -d "$created_at" +%s 2>/dev/null || echo 0)
    if [[ "$created_ts" -gt "$after_ts" ]]; then
      echo "$run_id"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  echo "0"
}

assert_tag_exists() {
  git fetch --tags --quiet
  if git rev-parse --verify "refs/tags/$1" >/dev/null 2>&1; then
    ok "tag '$1' exists"
  else
    fail "tag '$1' missing"
  fi
}

assert_tag_missing() {
  git fetch --tags --quiet
  if git rev-parse --verify "refs/tags/$1" >/dev/null 2>&1; then
    fail "tag '$1' should NOT exist (but it does)"
  else
    ok "tag '$1' correctly missing"
  fi
}

assert_branch_exists() {
  git fetch --quiet
  if git ls-remote --heads origin "$1" | grep -q "$1"; then
    ok "branch '$1' exists"
  else
    fail "branch '$1' missing"
  fi
}

assert_release_exists() {
  if gh release view "$1" >/dev/null 2>&1; then
    ok "release '$1' exists"
  else
    fail "release '$1' missing"
  fi
}

assert_release_title_contains() {
  local tag="$1" needle="$2"
  local title
  title=$(gh release view "$tag" --json name --jq '.name' 2>/dev/null || echo "")
  if [[ "$title" == *"$needle"* ]]; then
    ok "release '$tag' title contains '$needle'"
  else
    fail "release '$tag' title is '$title', expected to contain '$needle'"
  fi
}

assert_deployment_exists_for_env() {
  local env="$1"
  local count
  count=$(gh api "repos/$REPO/deployments?environment=$env&per_page=1" --jq 'length')
  if [[ "$count" -gt 0 ]]; then
    ok "deployment exists for env=$env"
  else
    fail "no deployment for env=$env"
  fi
}

assert_issue_open_for_version() {
  local version="$1"
  local count
  count=$(gh issue list --label pending-prod-deploy --search "$version in:title" --state=open --json number --jq 'length')
  if [[ "$count" -gt 0 ]]; then
    ok "open approval issue exists for $version"
  else
    fail "no open approval issue for $version"
  fi
}

assert_issue_closed_for_version() {
  local version="$1"
  local count
  count=$(gh issue list --label pending-prod-deploy --search "$version in:title" --state=closed --json number --jq 'length')
  if [[ "$count" -gt 0 ]]; then
    ok "approval issue for $version is closed"
  else
    fail "approval issue for $version not closed"
  fi
}

approve_issue_for_version() {
  local version="$1"
  local issue_num
  issue_num=$(gh issue list --label pending-prod-deploy --search "$version in:title" --state=open --json number --jq '.[0].number')
  if [[ -z "$issue_num" || "$issue_num" == "null" ]]; then
    fail "no open issue to approve for $version"
    return 1
  fi
  gh issue comment "$issue_num" --body "/approve"
  ok "commented /approve on issue #$issue_num"
}

# ───── Cleanup ────────────────────────────────────────────────────────
cleanup() {
  log "Cleaning up state..."
  # Delete tags
  git tag -l 'v*' | xargs -I {} git push origin --delete {} 2>/dev/null || true
  git tag -l 'v*' | xargs git tag -d 2>/dev/null || true
  # Close issues
  gh issue list --label pending-prod-deploy --json number --jq '.[].number' \
    | xargs -I {} gh issue close {} --reason not_planned 2>/dev/null || true
  # Delete releases
  gh release list --json tagName --jq '.[].tagName' \
    | xargs -I {} gh release delete {} --yes --cleanup-tag 2>/dev/null || true
  # Delete branches (prune stale refs first; awk strips whitespace cleanly)
  # Tolerant of transient SSH/network blips — cleanup must not abort the run.
  git fetch --prune --quiet 2>/dev/null || true
  git branch -r | awk '/origin\/(hotfix|release)\//{sub(/^[[:space:]]*origin\//,""); print}' \
    | xargs -I {} git push origin --delete {} 2>/dev/null || true
  # Delete deployments (must set inactive first)
  log "  Deleting GitHub Deployments..."
  local count=0
  while read -r deploy_id; do
    [[ -z "$deploy_id" ]] && continue
    gh api -X POST "repos/$REPO/deployments/$deploy_id/statuses" -f state=inactive >/dev/null 2>&1 || true
    gh api -X DELETE "repos/$REPO/deployments/$deploy_id" >/dev/null 2>&1 && count=$((count+1)) || true
  done < <(gh api "repos/$REPO/deployments?per_page=100" --paginate --jq '.[].id' 2>/dev/null)
  [[ $count -gt 0 ]] && echo "    ✓ Deleted $count deployments" || echo "    (no deployments to delete)"

  # Cancel any in-progress runs, then delete all workflow runs
  log "  Cancelling in-progress workflow runs..."
  while read -r run_id; do
    [[ -z "$run_id" ]] && continue
    gh run cancel "$run_id" >/dev/null 2>&1 || true
  done < <(gh run list --status in_progress --limit 50 --json databaseId --jq '.[].databaseId' 2>/dev/null)
  while read -r run_id; do
    [[ -z "$run_id" ]] && continue
    gh run cancel "$run_id" >/dev/null 2>&1 || true
  done < <(gh run list --status queued --limit 50 --json databaseId --jq '.[].databaseId' 2>/dev/null)

  log "  Deleting workflow runs..."
  count=0
  while read -r run_id; do
    [[ -z "$run_id" ]] && continue
    gh api -X DELETE "repos/$REPO/actions/runs/$run_id" >/dev/null 2>&1 && count=$((count+1)) || true
  done < <(gh run list --limit 200 --json databaseId --jq '.[].databaseId' 2>/dev/null)
  [[ $count -gt 0 ]] && echo "    ✓ Deleted $count workflow runs" || echo "    (no workflow runs to delete)"

  ok "Cleanup done"
}

# Retry a git push up to 3 times — SSH connections to github.com flake.
git_push_retry() {
  local attempt=1
  while (( attempt <= 3 )); do
    if git push "$@"; then return 0; fi
    echo "  ${YELLOW}~${RESET} git push failed (attempt $attempt/3), retrying in 5s..."
    sleep 5
    attempt=$((attempt+1))
  done
  return 1
}

add_dummy_commits() {
  local count="${1:-3}"
  for i in $(seq 1 "$count"); do
    echo "" >> README.md
    git -c user.name="$(git config user.name || echo bot)" \
        -c user.email="$(git config user.email || echo bot@example.com)" \
        commit -am "test: e2e dummy commit $i ($(date +%s))"
  done
  git_push_retry origin main
  ok "added $count dummy commits"
}

# ───── Drills ─────────────────────────────────────────────────────────

drill1_regular_cycle() {
  section "Drill 1 — Regular cycle (dev → stg → prod)"

  log "Step 1.1: Dispatch dev"
  local run_id
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=dev" "from=" "bump=patch")
  [[ "$run_id" == "0" ]] && { fail "dev dispatch didn't start"; return 1; }
  local result; result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "dev run completed (run $run_id)" || { fail "dev run failed: $result"; return 1; }
  assert_deployment_exists_for_env "development"

  log "Step 1.2: Dispatch stg"
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=stg" "from=" "bump=patch")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "stg run completed (run $run_id)" || { fail "stg run failed: $result"; return 1; }
  assert_tag_exists "v0.0.1-rc"
  assert_deployment_exists_for_env "staging"

  log "Step 1.3: Stg re-cut"
  add_dummy_commits 1
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=stg" "from=" "bump=patch")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "stg re-cut completed" || fail "stg re-cut failed: $result"

  log "Step 1.4: Dispatch prod-build"
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=prod-build" "from=v0.0.1-rc" "bump=patch")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prod-build run completed" || { fail "prod-build failed: $result"; return 1; }
  assert_issue_open_for_version "v0.0.1"

  log "Step 1.5: Approve via /approve"
  local approve_ts; approve_ts=$(date +%s)
  approve_issue_for_version "v0.0.1"

  # Wait for chain dispatch
  log "Waiting for chain dispatch (prod-deploy)..."
  sleep 10
  run_id=$(wait_for_new_run_after "release.yml" "$approve_ts")
  [[ "$run_id" == "0" ]] && { fail "chain dispatch didn't start"; return 1; }
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prod-deploy chain completed" || fail "prod-deploy chain failed: $result"

  # Final checks
  sleep 3
  assert_tag_exists "v0.0.1"
  assert_release_exists "v0.0.1"
  assert_deployment_exists_for_env "production"
  assert_issue_closed_for_version "v0.0.1"
}

drill2_hotfix() {
  section "Drill 2 — Hotfix flow"

  log "Step 2.1: Dispatch prepare-branch (hotfix)"
  local run_id; run_id=$(dispatch_and_wait_for_run "prepare-branch.yml" "kind=hotfix" "base=" "force=false")
  [[ "$run_id" == "0" ]] && { fail "prepare-branch dispatch didn't start"; return 1; }
  local result; result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prepare-branch completed" || { fail "prepare-branch failed: $result"; return 1; }
  assert_branch_exists "hotfix/v0.0.2"

  log "Step 2.2: Push fix commit to hotfix branch"
  git fetch --quiet
  git checkout hotfix/v0.0.2 2>/dev/null
  echo "" >> README.md
  git -c user.name="$(git config user.name || echo bot)" \
      -c user.email="$(git config user.email || echo bot@example.com)" \
      commit -am "fix: e2e hotfix commit"
  git_push_retry origin hotfix/v0.0.2
  git checkout main 2>/dev/null
  ok "pushed hotfix commit"

  log "Step 2.3: Dispatch stg from hotfix branch"
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=stg" "from=hotfix/v0.0.2" "bump=patch")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "stg hotfix completed" || { fail "stg hotfix failed: $result"; return 1; }
  assert_tag_exists "v0.0.2-rc"

  log "Step 2.4: Dispatch prod-build for hotfix"
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=prod-build" "from=v0.0.2-rc" "bump=patch")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prod-build hotfix completed" || { fail "prod-build hotfix failed: $result"; return 1; }
  assert_issue_open_for_version "v0.0.2"

  log "Step 2.5: Approve hotfix"
  local approve_ts; approve_ts=$(date +%s)
  approve_issue_for_version "v0.0.2"
  sleep 10
  run_id=$(wait_for_new_run_after "release.yml" "$approve_ts")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prod-deploy hotfix completed" || fail "prod-deploy hotfix failed: $result"

  sleep 3
  assert_tag_exists "v0.0.2"
  assert_release_exists "v0.0.2"
  assert_release_title_contains "v0.0.2" "HOTFIX"
}

drill3_rollback() {
  section "Drill 3 — Rollback"

  log "Step 3.1: Rollback to v0.0.1"
  local run_id; run_id=$(dispatch_and_wait_for_run "release.yml" "target=rollback" "from=v0.0.1" "bump=patch")
  [[ "$run_id" == "0" ]] && { fail "rollback dispatch didn't start"; return 1; }
  local result; result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "rollback completed" || { fail "rollback failed: $result"; return 1; }

  # Verify v0.0.1 marked as Latest
  local latest
  latest=$(gh release list --limit 5 --json tagName,isLatest --jq '[.[] | select(.isLatest == true)] | .[0].tagName')
  if [[ "$latest" == "v0.0.1" ]]; then
    ok "v0.0.1 marked as Latest after rollback"
  else
    fail "expected v0.0.1 as Latest, got '$latest'"
  fi
}

drill4_cherrypick() {
  section "Drill 4 — Cherry-pick release"

  log "Step 4.1: Dispatch prepare-branch (release)"
  local run_id; run_id=$(dispatch_and_wait_for_run "prepare-branch.yml" "kind=release" "base=" "force=false")
  local result; result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prepare-branch release completed" || { fail "prepare-branch release failed"; return 1; }
  assert_branch_exists "release/v0.1.0"

  log "Step 4.2: Cherry-pick a commit"
  git fetch --quiet
  add_dummy_commits 1
  local pick_sha; pick_sha=$(git rev-parse HEAD)
  git checkout release/v0.1.0 2>/dev/null
  git -c user.name="$(git config user.name || echo bot)" \
      -c user.email="$(git config user.email || echo bot@example.com)" \
      cherry-pick "$pick_sha" || true
  git_push_retry origin release/v0.1.0
  git checkout main 2>/dev/null
  ok "cherry-picked commit $pick_sha"

  log "Step 4.3: Dispatch stg from release branch"
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=stg" "from=release/v0.1.0" "bump=patch")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "stg cherrypick completed" || { fail "stg cherrypick failed"; return 1; }
  assert_tag_exists "v0.1.0-rc"

  log "Step 4.4: Dispatch prod-build for cherrypick"
  run_id=$(dispatch_and_wait_for_run "release.yml" "target=prod-build" "from=v0.1.0-rc" "bump=patch")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prod-build cherrypick completed" || { fail "prod-build cherrypick failed"; return 1; }

  log "Step 4.5: Approve cherrypick"
  local approve_ts; approve_ts=$(date +%s)
  approve_issue_for_version "v0.1.0"
  sleep 10
  run_id=$(wait_for_new_run_after "release.yml" "$approve_ts")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "success" ]] && ok "prod-deploy cherrypick completed" || fail "prod-deploy cherrypick failed"

  sleep 3
  assert_tag_exists "v0.1.0"
  assert_release_title_contains "v0.1.0" "CHERRYPICK"
}

drill5_negative_tests() {
  section "Drill 5 — Negative tests (selected)"

  log "Step 5.1: Rollback to non-existent tag (should fail)"
  local run_id; run_id=$(dispatch_and_wait_for_run "release.yml" "target=rollback" "from=v9.9.9" "bump=patch")
  local result; result=$(wait_for_completion "$run_id")
  [[ "$result" == "failure" ]] && ok "rollback to non-existent tag correctly blocked" \
                              || fail "expected failure, got '$result'"

  log "Step 5.2: GA tag already exists (re-trigger prod-deploy via repository_dispatch)"
  local before_ts; before_ts=$(date +%s)
  gh api "repos/$REPO/dispatches" -X POST \
    -f event_type=release \
    -f 'client_payload[target]=prod-deploy' \
    -f 'client_payload[from]=v0.0.1-rc' \
    -f 'client_payload[release_type]=regular' \
    -f 'client_payload[triggered_by]=e2e-test' >/dev/null
  sleep 10
  run_id=$(wait_for_new_run_after "release.yml" "$before_ts")
  result=$(wait_for_completion "$run_id")
  [[ "$result" == "failure" ]] && ok "duplicate GA tag correctly blocked" \
                              || fail "expected failure for duplicate tag, got '$result'"
}

# ───── Main ───────────────────────────────────────────────────────────

main() {
  echo "${BLUE}╔═══════════════════════════════════════════════════════════╗${RESET}"
  echo "${BLUE}║  v6 Release Strategy — Automated E2E Test                ║${RESET}"
  echo "${BLUE}║  Repo: ${REPO}${RESET}"
  echo "${BLUE}╚═══════════════════════════════════════════════════════════╝${RESET}"

  if $CLEANUP_ONLY; then cleanup; exit 0; fi

  cleanup
  add_dummy_commits 3

  case "$ONLY" in
    "")          drill1_regular_cycle; drill2_hotfix; drill3_rollback; drill4_cherrypick; drill5_negative_tests ;;
    drill1)      drill1_regular_cycle ;;
    drill2)      drill2_hotfix ;;
    drill3)      drill3_rollback ;;
    drill4)      drill4_cherrypick ;;
    drill5)      drill5_negative_tests ;;
    *)           echo "Unknown drill: $ONLY"; exit 1 ;;
  esac

  $SKIP_CLEANUP || cleanup

  # Summary
  echo
  echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo "${BLUE}Summary${RESET}"
  echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo "  ${GREEN}Passed: $PASS${RESET}"
  echo "  ${RED}Failed: $FAIL${RESET}"
  echo "  ${YELLOW}Skipped: $SKIP${RESET}"
  if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo
    echo "${RED}Failed assertions:${RESET}"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  fi

  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
}

main
