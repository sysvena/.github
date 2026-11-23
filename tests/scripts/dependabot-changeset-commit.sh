#!/usr/bin/env bash
# Tests the "Commit and push" step of .github/workflows/dependabot-changeset.yml:
# runs its real `run:` block (extracted with yq, as tests/gates/run.sh does)
# in a clone of a local repository, with a stub `gh`. Needs bash, git and yq
# v4 (mikefarah).
# Usage: tests/scripts/dependabot-changeset-commit.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
workflow="$root/.github/workflows/dependabot-changeset.yml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

yq '.jobs.commit.steps[] | select(.name == "Commit and push") | .run' "$workflow" > "$tmp/step.sh"
[ -s "$tmp/step.sh" ] || { echo "The step 'Commit and push' was not found in $workflow." >&2; exit 1; }

# The step asks GitHub for the id of the app's bot user.
mkdir "$tmp/bin"
printf '#!/usr/bin/env bash\necho 123\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

branch=dependabot/npm_and_yarn/ms-2.1.3
changeset=.changeset/dependabot-npm-and-yarn-ms-2-1-3.md
failures=0
report() { # <ok> <name> <detail>
  if [ "$1" = true ]; then
    echo "  ok     - $2"
  else
    echo "  not ok - $2: $3"
    failures=$((failures + 1))
  fi
}

# new_case <name> <with changeset: true|false>: a remote with the Dependabot
# branch (holding the changeset or not) and a clone of it at that branch,
# as the job's checkout leaves it.
new_case() {
  dir="$tmp/$1"
  mkdir -p "$dir/temp"
  git init -q --bare -b main "$dir/remote.git"
  git clone -q "$dir/remote.git" "$dir/seed" 2> /dev/null
  (
    cd "$dir/seed"
    git config user.email test@example.invalid
    git config user.name test
    echo '{}' > package.json
    git add -A
    git commit -qm base
    git push -q origin HEAD:main
    git checkout -q -b "$branch"
    echo 'v2' > yarn.lock
    if [ "$2" = true ]; then
      mkdir -p .changeset
      printf -- '---\n"app": patch\n---\n\nOld.\n' > "$changeset"
    fi
    git add -A
    git commit -qm update
    git push -q origin "HEAD:refs/heads/$branch"
  )
  git clone -q --branch "$branch" "$dir/remote.git" "$dir/work" 2> /dev/null
  printf -- '---\n"app": patch\n---\n\nUpdate locked dependency versions.\n' > "$dir/temp/changeset.md"
}

# run_step <write: true|false>: status in $status, output in $out.
run_step() {
  status=0
  out=$(cd "$dir/work" && PATH="$tmp/bin:$PATH" RUNNER_TEMP="$dir/temp" GH_TOKEN=x APP_SLUG=sysvena-dependabot \
    HEAD_REF="$branch" CHANGESET="$changeset" WRITE="$1" bash "$tmp/step.sh" 2>&1) || status=$?
}
remote_commits() { git -C "$dir/remote.git" rev-list --count "refs/heads/$branch"; }
remote_has() { git -C "$dir/remote.git" cat-file -e "refs/heads/$branch:$changeset" 2> /dev/null; }
remote_subject() { git -C "$dir/remote.git" log -1 --format=%s "refs/heads/$branch"; }

new_case add false
run_step true
if [ "$status" -eq 0 ] && remote_has && [ "$(remote_commits)" -eq 3 ] \
  && [ "$(remote_subject)" = "chore(changeset): add the changeset for this update [dependabot skip]" ] \
  && [ "$(git -C "$dir/remote.git" log -1 --format=%an "refs/heads/$branch")" = "sysvena-dependabot[bot]" ]; then
  report true "a planned changeset is committed and pushed" ""
else
  report false "a planned changeset is committed and pushed" "status $status: $out"
fi

run_step true
if [ "$status" -eq 0 ] && [ "$(remote_commits)" -eq 3 ] && grep -qF "The changeset is up to date." <<< "$out"; then
  report true "the same changeset again changes nothing" ""
else
  report false "the same changeset again changes nothing" "status $status: $out"
fi

new_case replace true
run_step true
if [ "$status" -eq 0 ] && [ "$(remote_commits)" -eq 3 ] \
  && git -C "$dir/remote.git" show "refs/heads/$branch:$changeset" | grep -qF "Update locked dependency versions."; then
  report true "a changed changeset replaces the old one" ""
else
  report false "a changed changeset replaces the old one" "status $status: $out"
fi

new_case none false
run_step false
if [ "$status" -eq 0 ] && [ "$(remote_commits)" -eq 2 ] && grep -qF "No changeset is needed and the branch has none." <<< "$out"; then
  report true "no changeset needed and none on the branch: nothing is pushed" ""
else
  report false "no changeset needed and none on the branch: nothing is pushed" "status $status: $out"
fi

new_case remove true
run_step false
if [ "$status" -eq 0 ] && ! remote_has && [ "$(remote_commits)" -eq 3 ] \
  && [ "$(remote_subject)" = "chore(changeset): remove the changeset of this update [dependabot skip]" ]; then
  report true "no changeset needed: the one on the branch is removed" ""
else
  report false "no changeset needed: the one on the branch is removed" "status $status: $out"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
