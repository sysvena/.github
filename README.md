# .github

Shared GitHub configuration for the `sysvena` organization.

## Shared PR gates

`.github/workflows/sysvena-gates.yml` is a reusable workflow that every sysvena
repository calls from its own `.github/workflows/ci.yml`:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, edited, labeled, unlabeled]

permissions:
  contents: read
  pull-requests: read

jobs:
  sysvena:
    uses: sysvena/.github/.github/workflows/sysvena-gates.yml@main
    permissions:
      contents: read
      pull-requests: read
      packages: read
    with:
      changeset: true     # require a changeset for shipped changes
      agent-rules: false  # true in Open Mercato apps
```

Gates:

- **PR title** — `<type>(<area>): <summary>`, at most 72 characters.
- **Changeset** — a PR that changes shipped files adds `.changeset/*.md`.
  Markdown, `docs/`, `.ai/`, `.github/` and `.changeset/` changes are exempt,
  and so is the release bot's version PR.
- **Regression test** — a PR labelled `bug` changes a test, unless the
  maintainer applied `skip-regression-test`.
- **Repo checks** — `scripts/check-lessons.mjs` when the repo has it, and
  `sysvena-agent-rules check` when `agent-rules: true`.

Changes to these gates go through a PR here and apply to every repository at
once. Workflows that upload artifacts set `retention-days: 7`.
