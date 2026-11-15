# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled run.

## Repositories

- repos: <owner/repo, one per line, at most 5>
  - Repositories with Dependabot or Renovate turned on. Your `gh` login must be able to read them.
  - Setup registers each one in the database. Add one later by editing this list and asking the agent to register it.
- db_path: ~/dependency-update-reviewer.db
  - The database file, outside this workspace, so deleting and re-adding the agent keeps the history.

## Runs

- paused: false
  - true makes a scheduled run end at once. The automation's own on and off switch is in the Automations page.
- max_reviews_per_run: 20
  - Most PRs reviewed per run (1 to 50). The rest wait for the next run, oldest change first.
- max_requests_per_run: 5
  - Most new requests (suggested GitHub writes) prepared per run.

## Actions

- allowed_actions: approve
  - Which writes the agent may suggest. Any of: approve, comment, bot-command. Each one still needs your OK for the exact command.
  - approve is only suggested for PRs that look safe with passing CI. bot-command means only `@dependabot rebase` or `@dependabot recreate`.
- comment_on_holds: false
  - true lets the agent suggest a short comment on PRs that need a look, saying what is being checked.

## Digest

- digest_style: short
  - short: counts, then one line per PR that needs you. full: one line per open PR.
