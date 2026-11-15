#!/usr/bin/env bash
# Tests for .github/workflows/sysvena-gates.yml.
#
# Runs the real `run:` blocks of the workflow (extracted with yq) against
# fixture pull requests, with a stub `gh` (tests/gates/stub/gh) that serves the
# fixture instead of the GitHub API. Needs bash, jq and yq v4 (mikefarah), all
# preinstalled on ubuntu-24.04 runners.
#
# Usage: tests/gates/run.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 2
workflow=.github/workflows/sysvena-gates.yml
stub="$root/tests/gates/stub"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0

# extract <job> <step name> <file>: writes the step's `run:` block to <file>.
extract() {
  yq ".jobs.\"$1\".steps[] | select(.name == \"$2\") | .run" "$workflow" > "$3"
  if [ ! -s "$3" ]; then
    echo "Cannot find step '$2' in job '$1' of $workflow" >&2
    exit 2
  fi
}
extract detect "Detect" "$tmp/detect.sh"
extract detect "Read the PR" "$tmp/read.sh"
extract pr-title "Check the PR title" "$tmp/title.sh"
extract changes "Check changed files" "$tmp/changes.sh"
extract changeset "Prepare the changeset check" "$tmp/cs-prepare.sh"
extract dependency-review "Prepare licence exceptions" "$tmp/dr-prepare.sh"
extract dependency-review "Check unknown and excepted licences" "$tmp/dr-check.sh"

report() { # <ok> <name> <detail>
  if [ "$1" = true ]; then
    passed=$((passed + 1))
    echo "ok     - $2"
  else
    failed=$((failed + 1))
    echo "not ok - $2"
    printf '%s\n' "$3" | sed 's/^/         /'
  fi
}

# pr_case <name> <expect title gate> <expect changes gate> <title> <labels> <files> [options]
#   labels:  comma-separated label names
#   files:   semicolon-separated "path status" pairs (status as in the API)
#   options: message=<text the changes gate must print>
pr_case() {
  local name=$1 want_title=$2 want_changes=$3 title=$4 labels=$5 files=$6
  shift 6
  local message="" opt
  for opt in "$@"; do
    case "$opt" in
      message=*) message=${opt#message=} ;;
      *) echo "Unknown option: $opt" >&2; exit 2 ;;
    esac
  done

  local fix="$tmp/fixture" work="$tmp/work"
  rm -rf "$fix" "$work"
  mkdir -p "$fix" "$work"
  jq -n --arg title "$title" --arg labels "$labels" \
    '{number: 1, state: "open", title: $title,
      labels: ($labels | split(",") | map(select(. != "")) | map({name: ., color: "ededed"}))}' \
    > "$fix/pr.json"
  jq -n --arg files "$files" \
    '$files | split(";") | map(select(. != "")) | map(split(" ") | {filename: .[0], status: .[1]})' \
    > "$fix/files.json"

  # Job `detect`, step "Read the PR": the snapshot both gates use.
  local snapshot
  if ! (cd "$work" && FIX="$fix" PATH="$stub:$PATH" REPO=o/r PR=1 GITHUB_OUTPUT="$work/output" \
    bash -e "$tmp/read.sh" > "$work/read.log" 2>&1); then
    report false "$name" "Read the PR failed: $(cat "$work/read.log")"
    return
  fi
  if [ "$(grep -c '^pr=' "$work/output")" != 1 ] || [ "$(wc -l < "$work/output")" != 1 ]; then
    report false "$name" "GITHUB_OUTPUT is not exactly one pr= line: $(cat "$work/output")"
    return
  fi
  snapshot=$(sed -n 's/^pr=//p' "$work/output")

  local got_title=pass got_changes=pass
  (cd "$work" && PR_SNAPSHOT="$snapshot" bash -e "$tmp/title.sh" > "$work/title.log" 2>&1) || got_title=fail
  (cd "$work" && FIX="$fix" PATH="$stub:$PATH" REPO=o/r PR=1 PR_SNAPSHOT="$snapshot" \
    bash -e "$tmp/changes.sh" > "$work/changes.log" 2>&1) || got_changes=fail

  local ok=true detail=""
  if [ "$got_title" != "$want_title" ]; then
    ok=false
    detail+="PR title gate: got $got_title, want $want_title"$'\n'"$(cat "$work/title.log")"$'\n'
  fi
  if [ "$got_changes" != "$want_changes" ]; then
    ok=false
    detail+="Changes gate: got $got_changes, want $want_changes"$'\n'"$(cat "$work/changes.log")"$'\n'
  fi
  if [ -n "$message" ] && ! grep -qF -- "$message" "$work/changes.log"; then
    ok=false
    detail+="Changes gate did not print: $message"$'\n'"$(cat "$work/changes.log")"$'\n'
  fi
  report "$ok" "$name" "$detail"
}

