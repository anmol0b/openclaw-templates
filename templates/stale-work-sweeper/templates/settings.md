# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled run.

## Repositories

- repos: <owner/repo, one per line, at most 10>
  - Repositories where you have branches, PRs or assigned issues. List your forks for their branches, and the upstream repositories for the PRs you opened there.
- db_path: ~/stale-work-sweeper.db
  - The database file, outside this workspace, so deleting and re-adding the agent keeps the history.

## Sweep

- paused: false
  - true makes a scheduled run end at once. The automation's own on and off switch is in the Automations page.
- stale_days: 30
  - No activity for this many days counts as stale (1 to 365). Branches: days since the last commit. PRs and issues: days since the last update.
- max_requests_per_run: 10
  - Most new requests (suggested GitHub writes) prepared per run.

## Actions

- allowed_actions: delete-branch, unassign, comment
  - Which writes the agent may suggest. Any of: delete-branch, comment, close, unassign. Each one still needs your OK for the exact command.
  - delete-branch is only ever suggested for a branch that is fully merged, has no open PR, and is not protected or the default branch.
