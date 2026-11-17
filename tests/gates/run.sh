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
extract pr-description "Check the PR description" "$tmp/description.sh"
extract changeset "Prepare the changeset check" "$tmp/cs-prepare.sh"
extract dependency-review "Prepare licence exceptions" "$tmp/dr-prepare.sh"
extract dependency-review "Check unknown and excepted licences" "$tmp/dr-check.sh"
extract workflow-lockfile "Find workflows" "$tmp/lf-find.sh"
extract workflow-lockfile "Install gh-actions-lock" "$tmp/lf-install.sh"
extract workflow-lockfile "Verify the lockfile" "$tmp/lf-verify.sh"

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

# desc_case <name> <expect pass|fail> <body> [head=<ref>] [author=<login>] [message=<text>]
# Runs "Read the PR" on a fixture with this body, then "Check the PR description"
# on the snapshot it wrote, as the workflow does.
desc_case() {
  local name=$1 want=$2 body=$3
  shift 3
  local head=feature/x author=someone message="" opt
  for opt in "$@"; do
    case "$opt" in
      head=*) head=${opt#head=} ;;
      author=*) author=${opt#author=} ;;
      message=*) message=${opt#message=} ;;
      *) echo "Unknown option: $opt" >&2; exit 2 ;;
    esac
  done
  local fix="$tmp/fixture" work="$tmp/work"
  rm -rf "$fix" "$work"
  mkdir -p "$fix" "$work"
  jq -n --arg body "$body" '{number: 1, state: "open", title: "docs: x", labels: [],
    body: (if $body == "<null>" then null else $body end)}' > "$fix/pr.json"
  if ! (cd "$work" && FIX="$fix" PATH="$stub:$PATH" REPO=o/r PR=1 GITHUB_OUTPUT="$work/output" \
    bash -e "$tmp/read.sh" > "$work/read.log" 2>&1); then
    report false "$name" "Read the PR failed: $(cat "$work/read.log")"
    return
  fi
  local snapshot got=pass
  snapshot=$(sed -n 's/^pr=//p' "$work/output")
  (cd "$work" && PR_SNAPSHOT="$snapshot" HEAD_REF="$head" AUTHOR="$author" \
    bash -e "$tmp/description.sh" > "$work/desc.log" 2>&1) || got=fail
  local ok=true detail=""
  if [ "$got" != "$want" ]; then
    ok=false
    detail="got $got, want $want"$'\n'"$(cat "$work/desc.log")"
  elif [ -n "$message" ] && ! grep -qF -- "$message" "$work/desc.log"; then
    ok=false
    detail="did not print: $message"$'\n'"$(cat "$work/desc.log")"
  fi
  report "$ok" "$name" "$detail"
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

# lf_find_case <name> <expected workflows=true|false> <files to create...>
lf_find_case() {
  local name=$1 want=$2
  shift 2
  local work="$tmp/lf-find" f
  rm -rf "$work"
  mkdir -p "$work"
  for f in "$@"; do mkdir -p "$work/$(dirname "$f")"; : > "$work/$f"; done
  local got
  got=$(cd "$work" && GITHUB_OUTPUT="$work/.output" bash -e "$tmp/lf-find.sh" > /dev/null 2>&1 \
    && cat "$work/.output")
  if [ "$got" = "workflows=$want" ]; then
    report true "$name" ""
  else
    report false "$name" "got:  $got"$'\n'"want: workflows=$want"
  fi
}

