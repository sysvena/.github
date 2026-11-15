#!/usr/bin/env bash
# End-to-end test of a version of the sysvena gates on sysvena/gates-canary.
#
# Points the org ruleset `require-sysvena-gates-canary` at <commit>, opens test
# pull requests on the canary, checks what the gates report, and closes the
# pull requests and deletes their branches again. The commit may be on a PR
# branch, so a change can be tested before it is merged.
#
# Usage: tests/e2e/gates-e2e.sh <commit of sysvena/.github>
# Needs: gh logged in as an org owner (scopes repo, admin:org and workflow), jq.
# The production ruleset `require-sysvena-gates` is not changed.
# The whole body is one { ...; exit; } group: bash reads it completely before
# it runs any of it, so editing this file while it runs (for example by
# switching branches in the same checkout) cannot change a running test.
{
set -euo pipefail

org=sysvena
source_repo=$org/.github
canary=$org/gates-canary
canary_ruleset=require-sysvena-gates-canary
gates=.github/workflows/sysvena-gates.yml
timeout_s=600

[ $# -eq 1 ] || { echo "Usage: $0 <commit of $source_repo>" >&2; exit 2; }
candidate=$(gh api "repos/$source_repo/commits/$1" --jq .sha)
stamp=$(date -u +%Y%m%d%H%M%S)
failures=0
prs=()
branches=()

log() { printf '%s\n' "$*"; }
pass() { log "  ok     - $*"; }
fail() { log "  not ok - $*"; failures=$((failures + 1)); }

# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
  local pr branch
  for pr in "${prs[@]}"; do
    gh pr close "$pr" -R "$canary" -c "End-to-end test of $source_repo@$candidate finished." > /dev/null 2>&1 || true
  done
  for branch in "${branches[@]}"; do
    gh api -X DELETE "repos/$canary/git/refs/heads/$branch" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# --- Point the canary ruleset at the candidate --------------------------------
ruleset_id=$(gh api "orgs/$org/rulesets" --jq ".[] | select(.name == \"$canary_ruleset\") | .id")
[ -n "$ruleset_id" ] || { echo "Ruleset $canary_ruleset not found" >&2; exit 2; }
gh api "orgs/$org/rulesets/$ruleset_id" \
  | jq --arg sha "$candidate" '{name, target, enforcement, conditions, bypass_actors,
      rules: [.rules[] | if .type == "workflows"
        then .parameters.workflows |= map(del(.ref) | .sha = $sha) else . end]}' \
  | gh api -X PUT "orgs/$org/rulesets/$ruleset_id" --input - > /dev/null
pinned=$(gh api "orgs/$org/rulesets/$ruleset_id" --jq '.rules[] | select(.type == "workflows") | .parameters.workflows[0].sha')
[ "$pinned" = "$candidate" ] || { echo "Ruleset $canary_ruleset is at $pinned, not $candidate" >&2; exit 1; }
log "Testing $source_repo@$candidate on $canary (ruleset $canary_ruleset)."

main_sha=$(gh api "repos/$canary/git/ref/heads/main" --jq .object.sha)
node_wanted=$(gh api "repos/$canary/contents/.nvmrc?ref=$main_sha" --jq .content | base64 -d | tr -d '[:space:]')
gh api "repos/$canary/labels/bug" > /dev/null 2>&1 \
  || gh api -X POST "repos/$canary/labels" -f name=bug -f color=d73a4a > /dev/null

# --- Helpers ------------------------------------------------------------------
# open_pr <n> <title> <path=content>...: branch from main, one commit per file,
# PR. Sets PR_NUMBER and PR_SHA (globals, so the cleanup list stays in this
# shell; do not call it in a subshell).
open_pr() {
  local n=$1 title=$2 branch="e2e/$stamp/$1" spec path
  shift 2
  gh api -X POST "repos/$canary/git/refs" -f "ref=refs/heads/$branch" -f "sha=$main_sha" > /dev/null
  branches+=("$branch")
  for spec in "$@"; do
    path=${spec%%=*}
    gh api -X PUT "repos/$canary/contents/$path" -f "message=test: e2e $stamp $n" -f "branch=$branch" \
      -f "content=$(printf '%s\n' "${spec#*=}" | base64 | tr -d '\n')" > /dev/null
  done
  PR_SHA=$(gh api "repos/$canary/git/ref/heads/$branch" --jq .object.sha)
  PR_NUMBER=$(gh api -X POST "repos/$canary/pulls" -f "title=$title" -f "head=$branch" -f base=main \
    -f "body=End-to-end test of $source_repo@$candidate. Closed automatically." --jq .number)
  prs+=("$PR_NUMBER")
}

# wait_run <head sha> <attempt>: waits for that attempt of the gates run to
# complete; prints the run id.
wait_run() {
  local sha=$1 attempt=$2 deadline=$((SECONDS + timeout_s)) run state
  while [ $SECONDS -lt $deadline ]; do
    run=$(gh api "repos/$canary/actions/runs?head_sha=$sha" \
      --jq '[.workflow_runs[] | select(.path == "'"$gates"'")][0].id // empty')
    if [ -n "$run" ]; then
      state=$(gh api "repos/$canary/actions/runs/$run" --jq '"\(.run_attempt) \(.status)"')
      if [ "$state" = "$attempt completed" ]; then printf '%s\n' "$run"; return; fi
    fi
    sleep 10
  done
  echo "Timed out waiting for attempt $attempt of the gates run on $sha" >&2
  return 1
}

# rerun <run id>: starts the next attempt; prints its number.
rerun() {
  local attempt
  attempt=$(gh api "repos/$canary/actions/runs/$1" --jq .run_attempt)
  gh api -X POST "repos/$canary/actions/runs/$1/rerun" > /dev/null
  printf '%s\n' $((attempt + 1))
}

# job_log <run id> <attempt> <job name>: prints the job's log without timestamps.
job_log() {
  local id
  id=$(gh api "repos/$canary/actions/runs/$1/attempts/$2/jobs" --jq ".jobs[] | select(.name == \"$3\") | .id")
  gh api --allow-escape-sequences "repos/$canary/actions/jobs/$id/logs" \
    | sed -E 's/^[0-9T:.-]+Z //; s/\x1b\[[0-9;]*m//g'
}

job_result() { # <run id> <attempt> <job name>
  gh api "repos/$canary/actions/runs/$1/attempts/$2/jobs" --jq ".jobs[] | select(.name == \"$3\") | .conclusion"
}

# check <description> <command...>: one test result, from the command's status.
check() {
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}

# expect <label> <run id> <attempt> <PR title> <changes> [message the changes job prints]
# Checks job results and what every run must show: the candidate version, the
# canary's Node version and the lessons check. Dependency review must succeed
# unless DR_WANT/DR_MESSAGE say otherwise (set them for one call only).
expect() {
  local label=$1 run=$2 attempt=$3 want_title=$4 want_changes=$5 message=${6:-}
  local want_dr=${DR_WANT:-success} dr_message=${DR_MESSAGE:-}
  local title changes repo dr detect_log changes_log repo_log dr_log
  title=$(job_result "$run" "$attempt" "PR title")
  changes=$(job_result "$run" "$attempt" "Changeset and regression test")
  repo=$(job_result "$run" "$attempt" "Repo checks")
  dr=$(job_result "$run" "$attempt" "Dependency review")
  check "$label: dependency review $want_dr (got $dr)" [ "$dr" = "$want_dr" ]
  if [ -n "$dr_message" ]; then
    dr_log=$(job_log "$run" "$attempt" "Dependency review")
    check "$label: dependency review says \"$dr_message\"" grep -qF -- "$dr_message" <<< "$dr_log"
  fi
  detect_log=$(job_log "$run" "$attempt" "Detect checks")
  changes_log=$(job_log "$run" "$attempt" "Changeset and regression test")
  repo_log=$(job_log "$run" "$attempt" "Repo checks")
  check "$label: PR title $want_title (got $title)" [ "$title" = "$want_title" ]
  check "$label: changes $want_changes (got $changes)" [ "$changes" = "$want_changes" ]
  if [ -n "$message" ]; then
    check "$label: changes says \"$message\"" grep -qF -- "$message" <<< "$changes_log"
  fi
  check "$label: ran $candidate" grep -qF "sysvena gates version: $candidate" <<< "$detect_log"
  check "$label: repo checks success (got $repo)" [ "$repo" = success ]
  check "$label: Node v$node_wanted from .nvmrc" grep -qx "Node v$node_wanted" <<< "$repo_log"
  check "$label: lessons check ran" grep -qF "check-lessons:" <<< "$repo_log"
}

# wait_pr_state <pr> <jq filter that must be true>: waits until the API shows it.
wait_pr_state() {
  local deadline=$((SECONDS + 60))
  until [ "$(gh api "repos/$canary/pulls/$1" --jq "$2")" = true ]; do
    [ $SECONDS -lt $deadline ] || { echo "PR $1 never matched $2" >&2; return 1; }
    sleep 2
  done
}

changeset() { printf '.changeset/e2e-%s-%s.md=---\n---\n\nEnd-to-end test.' "$stamp" "$1"; }

# --- Scenarios ----------------------------------------------------------------
log "1. Valid change"
open_pr 1 "feat: e2e valid change" "src/e2e-$stamp-1.ts=export const x = 1" "$(changeset 1)"
run=$(wait_run "$PR_SHA" 1)
expect "1" "$run" 1 success success "Changeset present."

log "2. Bug fix: title type fix, then title edit, then label bug (live PR data)"
open_pr 2 "fix: e2e fix without a test" "src/e2e-$stamp-2.ts=export const x = 2" "$(changeset 2)"
pr2=$PR_NUMBER sha2=$PR_SHA
run2=$(wait_run "$sha2" 1)
expect "2a fix title" "$run2" 1 success failure "A bug fix (title type 'fix')"
gh api -X PATCH "repos/$canary/pulls/$pr2" -f "title=feat: e2e fix without a test" > /dev/null
wait_pr_state "$pr2" '.title == "feat: e2e fix without a test"'
attempt=$(rerun "$run2"); wait_run "$sha2" "$attempt" > /dev/null
expect "2b title edited, re-run" "$run2" "$attempt" success success
gh api -X POST "repos/$canary/issues/$pr2/labels" -f "labels[]=bug" > /dev/null
wait_pr_state "$pr2" 'any(.labels[]; .name == "bug")'
attempt=$(rerun "$run2"); wait_run "$sha2" "$attempt" > /dev/null
expect "2c label bug, re-run" "$run2" "$attempt" success failure "A bug fix (label 'bug')"

log "3. Title without a type"
open_pr 3 "Add an e2e file" "src/e2e-$stamp-3.ts=export const x = 3" "$(changeset 3)"
run=$(wait_run "$PR_SHA" 1)
expect "3" "$run" 1 failure success

log "4. Shipped file without a changeset"
open_pr 4 "feat: e2e change without a changeset" "src/e2e-$stamp-4.ts=export const x = 4"
run=$(wait_run "$PR_SHA" 1)
expect "4" "$run" 1 success failure "adds no changeset"

# package_json <dependencies JSON> <devDependencies JSON>
package_json() { printf 'package.json={"name": "gates-canary-e2e", "private": true, "dependencies": %s, "devDependencies": %s}' "$1" "$2"; }

log "5. Development dependency with a known vulnerability (lodash 4.17.20)"
open_pr 5 "feat: e2e vulnerable dev dependency" "$(package_json '{}' '{"lodash": "4.17.20"}')" "$(changeset 5)"
run=$(wait_run "$PR_SHA" 1)
DR_WANT=failure DR_MESSAGE=GHSA-35jh-r3h4-6jhm expect "5" "$run" 1 success success

log "6. Dependency with a licence outside the allow list (axe-core, MPL-2.0)"
open_pr 6 "feat: e2e dependency with a reviewed-only licence" "$(package_json '{"axe-core": "4.11.1"}' '{}')" "$(changeset 6)"
run=$(wait_run "$PR_SHA" 1)
DR_WANT=failure DR_MESSAGE="Dependency review detected incompatible licenses." expect "6" "$run" 1 success success

log "7. Dependency with no detected licence (an action from the unlicensed canary)"
# Never runs (workflow_dispatch only); the dependency graph still reads `uses:`.
open_pr 7 "ci: e2e action with no licence" \
  ".github/workflows/e2e-$stamp.yml=on: workflow_dispatch
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: $canary@$main_sha"
run=$(wait_run "$PR_SHA" 1)
DR_WANT=failure DR_MESSAGE="Added dependencies with no detected licence." expect "7" "$run" 1 success success

log "8. Dependency with an allowed licence and no known vulnerability (ms 2.1.3, MIT)"
open_pr 8 "feat: e2e clean dependency" "$(package_json '{"ms": "2.1.3"}' '{}')" "$(changeset 8)"
run=$(wait_run "$PR_SHA" 1)
DR_MESSAGE="Every added dependency has a detected licence or a reviewed exception." expect "8" "$run" 1 success success

log "9. Own package with a reviewed exception (@sysvena/agent-rules, no licence data)"
# In a nested manifest: a root package.json depending on it would also turn on
# the agent rules check, which the canary does not use yet.
open_pr 9 "feat: e2e own package" \
  'e2e/package.json={"name": "gates-canary-e2e", "private": true, "devDependencies": {"@sysvena/agent-rules": "0.3.0"}}' \
  "$(changeset 9)"
run=$(wait_run "$PR_SHA" 1)
DR_MESSAGE="Every added dependency has a detected licence or a reviewed exception." expect "9" "$run" 1 success success

log ""
if [ "$failures" -eq 0 ]; then
  log "PASS: $source_repo@$candidate behaves as expected on $canary."
else
  log "FAIL: $failures check(s) failed for $source_repo@$candidate."
  exit 1
fi
exit
}
