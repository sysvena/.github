# .github

Shared GitHub configuration for the `sysvena` organization.

## Shared PR gates

`.github/workflows/sysvena-gates.yml` holds the PR gates of every sysvena
repository. The organization ruleset `require-sysvena-gates` requires it on the
default branch of every repository, so GitHub runs it on each pull request.
Repositories need no file for it, and cannot switch it off.

A ruleset runs the gates when a PR is opened, reopened or gets new commits.
A label or title change alone does not run them; the next push does. The
gates read the title, labels and files of the PR from the API, so a manual
re-run of an older run also checks the current PR (see "Re-running the gates").

Gates:

- **PR title** — `<type>(<area>): <summary>`, at most 72 characters.
- **Changeset** — when the repository uses Changesets (`.changeset/config.json`),
  a PR that changes shipped files adds `.changeset/*.md`. Markdown, `docs/`,
  `.ai/`, `.github/` and `.changeset/` changes are exempt, and so is the release
  PR (`changeset-release/*`).
- **Regression test** — a bug fix (PR title type `fix` or label `bug`) changes a
  test, unless the maintainer applied `skip-regression-test`.
- **Repo checks** — `scripts/check-lessons.mjs` when the repository has it, and
  `sysvena-agent-rules check` when `package.json` depends on
  `@sysvena/agent-rules`.

Each repository keeps its own `.github/workflows/ci.yml` only for checks that
are specific to it (for example typecheck, test and build). Workflows that
upload artifacts set `retention-days: 7`.

## Testing the gates

The org ruleset runs the gates from a pinned commit, so a PR here is checked by
the pinned version, not by its own. `.github/workflows/ci.yml` therefore tests
the PR's version:

- **actionlint** (1.7.12, with shellcheck) over every workflow.
- **Gate tests** — `tests/gates/run.sh` runs the real `run:` blocks of
  `sysvena-gates.yml` against fixture pull requests, with a stub `gh`
  (`tests/gates/stub/gh`). Add a case there for every change to a gate.

Run the tests locally with bash, jq and yq v4 (mikefarah):

```sh
tests/gates/run.sh
```

## Re-running the gates

`gh run rerun` cannot find a workflow from another repository (HTTP 404), so
re-run the latest gates run of the PR through the REST API:

```sh
repo=sysvena/<repository>; pr=<number>
sha=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)
run=$(gh api "repos/$repo/actions/runs?head_sha=$sha" \
  --jq '[.workflow_runs[] | select(.name == "sysvena gates")][0].id')
gh api -X POST "repos/$repo/actions/runs/$run/rerun"
```

The API can return the previous state of a PR for a few seconds after a
change. The `Detect checks` job logs the snapshot it checked (`PR snapshot:`);
if it still shows the old title or labels, re-run again.

Changes to the gates go through a PR here and apply to every repository at
once.
