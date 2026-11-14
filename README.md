# .github

Shared GitHub configuration for the `sysvena` organization.

## Shared PR gates

`.github/workflows/sysvena-gates.yml` holds the PR gates of every sysvena
repository. The organization ruleset `require-sysvena-gates` requires it on the
default branch of every repository, so GitHub runs it on each pull request.
Repositories need no file for it, and cannot switch it off.

Gates:

- **PR title** — `<type>(<area>): <summary>`, at most 72 characters.
- **Changeset** — when the repository uses Changesets (`.changeset/config.json`),
  a PR that changes shipped files adds `.changeset/*.md`. Markdown, `docs/`,
  `.ai/`, `.github/` and `.changeset/` changes are exempt, and so is the release
  PR (`changeset-release/*`).
- **Regression test** — a PR labelled `bug` changes a test, unless the
  maintainer applied `skip-regression-test`.
- **Repo checks** — `scripts/check-lessons.mjs` when the repository has it, and
  `sysvena-agent-rules check` when `package.json` depends on
  `@sysvena/agent-rules`.

Each repository keeps its own `.github/workflows/ci.yml` only for checks that
are specific to it (for example typecheck, test and build). Workflows that
upload artifacts set `retention-days: 7`.

Changes to the gates go through a PR here and apply to every repository at
once.
