#!/usr/bin/env bash
# The conditions are strings that check() evaluates after each run, so their
# variables must not expand where they are written.
# shellcheck disable=SC2016,SC2034
# Tests retry_download (scripts/lib/retry-download.sh) with a stub command
# that fails a set number of times with a given status before it works.
#
# Usage: tests/scripts/retry-download.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
ok() { echo "ok     - $1"; }
not_ok() { echo "not ok - $1"; failed=1; }

# The stub: fails the first $FAILS calls with status $CODE and a message on
# stderr, then prints "fetched" and its arguments. Every call is logged.
mkdir "$tmp/bin"
cat > "$tmp/bin/fetch" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
n=$(wc -l < "$STUB_DIR/calls")
if [ "$n" -le "$FAILS" ]; then
  echo "TypeError: terminated (read ECONNRESET)" >&2
  exit "$CODE"
fi
echo "fetched $*"
STUB
chmod +x "$tmp/bin/fetch"

# run <fails> <code> <retry_download arguments...>: sets STATUS, OUT, ERR, CALLS.
run() {
  local fails=$1 code=$2
  shift 2
  rm -f "$tmp/calls"
  touch "$tmp/calls"
  STATUS=0
  OUT=$(STUB_DIR=$tmp FAILS=$fails CODE=$code GH_READ_DELAY=0 PATH="$tmp/bin:$PATH" \
    bash -c '. "$1"; shift; retry_download "$@"' _ "$root/scripts/lib/retry-download.sh" "$@" 2> "$tmp/err") || STATUS=$?
  ERR=$(<"$tmp/err")
  CALLS=$(wc -l < "$tmp/calls")
}

check() { if eval "$2"; then ok "$1"; else not_ok "$1 (status $STATUS, calls $CALLS, out '$OUT', err '$ERR')"; fi; }

run 0 1 fetch yarn@4
check "a download that works runs once" \
  '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 1 ] && [ "$OUT" = "fetched yarn@4" ] && [ -z "$ERR" ]'

run 1 1 fetch yarn@4
check "a failed download is retried, then works" \
  '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 2 ] && [ "$OUT" = "fetched yarn@4" ]'

run 1 1 fetch yarn@4
check "the command's own message is shown" 'grep -qF "read ECONNRESET" <<< "$ERR"'

run 1 1 fetch yarn@4
check "a retry says what it retries" \
  'grep -qF "retry_download: '"'"'fetch yarn@4'"'"' failed with status 1, retry 1 of 3" <<< "$ERR"'

run 3 1 fetch yarn@4
check "three failures are retried three times, then it works" '[ "$STATUS" -eq 0 ] && [ "$CALLS" -eq 4 ]'

run 4 7 fetch yarn@4
check "after three retries it fails with the command's status" \
  '[ "$STATUS" -eq 7 ] && [ "$CALLS" -eq 4 ] && grep -qF "failed with status 7 after 3 retries" <<< "$ERR"'

run 0 1 fetch "two words" --clobber
check "arguments pass through unchanged" '[ "$STATUS" -eq 0 ] && [ "$OUT" = "fetched two words --clobber" ]'

run 0 1
check "a call without a command is a usage error" '[ "$STATUS" -eq 2 ] && [ "$CALLS" -eq 0 ] && grep -qF usage <<< "$ERR"'

# The waits: a stub `sleep` records them; GH_READ_DELAY at its default of 1.
cat > "$tmp/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$STUB_DIR/sleeps"
STUB
chmod +x "$tmp/bin/sleep"
rm -f "$tmp/calls" "$tmp/sleeps"
touch "$tmp/calls" "$tmp/sleeps"
STATUS=0
OUT=$(STUB_DIR=$tmp FAILS=4 CODE=1 PATH="$tmp/bin:$PATH" \
  bash -c '. "$1"; shift; retry_download "$@"' _ "$root/scripts/lib/retry-download.sh" fetch x 2> "$tmp/err") || STATUS=$?
ERR=$(<"$tmp/err")
CALLS=$(wc -l < "$tmp/calls")
waits=$(tr '\n' ' ' < "$tmp/sleeps")
check "it waits 1, 4 and 9 seconds between the tries" '[ "$waits" = "1 4 9 " ] && [ "$STATUS" -eq 1 ]'
rm "$tmp/bin/sleep"

exit "$failed"
