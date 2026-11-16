# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled run.

## Repositories

- repos: <owner/repo, one per line, at most 10>
  - Repositories whose security alerts you can see. GitHub shows them to admins, people with the security manager role, and people the admins chose; the digest says when this login cannot read them.
- db_path: ~/security-alert-triager.db
  - The database file, outside this workspace, so deleting and re-adding the agent keeps the history.

## Run

- paused: false
  - true makes a scheduled run end at once. The automation's own on and off switch is in the Automations page.
- max_requests_per_run: 5
  - Most new tracking-issue requests a scheduled run prepares.

## Actions

- allowed_actions: dismiss
  - Which writes the agent may prepare. Any of: dismiss, issue. Each one still needs your OK for the exact command.
  - dismiss is only ever prepared when you ask for it in chat, with a reason you chose. A scheduled run never suggests dismissing an alert.
  - issue opens a tracking issue for a Dependabot alert, built from its GHSA ID, package, severity and patched version. On a public repository that issue is public. Code scanning alerts never get an issue.
- issue_min_severity: high
  - With issue allowed, a scheduled run prepares issue requests for open Dependabot alerts at this severity or higher (critical, high, medium or low) that no bot PR fixes yet.
