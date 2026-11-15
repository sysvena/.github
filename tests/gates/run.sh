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
#   options: changeset=true|false (default false), head=<branch> (default feature/x),
#            message=<text the changes gate must print>
pr_case() {
  local name=$1 want_title=$2 want_changes=$3 title=$4 labels=$5 files=$6
  shift 6
  local changeset=false head=feature/x message="" opt
  for opt in "$@"; do
    case "$opt" in
      changeset=*) changeset=${opt#changeset=} ;;
      head=*) head=${opt#head=} ;;
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
  (cd "$work" && FIX="$fix" PATH="$stub:$PATH" REPO=o/r PR=1 HEAD_REF="$head" \
    REQUIRE_CHANGESET="$changeset" PR_SNAPSHOT="$snapshot" \
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
pr_case "chore title, no labels: no test needed" pass fail \
  "chore: bump tooling" "" "src/a.ts modified"

echo "# PR title"
# shellcheck disable=SC2016 # the $(...) must reach the gate unexpanded
pr_case "title with quotes and \$(...) is data, not code" pass pass \
  'feat: handle "quotes" and $(whoami)' "" "src/a.ts modified"
pr_case "title over 72 characters fails" fail pass \
  "feat: $(printf 'a%.0s' $(seq 1 70))" "" "src/a.ts modified"
pr_case "title without a type fails" fail pass \
  "Add export" "" "src/a.ts modified"
pr_case "multi-line title fails and stays one output line" fail pass \
  $'feat: first line\nsecond line' "" "src/a.ts modified"

echo "# Changeset (when .changeset/config.json exists)"
pr_case "shipped file without a changeset fails" pass fail \
  "feat: add export" "" "src/a.ts modified" "changeset=true" "message=adds no changeset"
pr_case "shipped file with a changeset passes" pass pass \
  "feat: add export" "" "src/a.ts modified;.changeset/brave-cats.md added" "changeset=true" "message=Changeset present"
pr_case ".changeset/README.md is not a changeset" pass fail \
  "feat: add export" "" "src/a.ts modified;.changeset/README.md modified" "changeset=true"
pr_case "a removed changeset does not count" pass fail \
  "feat: add export" "" "src/a.ts modified;.changeset/old.md removed" "changeset=true"
pr_case "docs, agent and CI files need no changeset" pass pass \
  "docs: explain setup" "" "README.md modified;docs/setup.md added;.ai/notes.md modified;.github/workflows/ci.yml modified" \
  "changeset=true" "message=no changeset needed"
pr_case "release PR needs no changeset" pass pass \
  "chore(release): version packages" "" "packages/a/package.json modified" "changeset=true" "head=changeset-release/main" \
  "message=Release PR"
pr_case "no changesets in the repository: none needed" pass pass \
  "feat: add export" "" "src/a.ts modified" "changeset=false" "message=changesets are not used"

echo "# Detect"
detect_case "empty repository" "changeset=false agent-rules=false lessons=false nvmrc=false"
detect_case "changesets, lessons and .nvmrc" "changeset=true agent-rules=false lessons=true nvmrc=true" \
  .changeset/config.json scripts/check-lessons.mjs .nvmrc
detect_case "agent rules dependency in package.json" "changeset=false agent-rules=true lessons=false nvmrc=false" \
  'package.json:{"devDependencies":{"@sysvena/agent-rules":"0.1.0"}}'
detect_case "other @sysvena package is not agent rules" "changeset=false agent-rules=false lessons=false nvmrc=false" \
  'package.json:{"devDependencies":{"@sysvena/agent-rules-extra":"1.0.0"}}'

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
