# .github

Shared GitHub configuration for the `sysvena` organization.

## Organization rulesets

All on the default branch of the repositories they target, with **no bypass
actors**: nobody, an organization owner or an agent acting as one included,
can merge a PR that breaks them or push to the default branch directly.

| Ruleset | Targets | Requires |
| --- | --- | --- |
| `protect-default-branch` | all repositories | changes through a PR (squash only), linear history, no force push or deletion |
| `require-sysvena-gates` | all except `gates-canary` | the gates (`sysvena-gates.yml`) at the pinned production commit |
| `require-sysvena-gates-canary` | `gates-canary` | the gates at the commit under test |
| `require-build` | custom property `ci-build` = `true` | the check `CI result` from GitHub Actions, branch up to date; CodeQL code scanning results with no open alert (thresholds: all alerts, all security alerts) |

A repository whose CI has a `CI result` job (it `needs` every other job and
fails unless all succeeded) gets `ci-build` = `true`; only organization owners
can change the property.

The CodeQL check of default setup reports "success" even when it finds an
alert; the ruleset rule is what blocks the merge.

In an emergency an organization owner can set a ruleset to "Disabled" and back
to "Active" afterwards; both changes are in the organization audit log. A PR
opened by a workflow with `GITHUB_TOKEN` (for example the release PR) gets its
runs in an approval-required state: approve them in the PR ("Approve workflows
to run").

## Security configuration

The organization code security configuration `sysvena` is enforced on every
repository and is the default for new ones. It uses GitHub Secret Protection
and GitHub Code Security (one active committer each) and turns on:

- secret scanning with push protection (a push that contains a secret is
  refused with `GH013`), non-provider patterns and AI-detected generic secrets
  as alerts, and validity checks;
- delegated bypass for push protection with no bypass reviewers: only
  organization owners can bypass a block; anyone else sends a bypass request
  that an owner approves or denies;
- CodeQL code scanning, default setup (languages detected per repository);
- the dependency graph, Dependabot alerts and Dependabot security updates;
- private vulnerability reporting stays off.

Dependency review in the gates needs Code Security and the dependency graph.

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
  test (a file under `__tests__/`, `__integration__/` or `tests/`, or a
  `*.test.*` / `*.spec.*` JS or TS file), unless the maintainer applied
  `skip-regression-test`.
- **Repo checks** — `scripts/check-lessons.mjs` when the repository has it, and
  `sysvena-agent-rules check` when `package.json` depends on
  `@sysvena/agent-rules`.
- **Dependency review** — in every repository, a PR must not add a dependency
  with a known vulnerability (any severity, runtime and development scope) or
  with a licence outside the policy (see "Dependency review").

Each repository keeps its own `.github/workflows/ci.yml` only for checks that
are specific to it (for example typecheck, test and build). Workflows that
upload artifacts set `retention-days: 7`.

## Dependency review

The job runs `actions/dependency-review-action`, the way GitHub documents
enforcing dependency review across an organization (a ruleset that requires a
workflow running it). It needs GitHub Code Security on private repositories;
the org security configuration `sysvena` enables it, with the dependency
graph, on every repository. The policy and its sources are in the comment above
the job in `sysvena-gates.yml`; in short:

- **Vulnerabilities:** every severity, scopes runtime, development and unknown.
  No exceptions; if a vulnerability cannot be fixed, its GHSA id goes into
  `allow-ghsas` with a comment, through a PR here.
- **Licences:** an allow list (`ALLOW_LICENSES`) of licences that both Google's
  classification and the Blue Oak Council list rate permissive, plus
  CC-BY-4.0 for data. A dependency whose licence the dependency graph cannot
  detect fails too.
- **Exceptions** (for example a weak-copyleft package such as one under MPL-2.0
  or LGPL-3.0, or one with no detected licence) live only in
  `LICENSE_EXCEPTIONS` in that job: `{purl, license, reason}`, with the purl
  without a version and the licence as the dependency graph reports it
  (`NOASSERTION` when none). An exception covers every version, but the gate
  fails when an added version reports another licence. A repository cannot add
  its own exceptions, so a PR cannot loosen its own check; an exception reaches
  the repositories through the release steps below.
- **Own packages** (`@sysvena/*` from GitHub Packages) have no licence data in
  the dependency graph, so each one needs an exception (`NOASSERTION`) when it
  is first published.

The job summary of the run lists every dependency change, its licence and its
OpenSSF Scorecard score.

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
   `tests/e2e/gates-e2e.sh <commit>`. It points the canary ruleset at the commit,
   opens test PRs on `gates-canary` (valid change; `fix` title without a test,
   then a title edit and a `bug` label with re-runs; title without a type;
   shipped file without a changeset; a vulnerable development dependency, a
   dependency under MPL-2.0, an action with no licence, a clean dependency and
   an own package with an exception for dependency review), checks each gate's result, the gates
   version the run reports, the canary's `.nvmrc` Node version and the lessons
   check, and closes the PRs and deletes their branches. Extend it when a gate
   changes.
2. **Merge** the PR (CI must be green).
3. **Promote:** `scripts/gates-promote.sh <merge commit on main>`. It runs the
   end-to-end test again on exactly that commit and moves the production
   ruleset only if it passes. It prints the previous commit.
4. **Roll back** if needed: `scripts/gates-promote.sh --rollback <previous
   commit>` (no end-to-end test: an older version can fail checks added later).

Both scripts need `gh` logged in as an org owner (scopes `repo`, `admin:org`
and `workflow`, for the test PR that adds a workflow file) and `jq`.

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
