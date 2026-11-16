# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled run.

## Repositories

- repos: <owner/repo, one per line, at most 10>
  - Repositories you maintain. Reading collaborators needs push access, and requesting a reviewer needs write access.
- db_path: ~/pr-review-nudger.db
  - The database file, outside this workspace, so deleting and re-adding the agent keeps the history.

## Check

- paused: false
  - true makes a scheduled run end at once. The automation's own on and off switch is in the Automations page.
- review_wait_days: 2
  - A PR waiting this many days for a review is stuck (1 to 60). Counted from the latest commit, or from when it was opened.
- author_wait_days: 7
  - A PR waiting this many days on its author after changes were requested is stuck (1 to 60).
- conflict_wait_days: 3
  - A PR with a merge conflict and no update for this many days is stuck (1 to 60).
- skip_bot_prs: true
  - true leaves out PRs opened by bots such as Dependabot and Renovate.
- max_requests_per_run: 10
  - Most new requests (suggested GitHub writes) prepared per run.

## Actions

- allowed_actions: request-review, comment
  - Which writes the agent may suggest. Any of: request-review, comment. Each one still needs your OK for the exact command.
  - request-review only names a reviewer from CODEOWNERS, collaborators with push access, or maintainers who reviewed recently.
- nudge_window_days: 3
  - At most one nudge comment per PR in this many days (1 to 30).