# detect_case <name> <expected outputs, space-separated> <files to create...>
detect_case() {
  local name=$1 want=$2
  shift 2
  local work="$tmp/detect"
  rm -rf "$work"
  mkdir -p "$work"
  local f
  for f in "$@"; do
    case "$f" in
      package.json:*) printf '%s\n' "${f#package.json:}" > "$work/package.json" ;;
      *) mkdir -p "$work/$(dirname "$f")"; : > "$work/$f" ;;
    esac
  done
  local got
  got=$(cd "$work" && GITHUB_OUTPUT="$work/.output" bash -e "$tmp/detect.sh" > /dev/null 2>&1 \
    && tr '\n' ' ' < "$work/.output" | sed 's/ $//')
  if [ "$got" = "$want" ]; then
    report true "$name" ""
  else
    report false "$name" "got:  $got"$'\n'"want: $want"
  fi
}

# dr_prepare_case <name> <expect pass|fail> <LICENSE_EXCEPTIONS> [purls output]
# Runs "Prepare licence exceptions"; on pass, checks the `purls=` output.
dr_prepare_case() {
  local name=$1 want=$2 exceptions=$3 want_purls=${4-}
  local work="$tmp/dr-prepare"
  rm -rf "$work"
  mkdir -p "$work"
  local got=pass
  (cd "$work" && LICENSE_EXCEPTIONS="$exceptions" GITHUB_OUTPUT="$work/output" \
    bash -e "$tmp/dr-prepare.sh" > "$work/log" 2>&1) || got=fail
  local ok=true detail=""
  if [ "$got" != "$want" ]; then
    ok=false
    detail="got $got, want $want"$'\n'"$(cat "$work/log")"
  elif [ "$want" = pass ]; then
    if [ "$(wc -l < "$work/output")" != 1 ] || [ "$(cat "$work/output")" != "purls=$want_purls" ]; then
      ok=false
      detail="GITHUB_OUTPUT is not exactly 'purls=$want_purls': $(cat "$work/output")"
    fi
  fi
  report "$ok" "$name" "$detail"
}

