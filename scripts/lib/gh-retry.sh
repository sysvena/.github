# shellcheck shell=bash
# gh_read and gh_write: `gh api` that survives GitHub's transient server
# errors. Sourced by scripts/gates-promote.sh and tests/e2e/gates-e2e.sh at
# their start, so a later edit of this file cannot change a running script,
# and by the gates workflow (from the commit the gates run from).
#
# GitHub's REST docs give no retry rule for 5xx ("try your request later");
# this follows GitHub's own client, @octokit/plugin-retry 8.1.1: up to 3
# retries, waiting 1, 4 and 9 seconds (the square of the retry number), but
# only on 500, 502, 503 and 504. Everything else (4xx, rate limits, network
# errors) fails at once with gh's own message and status. A failed try
# prints nothing on stdout.
# GH_READ_DELAY scales the waits (seconds per unit; default 1; tests use 0).

# gh_read: a read (GET). It refuses write options, so a write cannot be
# retried here by mistake.
# Usage: gh_read <gh api arguments>   (no -X/--method, -f/-F/--field, --input)
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

# gh_write: `gh api` for a write, retried on the same server errors as
# gh_read, but only after a read shows the write did not happen: a write that
# failed with 5xx may still have been applied.
#
# Usage: gh_write <settled command...> -- <gh api arguments>
#   The settled command (usually a function and its arguments) runs after any
#   failure; when it succeeds, the write counts as done and its output is
#   printed instead of the answer of the write (for example the number of a
#   PR that a failed create did open). Use `false` for an idempotent write
#   (PUT of a whole resource, PATCH to fixed values, adding a label): it is
#   then retried on 5xx only, as repeating it changes nothing.
# `--input -` is read once and sent again on a retry.
gh_write() {
  local -a settled=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    settled+=("$1")
    shift
  done
  [ "${1:-}" = -- ] && [ ${#settled[@]} -gt 0 ] || { echo "gh_write: usage: gh_write <settled command...> -- <gh api arguments>" >&2; return 2; }
  shift
  local -a args=("$@")
  local i body=""
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = --input ] && [ "${args[$((i + 1))]:-}" = - ]; then
      body=$(mktemp)
      cat > "$body"
      args[i + 1]=$body
    fi
  done
  local out err done_out status try=0 retries=3
  out=$(mktemp)
  err=$(mktemp)
  done_out=$(mktemp)
  while :; do
    status=0
    gh api "${args[@]}" > "$out" 2> "$err" || status=$?
    if [ "$status" -eq 0 ]; then
      cat "$out"
      break
    fi
    if [ "${settled[*]}" != false ] && "${settled[@]}" > "$done_out" 2> /dev/null; then
      echo "gh_write: $(grep -oE 'HTTP [0-9]{3}' "$err" | head -1) for gh api ${args[*]}, but it was applied" >&2
      cat "$done_out"
      status=0
      break
    fi
    if [ "$try" -lt "$retries" ] && grep -qE 'HTTP (500|502|503|504)\b' "$err"; then
      try=$((try + 1))
      echo "gh_write: $(grep -oE 'HTTP [0-9]{3}' "$err" | head -1) for gh api ${args[*]}, retry $try of $retries" >&2
      sleep $((try * try * ${GH_READ_DELAY:-1}))
      continue
    fi
    cat "$err" >&2
    break
  done
  rm -f "$out" "$err" "$done_out" ${body:+"$body"}
  return "$status"
}
