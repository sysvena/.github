#!/usr/bin/env bash
# The conditions are strings that check() evaluates after each run, so their
# variables must not expand where they are written.
# shellcheck disable=SC2016,SC2034
# Tests gh_read and gh_write (scripts/lib/gh-retry.sh) with a stub `gh` that
# fails a set number of times with a given error before it answers.
#
# Usage: tests/scripts/gh-retry.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
ok() { echo "ok     - $1"; }
not_ok() { echo "not ok - $1"; failed=1; }

# The stub: fails the first $FAILS calls by printing $ERROR and exiting 1,
# then prints "answer" and its arguments. Every call is logged.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
n=$(wc -l < "$STUB_DIR/calls")
if [ "$n" -le "$FAILS" ]; then
  echo "$ERROR" >&2
  exit 1
fi
prev=""
for a in "$@"; do
  if [ "$prev" = --input ]; then echo "body $(cat "$a")"; fi
  prev=$a
done
echo "answer $*"
STUB
chmod +x "$tmp/bin/gh"

# run <fails> <error> <gh_read arguments...>: sets STATUS, OUT, ERR, CALLS.
run() {
  local fails=$1 error=$2
  shift 2
  rm -f "$tmp/calls"
  touch "$tmp/calls"
  STATUS=0
  OUT=$(STUB_DIR=$tmp FAILS=$fails ERROR=$error GH_READ_DELAY=0 PATH="$tmp/bin:$PATH" \
    bash -c '. "$1"; shift; gh_read "$@"' _ "$root/scripts/lib/gh-retry.sh" "$@" 2> "$tmp/err") || STATUS=$?
  ERR=$(<"$tmp/err")
  CALLS=$(wc -l < "$tmp/calls")
}

check() { if eval "$2"; then ok "$1"; else not_ok "$1 (status $STATUS, calls $CALLS, out '$OUT', err '$ERR')"; fi; }

run 0 "" "repos/o/r" --jq .x
check "a read that works is called once and prints its answer" \
  '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 1 ] && [ "$OUT" = "answer api repos/o/r --jq .x" ] && [ -z "$ERR" ]'

for code in 500 502 503 504; do
  run 1 "gh: HTTP $code" "repos/o/r"
  check "HTTP $code is retried, then the answer is printed once" \
    '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 2 ] && [ "$OUT" = "answer api repos/o/r" ]'
done

run 1 "gh: Server Error (HTTP 502)" "repos/o/r"
check "gh's 'Server Error (HTTP 502)' wording is retried" '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 2 ]'

run 1 "gh: HTTP 503" "repos/o/r"
check "a retry says what it retries" 'grep -qF "gh_read: HTTP 503 for gh api repos/o/r, retry 1 of 3" <<< "$ERR"'

run 3 "gh: HTTP 503" "repos/o/r"
check "three failures are retried three times, then it works" '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 4 ]'

run 4 "gh: HTTP 503" "repos/o/r"
check "after three retries it fails with gh's status and message, and prints no answer" \
  '[ "$STATUS" -eq 1 ] && [ "$CALLS" -eq 4 ] && [ -z "$OUT" ] && grep -qx "gh: HTTP 503" <<< "$ERR"'

for code in 400 401 403 404 409 422 429; do
  run 1 "gh: HTTP $code" "repos/o/r"
  check "HTTP $code fails at once" '[ "$STATUS" -eq 1 ] && [ "$CALLS" -eq 1 ] && grep -qx "gh: HTTP $code" <<< "$ERR"'
done

run 1 "gh: HTTP 5030" "repos/o/r"
check "a longer number is not HTTP 503" '[ "$STATUS" -eq 1 ] && [ "$CALLS" -eq 1 ]'

run 1 "error connecting to api.github.com" "repos/o/r"
check "a network error fails at once" '[ "$STATUS" -eq 1 ] && [ "$CALLS" -eq 1 ]'

for arg in -X --method=PATCH -XPUT -f -F --field --raw-field=a=b --input --input=-; do
  run 0 "" "repos/o/r" "$arg" x
  check "a write ($arg) is refused without calling gh" '[ "$STATUS" -eq 2 ] && [ "$CALLS" -eq 0 ] && grep -qF "only reads" <<< "$ERR"'
done

# The waits: a stub `sleep` records them; GH_READ_DELAY at its default of 1.
cat > "$tmp/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$STUB_DIR/sleeps"
STUB
chmod +x "$tmp/bin/sleep"
rm -f "$tmp/calls" "$tmp/sleeps"
touch "$tmp/calls" "$tmp/sleeps"
STATUS=0
OUT=$(STUB_DIR=$tmp FAILS=4 ERROR="gh: HTTP 503" PATH="$tmp/bin:$PATH" \
  bash -c '. "$1"; shift; gh_read "$@"' _ "$root/scripts/lib/gh-retry.sh" repos/o/r 2> "$tmp/err") || STATUS=$?
