#!/usr/bin/env bash
# Moves every sysvena repository to a new version of the gates.
#
# The commit must be on main of sysvena/.github. The script first runs the
# end-to-end test (tests/e2e/gates-e2e.sh) on exactly that commit, and moves the
# production ruleset `require-sysvena-gates` to it only when the test passes.
# It prints the previous commit and the command to roll back to it.
#
# Usage: scripts/gates-promote.sh <commit on main of sysvena/.github>
#        scripts/gates-promote.sh --rollback <commit>
#
# --rollback skips the end-to-end test: it is for going back to a version that
# was in production before (an older version can fail checks that the test
# added later, such as the gates version line).
# Needs: gh logged in as an org owner (scopes repo, admin:org and workflow), jq.
# The whole body is one { ...; exit; } group: bash reads it completely before
# it runs any of it, so editing this file while it runs (for example by
# switching branches in the same checkout) cannot change a running test.
{
set -euo pipefail
# shellcheck source=scripts/lib/gh-read.sh
. "$(dirname "$0")/lib/gh-read.sh"

org=sysvena
source_repo=$org/.github
production_ruleset=require-sysvena-gates

rollback=false
if [ "${1:-}" = --rollback ]; then
  rollback=true
  shift
fi
[ $# -eq 1 ] || { echo "Usage: $0 [--rollback] <commit on main of $source_repo>" >&2; exit 2; }
commit=$(gh_read "repos/$source_repo/commits/$1" --jq .sha)

# On main: main is identical to the commit or ahead of it.
status=$(gh_read "repos/$source_repo/compare/$commit...main" --jq .status)
case "$status" in
  identical | ahead) ;;
  *) echo "$commit is not on main of $source_repo (main is $status)" >&2; exit 1 ;;
esac

ruleset_id=$(gh_read "orgs/$org/rulesets" --jq ".[] | select(.name == \"$production_ruleset\") | .id")
[ -n "$ruleset_id" ] || { echo "Ruleset $production_ruleset not found" >&2; exit 2; }
previous=$(gh_read "orgs/$org/rulesets/$ruleset_id" --jq '.rules[] | select(.type == "workflows") | .parameters.workflows[0].sha // .parameters.workflows[0].ref')
if [ "$previous" = "$commit" ]; then
  echo "$production_ruleset is already at $commit."
  exit 0
fi

if [ "$rollback" = true ]; then
  echo "Rolling back to $commit without the end-to-end test."
else
  "$(dirname "$0")/../tests/e2e/gates-e2e.sh" "$commit"
fi

gh_read "orgs/$org/rulesets/$ruleset_id" \
  | jq --arg sha "$commit" '{name, target, enforcement, conditions, bypass_actors,
      rules: [.rules[] | if .type == "workflows"
        then .parameters.workflows |= map(del(.ref) | .sha = $sha) else . end]}' \
  | gh api -X PUT "orgs/$org/rulesets/$ruleset_id" --input - > /dev/null
now=$(gh_read "orgs/$org/rulesets/$ruleset_id" --jq '.rules[] | select(.type == "workflows") | .parameters.workflows[0].sha')
[ "$now" = "$commit" ] || { echo "$production_ruleset is at $now, not $commit" >&2; exit 1; }

echo "$production_ruleset moved from $previous to $commit."
echo "Roll back: $0 --rollback $previous"
exit
}
