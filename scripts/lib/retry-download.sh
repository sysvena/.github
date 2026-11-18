# shellcheck shell=bash
# retry_download: runs a download command again when it fails, for commands
# that only fetch a pinned file and verify it, so running them again changes
# nothing: `corepack install` (the Yarn release in package.json's
# `packageManager`, checked against its hash) and `gh release download
# --clobber` (followed by a SHA-256 check). Sourced by the gates workflow.
#
# Neither tool retries on its own: Corepack fetches once (nodejs/corepack
# sources/httpUtils.ts) and gh retries no download. A connection that breaks
# mid-download ends Corepack with an unhandled stream error ("TypeError:
# terminated", cause "read ECONNRESET"), not with an HTTP status, so a
# failure cannot be sorted into transient or not; every failure is retried,
# and a lasting one (a wrong hash, a missing release) fails after the last
# try with the command's own message and status.
#
# The tries follow scripts/lib/gh-retry.sh (GitHub's own client,
# @octokit/plugin-retry 8.1.1): up to 3 retries, waiting 1, 4 and 9 seconds.
# GH_READ_DELAY scales the waits (seconds per unit; default 1; tests use 0).
#
# Usage: retry_download <command> [arguments...]
retry_download() {
  [ $# -gt 0 ] || { echo "retry_download: usage: retry_download <command> [arguments...]" >&2; return 2; }
  local status try=0 retries=3
  while :; do
    status=0
    "$@" || status=$?
    if [ "$status" -eq 0 ]; then
      return 0
    fi
    if [ "$try" -lt "$retries" ]; then
      try=$((try + 1))
      echo "retry_download: '$*' failed with status $status, retry $try of $retries" >&2
      sleep $((try * try * ${GH_READ_DELAY:-1}))
      continue
    fi
    echo "retry_download: '$*' failed with status $status after $retries retries" >&2
    return "$status"
  done
}