# dr_check_case <name> <expect pass|fail> <review outcome> <invalid-license-changes>
#               <LICENSE_EXCEPTIONS> <compare API response> [message] [calls compare: yes|no]
# Runs "Check unknown and excepted licences" with a stub dependency review API.
dr_check_case() {
  local name=$1 want=$2 outcome=$3 invalid=$4 exceptions=$5 compare=$6 message=${7:-} want_calls=${8:-}
  local fix="$tmp/fixture" work="$tmp/work"
  rm -rf "$fix" "$work"
  mkdir -p "$fix" "$work"
  printf '%s\n' "$compare" > "$fix/compare.json"
  : > "$fix/calls"
  local got=pass
  (cd "$work" && FIX="$fix" PATH="$stub:$PATH" REPO=o/r BASE_SHA=b1 HEAD_SHA=h1 \
    REVIEW_OUTCOME="$outcome" INVALID_LICENSES="$invalid" LICENSE_EXCEPTIONS="$exceptions" \
    bash -e "$tmp/dr-check.sh" > "$work/log" 2>&1) || got=fail
  local ok=true detail=""
  if [ "$got" != "$want" ]; then
    ok=false
    detail+="got $got, want $want"$'\n'"$(cat "$work/log")"$'\n'
  fi
  if [ -n "$message" ] && ! grep -qF -- "$message" "$work/log"; then
    ok=false
    detail+="did not print: $message"$'\n'"$(cat "$work/log")"$'\n'
  fi
  case "$want_calls" in
    yes) grep -qx 'repos/o/r/dependency-graph/compare/b1...h1' "$fix/calls" \
           || { ok=false; detail+="did not call the compare API for b1...h1: $(cat "$fix/calls")"$'\n'; } ;;
    no) [ ! -s "$fix/calls" ] || { ok=false; detail+="unexpected API calls: $(cat "$fix/calls")"$'\n'; } ;;
  esac
  report "$ok" "$name" "$detail"
}

# policy_case <name> <yq expression over the workflow> <expected value>
policy_case() {
  local got
  got=$(yq "$2" "$workflow")
  if [ "$got" = "$3" ]; then
    report true "$1" ""
  else
    report false "$1" "got:  $got"$'\n'"want: $3"
  fi
}

# cs_case <name> <expect run=true|false> <base files> <head files> [options]
#   files:   semicolon-separated "path=content" pairs; "path=-" removes the file
#   options: head=<branch> (default feature/x), message=<text it must print>,
#            config=<content .changeset/config.json must have afterwards>
# Builds a repository with a base commit, a PR branch on top of it and the
# merge commit the checkout of a PR gives, then runs "Prepare the changeset
# check" in it.
cs_case() {
  local name=$1 want=$2 base_files=$3 head_files=$4
  shift 4
  local head=feature/x message="" config="" opt
  for opt in "$@"; do
    case "$opt" in
      head=*) head=${opt#head=} ;;
      message=*) message=${opt#message=} ;;
      config=*) config=${opt#config=} ;;
      *) echo "Unknown option: $opt" >&2; exit 2 ;;
    esac
  done
  local repo="$tmp/cs-repo"
  rm -rf "$repo"
  mkdir -p "$repo"
  apply_files() { # <files>
    local spec path
    local -a specs
    IFS=';' read -r -a specs <<< "$1"
    for spec in "${specs[@]}"; do
      [ -n "$spec" ] || continue
      path=${spec%%=*}
      if [ "${spec#*=}" = - ]; then
        rm -f "$repo/$path"
      else
        mkdir -p "$repo/$(dirname "$path")"
        printf '%s\n' "${spec#*=}" > "$repo/$path"
      fi
    done
  }
  local gitc=(git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
  "${gitc[@]}" init -q -b main
  apply_files "README.md=base;$base_files"
  "${gitc[@]}" add -A && "${gitc[@]}" commit -qm base
  "${gitc[@]}" switch -q -c pr
  apply_files "src/pr.ts=pr;$head_files"
  "${gitc[@]}" add -A && "${gitc[@]}" commit -qm pr
  "${gitc[@]}" switch -q main
  echo more > "$repo/MAIN.md"
  "${gitc[@]}" add -A && "${gitc[@]}" commit -qm "main moves on"
  "${gitc[@]}" merge -q --no-ff -m merge pr
  local got_run
  (cd "$repo" && HEAD_REF="$head" GITHUB_OUTPUT="$tmp/cs-output" bash -e "$tmp/cs-prepare.sh" > "$tmp/cs-log" 2>&1)
  local status=$?
  got_run=$(sed -n 's/^run=//p' "$tmp/cs-output" 2> /dev/null)
  local want_base ok=true detail=""
  want_base=$(git -C "$repo" rev-parse HEAD^1)
  if [ "$status" != 0 ]; then
    ok=false; detail+="step failed: $(cat "$tmp/cs-log")"$'\n'
  elif [ "$got_run" != "$want" ]; then
    ok=false; detail+="run=$got_run, want $want"$'\n'"$(cat "$tmp/cs-log")"$'\n'
  elif ! grep -qx "base=$want_base" "$tmp/cs-output"; then
    ok=false; detail+="base output is not the merge commit's first parent: $(cat "$tmp/cs-output")"$'\n'
  fi
  if [ -n "$message" ] && ! grep -qF -- "$message" "$tmp/cs-log"; then
    ok=false; detail+="did not print: $message"$'\n'"$(cat "$tmp/cs-log")"$'\n'
  fi
  if [ -n "$config" ] && [ "$(cat "$repo/.changeset/config.json" 2> /dev/null)" != "$config" ]; then
    ok=false; detail+="config is: $(cat "$repo/.changeset/config.json" 2> /dev/null), want: $config"$'\n'
  fi
  rm -f "$tmp/cs-output"
  report "$ok" "$name" "$detail"
}

