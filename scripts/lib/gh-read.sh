# shellcheck shell=bash
# gh_read: `gh api` for a read (GET) that retries GitHub's transient server
# errors. Sourced by scripts/gates-promote.sh and tests/e2e/gates-e2e.sh at
# their start, so a later edit of this file cannot change a running script.
#
# GitHub's REST docs give no retry rule for 5xx ("try your request later");
# this follows GitHub's own client, @octokit/plugin-retry 8.1.1: up to 3
# retries, waiting 1, 4 and 9 seconds (the square of the retry number). It
# retries only 500, 502, 503 and 504, and only reads: a write that failed
# with 5xx may have been applied, so repeating it could apply it twice.
# Everything else (4xx, rate limits, network errors) fails at once, as before.
#
# Usage: gh_read <gh api arguments>   (no -X/--method, -f/-F/--field, --input)
# GH_READ_DELAY scales the waits (seconds per unit; default 1; tests use 0).
gh_read() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -X | --method | --method=* | -X* | -f | -F | --field | --field=* | --raw-field | --raw-field=* | --input | --input=*)
        echo "gh_read: only reads; '$arg' is not allowed (use gh api for writes)" >&2
        return 2
        ;;
    esac
  done
  local out err status try=0 retries=3
  out=$(mktemp)
  err=$(mktemp)
  while :; do
    status=0
    gh api "$@" > "$out" 2> "$err" || status=$?
    if [ "$status" -eq 0 ]; then
      cat "$out"
      rm -f "$out" "$err"
      return 0
    fi
    if [ "$try" -lt "$retries" ] && grep -qE 'HTTP (500|502|503|504)\b' "$err"; then
      try=$((try + 1))
      echo "gh_read: $(grep -oE 'HTTP [0-9]{3}' "$err" | head -1) for gh api $*, retry $try of $retries" >&2
      sleep $((try * try * ${GH_READ_DELAY:-1}))
      continue
    fi
    cat "$err" >&2
    rm -f "$out" "$err"
    return "$status"
  done
}
