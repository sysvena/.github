# Security policy

This repository holds the pull-request checks and reusable workflows of the
sysvena organisation.

## Scope

This policy covers the code in this repository: workflows, scripts and their
tests. The other repositories of the organisation are private; report a
problem you believe concerns one of them the same way.

## Supported versions

Only the `main` branch. There are no releases: callers pin a commit, and fixes
are not applied to older commits.

## Reporting a vulnerability

Do not open a public issue, discussion or pull request for a security problem.

Report it privately through GitHub:
[Report a vulnerability](https://github.com/sysvena/.github/security/advisories/new).
This is the only channel; there is no e-mail address.

Include:

- the workflow or script, and the commit;
- what an attacker controls and what they gain;
- the steps to reproduce it.

## What to expect

We acknowledge a report within 7 days. We agree the fix and the date of
disclosure with you, at the latest 90 days after the report, and publish a
GitHub security advisory that credits you unless you ask otherwise. There is
no bug bounty.