# lf_install_case <name> <expect pass|fail> <asset content> <pinned SHA-256> [uname -s-m] [message]
# Runs "Install gh-actions-lock" with the stub `gh release download` and a
# stub `uname`.
lf_install_case() {
  local name=$1 want=$2 asset=$3 sha=$4 platform=${5:-Linux-x86_64} message=${6:-}
  local fix="$tmp/fixture" work="$tmp/work" bin="$tmp/bin"
  rm -rf "$fix" "$work" "$bin"
  mkdir -p "$fix" "$work" "$bin"
  printf '%s' "$asset" > "$fix/asset"
  : > "$fix/calls"
  # shellcheck disable=SC2016 # the stub's own $1, not expanded here
  printf '#!/usr/bin/env bash\ncase "$1" in -s) echo %s ;; -m) echo %s ;; esac\n' \
    "${platform%%-*}" "${platform#*-}" > "$bin/uname"
  chmod +x "$bin/uname"
  local got=pass
  (cd "$work" && FIX="$fix" PATH="$bin:$stub:$PATH" LOCK_BIN="$work/gh-actions-lock" \
    GH_ACTIONS_LOCK_VERSION=v9.9.9 GH_ACTIONS_LOCK_SHA256="$sha" \
    bash -e "$tmp/lf-install.sh" > "$work/log" 2>&1) || got=fail
  local ok=true detail=""
  if [ "$got" != "$want" ]; then
    ok=false; detail+="got $got, want $want"$'\n'"$(cat "$work/log")"$'\n'
  fi
  if [ -n "$message" ] && ! grep -qF -- "$message" "$work/log"; then
    ok=false; detail+="did not print: $message"$'\n'"$(cat "$work/log")"$'\n'
  fi
  if [ "$want" = pass ]; then
    grep -qx 'release download v9.9.9 github/gh-actions-lock linux-amd64' "$fix/calls" \
      || { ok=false; detail+="did not download the pinned asset: $(cat "$fix/calls")"$'\n'; }
    [ -x "$work/gh-actions-lock" ] || { ok=false; detail+="the binary is not executable"$'\n'; }
  fi
  report "$ok" "$name" "$detail"
}

