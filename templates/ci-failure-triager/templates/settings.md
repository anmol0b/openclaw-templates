# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled cycle.

## Repositories

- repos: <owner/repo, one per line, at most 5>
  - Repositories whose GitHub Actions failures you want triaged. Your `gh` login must be able to read them.
  - Setup registers each one in the database.
- db_path: ~/ci-failure-triager.db
  - The database file, outside this workspace, so deleting and re-adding the agent keeps the history.

## Cycles

- paused: false
  - true makes a scheduled cycle end at once. The automation's on and off switch is in the Automations page.
- max_triage_per_cycle: 10
  - Most failed runs triaged per cycle (1 to 30). The rest wait, oldest first.
- max_requests_per_cycle: 5
  - Most new requests (suggested GitHub writes) prepared per cycle.

## Actions

- allowed_actions: rerun, issue
  - Which writes the agent may suggest. Any of: rerun, issue, pr-comment. Each one still needs your OK for the exact command.
- issue_branches: main
  - Branches where a new break may get an issue suggestion, one per line. Usually your default branch.

## Digest

- digest_style: short
  - short: gaps, new breaks and requests. full: one line per triaged run.