echo "# Regression test: bug fix = title type 'fix' or label 'bug'"
pr_case "fix title without a test fails" pass fail \
  "fix: handle empty input" "" "src/a.ts modified" "message=A bug fix (title type 'fix')"
pr_case "fix(area)! title with a test passes" pass pass \
  "fix(api)!: reject bad ids" "" "src/a.ts modified;src/a.test.ts added" "message=regression test present"
pr_case "bug label without a test fails" pass fail \
  "feat: add export" "bug" "src/a.ts modified" "message=A bug fix (label 'bug')"
pr_case "bug label among other labels fails" pass fail \
  "feat: add export" "good first issue,bug" "src/a.ts modified" "message=label 'bug'"
pr_case "bug label waived by skip-regression-test" pass pass \
  "feat: add export" "bug,skip-regression-test" "src/a.ts modified" "message=waived by the maintainer"
pr_case "fix title waived by skip-regression-test" pass pass \
  "fix: handle empty input" "skip-regression-test" "src/a.ts modified" "message=waived by the maintainer"
pr_case "label 'bugfix' is not 'bug'" pass pass \
  "feat: add export" "bugfix" "src/a.ts modified"
pr_case "'fixup:' is not type fix (and fails the title gate)" fail pass \
  "fixup: tidy" "" "src/a.ts modified"
pr_case "'Fix:' is not type fix (and fails the title gate)" fail pass \
  "Fix: tidy" "" "src/a.ts modified"
pr_case "a removed test file does not count" pass fail \
  "fix: handle empty input" "" "src/a.ts modified;src/old.test.ts removed"
pr_case "a file under __tests__/ counts" pass pass \
  "fix: handle empty input" "" "src/a.ts modified;src/__tests__/a.ts modified"
pr_case "a .spec.mjs file counts" pass pass \
  "fix: handle empty input" "" "src/a.mjs modified;src/a.spec.mjs added"
pr_case "a file under tests/ at the root counts" pass pass \
  "fix: handle empty input" "" "scripts/a.sh modified;tests/a.sh modified"
pr_case "a file under a nested tests/ counts" pass pass \
  "fix: handle empty input" "" "src/a.py modified;pkg/tests/test_a.py added"
pr_case "a directory ending in tests/ (contests/) does not count" pass fail \
  "fix: handle empty input" "" "src/a.ts modified;docs/contests/a.ts modified"
pr_case "a .test.md file does not count" pass fail \
  "fix: handle empty input" "" "src/a.ts modified;notes/a.test.md added"
pr_case "chore title, no labels: no test needed" pass pass \
  "chore: bump tooling" "" "src/a.ts modified"

echo "# PR title"
# shellcheck disable=SC2016 # the $(...) must reach the gate unexpanded
pr_case "title with quotes and \$(...) is data, not code" pass pass \
  'feat: handle "quotes" and $(whoami)' "" "src/a.ts modified"