# lf_verify_case <name> <expect pass|fail> <lockfile yes|no> <exit code> <JSON on stdout> [message]
# Runs "Verify the lockfile" with a stub binary that prints the JSON, writes a
# line to stderr and exits with the code.
lf_verify_case() {
  local name=$1 want=$2 lockfile=$3 code=$4 json=$5 message=${6:-}
  local work="$tmp/work"
  rm -rf "$work"
  mkdir -p "$work/.github/workflows"
  [ "$lockfile" = yes ] && : > "$work/.github/workflows/actions.lock"
  printf '%s' "$json" > "$tmp/lf-stdout"
  # shellcheck disable=SC2016 # the stub's own $*, not expanded here
  printf '#!/usr/bin/env bash\n[ "$*" = "--verify --no-interactive --json" ] || { echo "bad args: $*" >&2; exit 9; }\ncat %q\necho "stub progress" >&2\nexit %s\n' \
    "$tmp/lf-stdout" "$code" > "$tmp/lf-bin"
  chmod +x "$tmp/lf-bin"
  local got=pass
  (cd "$work" && LOCK_BIN="$tmp/lf-bin" bash -e "$tmp/lf-verify.sh" > "$work/log" 2>&1) || got=fail
  local ok=true detail=""
  if [ "$got" != "$want" ]; then
    ok=false; detail+="got $got, want $want"$'\n'"$(cat "$work/log")"$'\n'
  fi
  if [ -n "$message" ] && ! grep -qF -- "$message" "$work/log"; then
    ok=false; detail+="did not print: $message"$'\n'"$(cat "$work/log")"$'\n'
  fi
  report "$ok" "$name" "$detail"
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
# shellcheck disable=SC2016 # literal workflow expressions, not shell
policy_case "allowed advisories only from this workflow" "$review | .with.\"allow-ghsas\"" '${{ env.ALLOW_GHSAS }}'
policy_case "allowed advisories as reviewed" "$dr.env.ALLOW_GHSAS" "GHSA-3g3m-2fjr-6pw4"
policy_case "only the policy inputs are set" "$review | .with | keys | join(\",\")" \
  "fail-on-severity,fail-on-scopes,allow-licenses,allow-dependencies-licenses,allow-ghsas"
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

echo "# Workflow lockfile: policy"
policy_case "job reads contents only" '.jobs.workflow-lockfile.permissions | to_entries | map(.key + "=" + .value) | join(",")' "contents=read"
policy_case "extension version pinned" '.jobs.workflow-lockfile.env.GH_ACTIONS_LOCK_VERSION | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")' "true"
policy_case "extension SHA-256 pinned" '.jobs.workflow-lockfile.env.GH_ACTIONS_LOCK_SHA256 | test("^[0-9a-f]{64}$")' "true"
# A tag ref in the gates breaks ruleset runs once the lockfile is used (tested
# on gates-canary), and --no-narrow keeps SHA pins: every step `uses:` of the
# gates is a full commit SHA.
policy_case "every action in the gates is pinned to a commit SHA" \
  '[.jobs[].steps[] | select(has("uses")) | .uses | test("^[^@]+@[0-9a-f]{40}$")] | all' "true"

echo "# Workflow lockfile: when it applies"
lf_find_case "no .github/workflows: no check" false README.md
lf_find_case "empty .github/workflows: no check" false .github/workflows/README.md
lf_find_case "a .yml workflow: check" true .github/workflows/ci.yml
lf_find_case "a .yaml workflow: check" true .github/workflows/release.yaml
lf_find_case "only a nested file (not run by GitHub): no check" false .github/workflows/sub/ci.yml
lf_find_case "only a lockfile: no check" false .github/workflows/actions.lock

echo "# Workflow lockfile: install"
good_sha=$(printf 'binary' | sha256sum | cut -d' ' -f1)
lf_install_case "pinned SHA-256 matches: installed" pass binary "$good_sha" "" "SHA-256 verified"
lf_install_case "a different binary fails" fail tampered "$good_sha" "" "does not have the pinned SHA-256"
lf_install_case "an empty download fails" fail "" "$good_sha" "" "does not have the pinned SHA-256"
lf_install_case "a non-amd64 runner fails" fail binary "$good_sha" Linux-aarch64 "is linux-amd64"

echo "# Workflow lockfile: verify"
sha_ref='{"workflow":".github/workflows/ci.yml","category":"sha-as-ref","severity":"warning","dependency":"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1","detail":"pinned to a bare SHA"}'
finding() { printf '{"workflow":".github/workflows/ci.yml","category":"%s","severity":"%s","dependency":"actions/checkout@v1","detail":"d"}' "$1" "$2"; }
dep() { printf '{"nwo":"%s","ref":"%s","sha":"3d3c42e5aac5ba805825da76410c181273ba90b1","hash_algo":"sha1","direct":%s}' "$1" "$2" "$3"; }
pinned=$(dep actions/checkout 3d3c42e5aac5ba805825da76410c181273ba90b1 true)
# result <valid> <findings> [dependencies of .github/workflows/ci.yml]
result() { printf '{"valid":%s,"findings":[%s],"workflows":[{"path":".github/workflows/ci.yml","dependencies":[%s]}]}' "$1" "$2" "${3-$pinned}"; }
lf_verify_case "workflows without a lockfile fail" fail no 0 "$(result true "")" "has workflows but no .github/workflows/actions.lock"
lf_verify_case "valid with no findings passes" pass yes 0 "$(result true "")" "Workflow lockfile OK"
lf_verify_case "valid with only sha-as-ref passes" pass yes 0 "$(result true "$sha_ref,$sha_ref")" "2 sha-as-ref warning(s)"
lf_verify_case "an error finding (exit 1) fails" fail yes 1 "$(result false "$(finding tag-commit-mismatch error)")" "does not verify (exit 1)"
lf_verify_case "an unanswered API (reachability-unknown) fails" fail yes 1 \
  "$(result false '{"category":"reachability-unknown","severity":"error","retryable":true,"dependency":"actions/checkout@v1"}')" "does not verify"
lf_verify_case "a warning (ref-moved) fails" fail yes 0 "$(result true "$sha_ref,$(finding ref-moved warning)")" "1 finding(s) the policy does not accept"
lf_verify_case "a container-image warning fails" fail yes 0 "$(result true "$(finding container-image warning)")" "the policy does not accept"
lf_verify_case "a notice (fresh-tag, info) fails" fail yes 0 "$(result true "$(finding fresh-tag info)")" "the policy does not accept"
lf_verify_case "valid false with exit 0 fails" fail yes 0 "$(result false "")" "does not verify (exit 0)"
lf_verify_case "a non-zero exit with valid true fails" fail yes 1 "$(result true "")" "does not verify (exit 1)"
lf_verify_case "a tool failure (exit 2, no JSON) fails" fail yes 2 "" "failed (exit 2) without a result"
lf_verify_case "malformed JSON fails" fail yes 0 '{"valid":true}' "without a result"
lf_verify_case "JSON without workflows fails" fail yes 0 '{"valid":true,"findings":[]}' "without a result"
lf_verify_case "a direct tag ref fails" fail yes 0 "$(result true "" "$(dep actions/checkout v7.0.1 true)")" \
  ".github/workflows/ci.yml: actions/checkout@v7.0.1"
lf_verify_case "a direct short SHA ref fails" fail yes 0 "$(result true "" "$(dep actions/checkout 3d3c42e true)")" "Not pinned:"
lf_verify_case "a direct branch ref fails" fail yes 0 "$(result true "" "$pinned,$(dep actions/setup-node main true)")" \
  "actions/setup-node@main"
lf_verify_case "a transitive tag ref passes" pass yes 0 "$(result true "" "$pinned,$(dep actions/cache v4.2.0 false)")" "Workflow lockfile OK"
lf_verify_case "a workflow with no dependencies passes" pass yes 0 "$(result true "" "")" "Workflow lockfile OK"
lf_verify_case "the findings are printed" fail yes 0 "$(result true "$(finding stale-workflow warning)")" "warning stale-workflow: actions/checkout@v1 d"
lf_verify_case "the tool's log is printed" pass yes 0 "$(result true "")" "  stub progress"

# PR description gate (sysvena/mercato-platform#15 row 6.7).
nl=$'\n'
footer="${nl}${nl}🤖 Generated with [Claude Code](https://claude.com/claude-code)"
desc_case "bold labels with content pass" pass "Text.${nl}${nl}**Sources/tests:** unit tests.${nl}${nl}**Quality:** None.${footer}" \
  message="line 3"
desc_case "heading labels with content on the next lines pass" pass \
  "Text.${nl}${nl}## Sources/tests:${nl}- tests pass${nl}${nl}## Quality:${nl}None.${footer}"
desc_case "headings without the colon's bold also pass" pass "## Sources/tests:${nl}x${nl}### Quality:${nl}None."
desc_case "CRLF line ends pass" pass "**Sources/tests:** x"$'\r\n'"**Quality:** None."$'\r\n'
desc_case "an empty description fails" fail "" message="'Sources/tests:' part, then a 'Quality:' part"
desc_case "a null description fails" fail "<null>"
desc_case "no Quality fails" fail "**Sources/tests:** tests.${footer}"
desc_case "no Sources/tests fails" fail "**Quality:** None.${footer}"
desc_case "Quality before Sources/tests fails" fail "**Quality:** None.${nl}**Sources/tests:** x" message="must come before"
desc_case "empty Quality followed only by the attribution fails" fail "**Sources/tests:** x${nl}${nl}**Quality:**${footer}" \
  message="each need content"
desc_case "empty Quality followed by a heading fails" fail "**Sources/tests:** x${nl}**Quality:**${nl}## Notes${nl}text"
desc_case "empty Sources/tests fails" fail "**Sources/tests:**${nl}${nl}**Quality:** None."
desc_case "labels inside a line do not count" fail "See the **Sources/tests:** part and **Quality:** None."
desc_case "a similar word is not a label" fail "**Sources/tests:** x${nl}**Quality first:** None."
desc_case "text with \$(...) and backticks is data" pass "**Sources/tests:** \$(touch pwned) \`id\`${nl}**Quality:** None."
tpl=$(cat .github/pull_request_template.md)
desc_case "the unfilled PR template fails" fail "$tpl" message="each need content"
desc_case "the filled PR template passes" pass \
  "$(sed -e 's/^## Sources\/tests:$/&\n- ran tests/' -e 's/^## Quality:$/&\nNone./' .github/pull_request_template.md)"
desc_case "a hint in an HTML comment is not content" fail "**Sources/tests:** <!-- x -->${nl}**Quality:** None."
desc_case "a release PR is exempt" pass "" head=changeset-release/main message="Release PR"
desc_case "a Dependabot PR is exempt" pass "Bumps x." author='dependabot[bot]' message="Dependabot PR"
desc_case "a branch merely containing changeset-release is not exempt" fail "" head=feature/changeset-release/x

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
