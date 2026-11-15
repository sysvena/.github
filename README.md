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

## Releasing a new version of the gates

The org ruleset `require-sysvena-gates` runs the gates from a pinned commit of
this repository, so a merge here changes nothing until that commit is moved.
`sysvena/gates-canary` is the permanent test repository: the ruleset
`require-sysvena-gates-canary` runs a candidate version there, and production
excludes it.

1. **Before merge:** run the end-to-end test on the PR's head commit:
   `scripts/gates-e2e.sh <commit>`. It points the canary ruleset at the commit,
   opens test PRs on `gates-canary` (valid change; `fix` title without a test,
   then a title edit and a `bug` label with re-runs; title without a type;
   shipped file without a changeset), checks each gate's result, the gates
   version the run reports, the canary's `.nvmrc` Node version and the lessons
   check, and closes the PRs and deletes their branches. Extend it when a gate
   changes.
2. **Merge** the PR (CI must be green).
3. **Promote:** `scripts/gates-promote.sh <merge commit on main>`. It runs the
   end-to-end test again on exactly that commit and moves the production
   ruleset only if it passes. It prints the previous commit.
4. **Roll back** if needed: `scripts/gates-promote.sh --rollback <previous
   commit>` (no end-to-end test: an older version can fail checks added later).

Both scripts need `gh` logged in as an org owner (scopes `repo` and
`admin:org`) and `jq`.

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