pr_case "title over 72 characters fails" fail pass \
  "feat: $(printf 'a%.0s' $(seq 1 70))" "" "src/a.ts modified"
pr_case "title without a type fails" fail pass \
  "Add export" "" "src/a.ts modified"
for type in feat fix chore docs style refactor test perf ci build revert; do
  pr_case "type '$type' is accepted" pass "$([ "$type" = fix ] && echo fail || echo pass)" \
    "$type(ui): adjust spacing" "" "src/a.ts modified"
done
pr_case "type 'styles' is not 'style'" fail pass \
  "styles: adjust spacing" "" "src/a.ts modified"
pr_case "type 'Style' (capital) fails" fail pass \
  "Style: adjust spacing" "" "src/a.ts modified"
pr_case "multi-line title fails and stays one output line" fail pass \
  $'feat: first line\nsecond line' "" "src/a.ts modified"

echo "# Changeset: what the check runs with"
cfg_base='{"baseBranch": "main"}'
cfg_loose='{"baseBranch": "main", "changedFilePatterns": ["nothing/**"]}'
cs_case "base with Changesets: the check runs" true ".changeset/config.json=$cfg_base" "" \
  "message=unchanged by this PR" "config=$cfg_base"
cs_case "a PR that loosens the config is checked with the base config" true \
  ".changeset/config.json=$cfg_base" ".changeset/config.json=$cfg_loose" \
  "message=of the base commit" "config=$cfg_base"
cs_case "a PR that removes Changesets is still checked" true \
  ".changeset/config.json=$cfg_base" ".changeset/config.json=-" "config=$cfg_base"
cs_case "a PR that adds Changesets: checked from the next PR" false "" ".changeset/config.json=$cfg_base" \
  "message=applies from the next PR"
cs_case "no Changesets: no check" false "" "" "message=changesets are not used"
cs_case "release PR: no check" false ".changeset/config.json=$cfg_base" "" \
  "head=changeset-release/main" "message=Release PR"
cs_case "a branch only named like a release PR is checked" true ".changeset/config.json=$cfg_base" "" \
  "head=feature/changeset-release/x"

echo "# Detect"
detect_case "empty repository" "agent-rules=false lessons=false nvmrc=false"
detect_case "lessons and .nvmrc (a changeset config is not detected here)" "agent-rules=false lessons=true nvmrc=true" \
  .changeset/config.json scripts/check-lessons.mjs .nvmrc
detect_case "agent rules dependency in package.json" "agent-rules=true lessons=false nvmrc=false" \
  'package.json:{"devDependencies":{"@sysvena/agent-rules":"0.1.0"}}'
detect_case "other @sysvena package is not agent rules" "agent-rules=false lessons=false nvmrc=false" \
  'package.json:{"devDependencies":{"@sysvena/agent-rules-extra":"1.0.0"}}'

echo "# Dependency review: policy"
dr='.jobs."dependency-review"'
review="$dr.steps[] | select(.name == \"Review dependency changes\")"
policy_case "action pinned to the v5.0.0 commit" "$review | .uses" \
  "actions/dependency-review-action@a1d282b36b6f3519aa1f3fc636f609c47dddb294"
policy_case "fails on every severity" "$review | .with.\"fail-on-severity\"" "low"
policy_case "fails in every scope" "$review | .with.\"fail-on-scopes\"" "runtime, development, unknown"
# shellcheck disable=SC2016 # literal workflow expressions, not shell
policy_case "uses the allow list" "$review | .with.\"allow-licenses\"" '${{ env.ALLOW_LICENSES }}'
# shellcheck disable=SC2016 # literal workflow expressions, not shell
policy_case "exceptions only from this workflow" "$review | .with.\"allow-dependencies-licenses\"" \
  '${{ steps.exceptions.outputs.purls }}'
policy_case "only the policy inputs are set" "$review | .with | keys | join(\",\")" \
  "fail-on-severity,fail-on-scopes,allow-licenses,allow-dependencies-licenses"
