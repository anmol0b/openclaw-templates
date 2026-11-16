# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled run.

## Repositories

- repos: <owner/repo, one per line, at most 10>
  - Repositories you maintain, where newcomers open PRs and issues.
- db_path: ~/first-timer-welcomer.db
  - The database file, outside this workspace, so deleting and re-adding the agent keeps who was welcomed.

## Welcome pass

- paused: false
  - true makes a scheduled run end at once. The automation's own on and off switch is in the Automations page.
- recent_days: 14
  - PRs and issues opened in this many days are listed (1 to 90).
- max_requests_per_run: 10
  - Most new requests (suggested GitHub writes) prepared per run.
- welcome_note: <optional, one sentence added to every welcome, such as a link to CONTRIBUTING.md>

## Actions

- allowed_actions: welcome, add-label
  - Which writes the agent may suggest. Any of: welcome, add-label. Each one still needs your OK for the exact command.
- allowed_labels: good first issue, help wanted
  - 1 to 5 labels the agent may suggest, spelled exactly as in your repositories. Letters, digits, spaces and . _ : / - only.
  - After changing this line, ask the agent to update the repositories (it runs add-repo again).
- max_label_suggestions: 3
  - Most label suggestions per run.
