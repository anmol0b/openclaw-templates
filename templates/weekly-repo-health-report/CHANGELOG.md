# Changelog

## 0.1.0

First version.

- The avatar and catalog icon is a Blobster rendered with `openclaw agents render-blobster`.

- A paused weekly automation reads up to 10 repositories with one fixed read-only command each (`node references/fetch.mjs <owner/repo>`): six bounded `gh` reads covering PRs and issues updated in the last 7 days, open PRs and issues, and the newest workflow runs on the default branch.
- fetch.mjs keeps only numbers, dates, states and logins. No title, body, review text, name or label reaches the workspace or the model.
- One snapshot per repository per ISO week (UTC), replaced by a second run in the same week. The report shows the change from the previous week's snapshot, and says "no baseline yet" on the first week instead of showing zero changes.
- Never writes to GitHub. The only writes are its own database and `reports/<week>.md`.