policy_case "allow list as decided" "$dr.env.ALLOW_LICENSES" \
  "MIT, MIT-0, Apache-2.0, ISC, BSD-2-Clause, BSD-3-Clause, 0BSD, BlueOak-1.0.0, Zlib, Python-2.0, AFL-2.1, AFL-3.0, CC0-1.0, Unlicense, CC-BY-4.0"
policy_case "read-only token" "$dr.permissions | to_entries | map(.key + \"=\" + .value) | join(\",\")" "contents=read"
policy_case "no checkout (a PR cannot change the policy)" "[$dr.steps[] | select(.uses // \"\" | test(\"checkout\"))] | length" "0"

echo "# Dependency review: licence exceptions"
dr_prepare_case "the exceptions in the workflow are valid" pass \
  "$(yq "$dr.env.LICENSE_EXCEPTIONS" "$workflow")" \
  "$(yq "$dr.env.LICENSE_EXCEPTIONS" "$workflow" | jq -r 'map(.purl) | join(", ")')"
dr_prepare_case "no exceptions" pass '[]' ""
dr_prepare_case "two exceptions become one purl list" pass \
  '[{"purl":"pkg:npm/elkjs","license":"EPL-2.0","reason":"r"},{"purl":"pkg:npm/%40img/sharp-libvips-linux-x64","license":"LGPL-3.0-or-later","reason":"r"}]' \
  "pkg:npm/elkjs, pkg:npm/%40img/sharp-libvips-linux-x64"
dr_prepare_case "purl with a version fails" fail '[{"purl":"pkg:npm/elkjs@0.9.3","license":"EPL-2.0","reason":"r"}]'
dr_prepare_case "purl with a comma fails" fail '[{"purl":"pkg:npm/a,pkg:npm/b","license":"MIT","reason":"r"}]'
dr_prepare_case "purl with a newline fails" fail "$(jq -n '[{purl: "pkg:npm/a\npkg:npm/b", license: "MIT", reason: "r"}]')"
dr_prepare_case "missing reason fails" fail '[{"purl":"pkg:npm/elkjs","license":"EPL-2.0"}]'
dr_prepare_case "blank reason fails" fail '[{"purl":"pkg:npm/elkjs","license":"EPL-2.0","reason":" "}]'
dr_prepare_case "empty licence fails" fail '[{"purl":"pkg:npm/elkjs","license":"","reason":"r"}]'
dr_prepare_case "unknown key fails" fail '[{"purl":"pkg:npm/elkjs","license":"EPL-2.0","reason":"r","version":"1"}]'
dr_prepare_case "not an array fails" fail '{"purl":"pkg:npm/elkjs","license":"EPL-2.0","reason":"r"}'
dr_prepare_case "not JSON fails" fail 'pkg:npm/elkjs'

