#!/usr/bin/env bash
# Checks that the long-running scripts are safe to edit while they run.
#
# Bash reads a script as it executes it, so an edit in place (same file) while
# a script runs changes what it does next. A script whose body is one
# `{ ...; exit; }` group is read completely before any of it runs. This test
# shows the difference on throwaway scripts, then checks that every script in
# scripts/ and tests/e2e/ has that shape.
#
# Usage: tests/scripts/edit-safe.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
ok() { echo "ok     - $1"; }
not_ok() { echo "not ok - $1"; failed=1; }

# run_edited <script>: runs it, edits it in place while it sleeps, prints output.
run_edited() {
  bash "$1" > "$1.out" &
  local pid=$!
  sleep 0.5
  local s
  s=$(<"$1")
  printf '%s\n' "${s/echo original/echo edited}" > "$1"
  wait "$pid"
  cat "$1.out"
}

printf '#!/usr/bin/env bash\necho start\nsleep 1.5\necho original\n' > "$tmp/plain.sh"
printf '#!/usr/bin/env bash\n{\necho start\nsleep 1.5\necho original\nexit\n}\n' > "$tmp/group.sh"
if [ "$(run_edited "$tmp/plain.sh" | tail -1)" = edited ]; then
  ok "a plain script runs an edit made while it runs"
else
  not_ok "a plain script runs an edit made while it runs (the premise of this test)"
fi
if [ "$(run_edited "$tmp/group.sh" | tail -1)" = original ]; then
  ok "a { ...; exit; } script ignores an edit made while it runs"
else
  not_ok "a { ...; exit; } script ignores an edit made while it runs"
fi

for f in "$root"/scripts/*.sh "$root"/tests/e2e/*.sh; do
  name=${f#"$root"/}
  first=$(grep -v -e '^#' -e '^[[:space:]]*$' "$f" | head -1)
  last=$(grep -v '^[[:space:]]*$' "$f" | tail -2 | tr '\n' ' ')
  if [ "$first" = "{" ] && [ "$last" = "exit } " ]; then
    ok "$name is one { ...; exit; } group"
  else
    not_ok "$name is one { ...; exit; } group (first code line: '$first', last lines: '$last')"
  fi
done
exit "$failed"
