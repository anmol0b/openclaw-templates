# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled run.

## Repositories

- repos: <owner/repo, one per line, at most 10>
  - Repositories to report on. Your `gh` login must be able to read them. Nothing is ever written to them.
- db_path: ~/weekly-repo-health-report.db
  - The database file, outside this workspace, so deleting and re-adding the agent keeps the weekly history.

## Report

- paused: false
  - true makes a scheduled run end at once. The automation's own on and off switch is in the Automations page.
- stale_pr_days: 14
  - An open PR with no update for this many days counts as stale (1 to 365).
- stale_issue_days: 30
  - An open issue with no update for this many days counts as stale (1 to 365).
- exclude_bot_prs: true
  - true leaves PRs opened by bots (dependency updates and the like) out of every PR number. false counts them.

## Read limits (fixed, for reference)

These are set in references/fetch.mjs so the read command never changes. When a read hits its limit, the report says that number may be low.

- PRs and issues updated in the last 7 days: 300 each
- Open PRs and open issues: 500 each
- Workflow runs on the default branch: the newest 200