echo "# Dependency review: unknown and excepted licences"
none='{"forbidden":[],"unresolved":[],"unlicensed":[]}'
ex_elk='[{"purl":"pkg:npm/elkjs","license":"EPL-2.0","reason":"r"}]'
ex_unknown='[{"purl":"pkg:githubactions/acme/tool","license":"NOASSERTION","reason":"r"}]'
add() { # <purl> <licence or null> [change type]
  jq -n --arg p "$1" --argjson l "$2" --arg t "${3:-added}" \
    '{change_type: $t, manifest: "package.json", ecosystem: "npm", name: ($p | sub("^pkg:[a-z]+/"; "") | sub("@[^/@]*$"; "")),
      version: ($p | capture("@(?<v>[^/@]*)$").v // ""), package_url: $p, license: $l, scope: "runtime", vulnerabilities: []}'
}
dr_check_case "nothing to report passes without API calls" pass success "$none" '[]' '[]' \
  "Every added dependency has a detected licence" no
dr_check_case "unknown licence fails" fail failure \
  '{"forbidden":[],"unresolved":[],"unlicensed":[{"manifest":"package.json","name":"mystery","version":"1.0.0","package_url":"pkg:npm/mystery@1.0.0"}]}' \
  '[]' '[]' "package.json » mystery@1.0.0 (pkg:npm/mystery@1.0.0)"
dr_check_case "unknown licence fails even when the action passed" fail success \
  '{"forbidden":[],"unresolved":[],"unlicensed":[{"manifest":"w.yml","name":"acme/tool","version":"1","package_url":"pkg:githubactions/acme/tool@1"}]}' \
  '[]' '[]' "no detected licence"
dr_check_case "no licence result after a successful review fails" fail success "" '[]' '[]' \
  "reported no licence result"
dr_check_case "no licence result after a failed review defers to it" fail failure "" '[]' '[]' \
  "failed before it reported licences"
dr_check_case "unknown licence and changed exception: unknown reported too" fail success \
  '{"forbidden":[],"unresolved":[],"unlicensed":[{"manifest":"package.json","name":"mystery","version":"1.0.0","package_url":"pkg:npm/mystery@1.0.0"}]}' \
  "$ex_elk" "[$(add pkg:npm/elkjs@0.10.0 '"GPL-3.0-only"')]" "package.json » mystery@1.0.0"
dr_check_case "compare API error fails" fail success "$none" "$ex_elk" 'not json'
dr_check_case "excepted package with its approved licence passes" pass failure "$none" "$ex_elk" \
  "[$(add pkg:npm/elkjs@0.9.3 '"EPL-2.0"')]" "still has its approved licence" yes
dr_check_case "excepted package with a new licence fails" fail success "$none" "$ex_elk" \
  "[$(add pkg:npm/elkjs@0.10.0 '"GPL-3.0-only"')]" \
  "package.json » elkjs@0.10.0: reports GPL-3.0-only, the exception approved EPL-2.0 (pkg:npm/elkjs)" yes
dr_check_case "excepted package now with no licence fails" fail success "$none" "$ex_elk" \
  "[$(add pkg:npm/elkjs@0.10.0 null)]" "reports NOASSERTION, the exception approved EPL-2.0"
dr_check_case "exception approved for NOASSERTION matches no licence" pass success "$none" "$ex_unknown" \
  "[$(add pkg:githubactions/acme/tool@v2 null)]"
dr_check_case "a removed version with another licence is ignored" pass success "$none" "$ex_elk" \
  "[$(add pkg:npm/elkjs@0.8.0 '"MIT"' removed), $(add pkg:npm/elkjs@0.9.3 '"EPL-2.0"')]"
dr_check_case "an exception does not cover a package with a longer name" pass success "$none" "$ex_elk" \
  "[$(add pkg:npm/elkjs-extra@1.0.0 '"MIT"')]"
dr_check_case "purl match ignores case and qualifiers" fail success "$none" \
  '[{"purl":"pkg:npm/%40img/sharp-libvips-linux-x64","license":"LGPL-3.0-or-later","reason":"r"}]' \
  "[$(add 'pkg:npm/%40IMG/sharp-libvips-linux-x64@1.3.4?arch=x64' '"MIT"')]" "the exception approved LGPL-3.0-or-later"
dr_check_case "scoped package purl without the version matches" fail success "$none" \
  '[{"purl":"pkg:npm/%40img/sharp-libvips-linux-x64","license":"LGPL-3.0-or-later","reason":"r"}]' \
  "[$(add 'pkg:npm/%40img/sharp-libvips-linux-x64@1.3.4' '"MIT"')]" "reports MIT"
dr_check_case "unknown licence and changed exception are both reported" fail success \
  '{"forbidden":[],"unresolved":[],"unlicensed":[{"manifest":"package.json","name":"mystery","version":"1.0.0","package_url":"pkg:npm/mystery@1.0.0"}]}' \
  "$ex_elk" "[$(add pkg:npm/elkjs@0.10.0 '"GPL-3.0-only"')]" "reports GPL-3.0-only"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