ERR=$(<"$tmp/err")
CALLS=$(wc -l < "$tmp/calls")
waits=$(tr '\n' ' ' < "$tmp/sleeps")
check "it waits 1, 4 and 9 seconds between the tries" '[ "$waits" = "1 4 9 " ] && [ "$STATUS" -eq 1 ]'
rm "$tmp/bin/sleep"

run 0 "" --allow-escape-sequences "repos/o/r/actions/jobs/1/logs"
check "other flags pass through" '[ "$STATUS" -eq 0 ] && [ "$OUT" = "answer api --allow-escape-sequences repos/o/r/actions/jobs/1/logs" ]'

# --- gh_write ---------------------------------------------------------------
# write <fails> <error> <settled outcome: yes|no> <gh_write arguments after the
# settled command>: the settled command is `settled`, which prints "settled"
# and succeeds when SETTLED=yes. Sets STATUS, OUT, ERR, CALLS, CHECKS.
write() {
  local fails=$1 error=$2 settled=$3
  shift 3
  rm -f "$tmp/calls" "$tmp/checks"
  touch "$tmp/calls" "$tmp/checks"
  STATUS=0
  OUT=$(STUB_DIR=$tmp FAILS=$fails ERROR=$error SETTLED=$settled GH_READ_DELAY=0 PATH="$tmp/bin:$PATH" \
    bash -c '. "$1"; shift
      settled() { echo x >> "$STUB_DIR/checks"; [ "$SETTLED" = yes ] && echo settled; }
      gh_write "$@"' _ "$root/scripts/lib/gh-retry.sh" "$@" < "${STDIN:-/dev/null}" 2> "$tmp/err") || STATUS=$?
  ERR=$(<"$tmp/err")
  CALLS=$(wc -l < "$tmp/calls")
  CHECKS=$(wc -l < "$tmp/checks")
}

write 0 "" no settled -- -X POST repos/o/r/pulls -f title=t
check "a write that works is sent once, not checked, and prints its answer" \
  '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 1 ] && [ "$CHECKS" -eq 0 ] && [ "$OUT" = "answer api -X POST repos/o/r/pulls -f title=t" ]'

write 1 "gh: HTTP 503" no false -- -X PUT repos/o/r
check "an idempotent write (false) is retried on 503" '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 2 ]'

write 1 "gh: HTTP 503" yes settled -- -X POST repos/o/r/pulls
check "a write that failed but was applied is not sent again, and prints the read-back" \
  '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 1 ] && [ "$OUT" = settled ] && grep -qF "but it was applied" <<< "$ERR"'

write 1 "gh: HTTP 503" no settled -- -X POST repos/o/r/pulls
check "a write that failed and was not applied is sent again" \
  '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 2 ] && [ "$CHECKS" -eq 1 ] && [ "$OUT" = "answer api -X POST repos/o/r/pulls" ]'

write 1 "gh: HTTP 422" yes settled -- -X POST repos/o/r/git/refs
check "a 4xx whose read-back shows the write done counts as done" '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 1 ] && [ "$OUT" = settled ]'

write 1 "gh: HTTP 422" no settled -- -X POST repos/o/r/git/refs
check "a 4xx whose read-back fails is not retried" \
  '[ "$STATUS" -eq 1 ] && [ "$CALLS" -eq 1 ] && grep -qx "gh: HTTP 422" <<< "$ERR" && [ -z "$OUT" ]'

write 4 "gh: HTTP 502" no settled -- -X POST repos/o/r/pulls
check "after three retries a write fails, checked after every failure" \
  '[ "$STATUS" -eq 1 ] && [ "$CALLS" -eq 4 ] && [ "$CHECKS" -eq 4 ]'

printf '{"a": 1}' > "$tmp/stdin"
STDIN=$tmp/stdin write 1 "gh: HTTP 503" no false -- -X PUT repos/o/r --input -
check "--input - is read once and sent again on the retry" \
  '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 2 ] && grep -qxF "body {\"a\": 1}" <<< "$OUT"'

write 0 "" no -X PUT repos/o/r
check "a call without -- is a usage error and sends nothing" '[ "$STATUS" -eq 2 ] && [ "$CALLS" -eq 0 ] && grep -qF usage <<< "$ERR"'

write 0 "" no -- -X PUT repos/o/r
check "a call without a settled command is a usage error" '[ "$STATUS" -eq 2 ] && [ "$CALLS" -eq 0 ]'

exit "$failed"
