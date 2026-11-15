# Settings

Edit the values after the colons. The agent reads this file at the start of every task and never changes it in a scheduled run.

## Repositories

- repos: <owner/repo, one per line, at most 5>
  - Repositories you release by hand. Your `gh` login must be able to read them, and to create releases for the drafts you approve.
- db_path: ~/release-notes-drafter.db
  - The database file, outside this workspace.

## Notes

- list_bot_prs: false
  - true lists pull requests from bots (dependency updates and the like) under Internal. false leaves them out of the notes.
- include_pr_bodies: false
  - false: the drafter sorts pull requests from their labels, title prefixes and titles only. This is the default.
  - true: it also reads up to 1500 characters of each pull request's description. Turn it on only for repositories you trust, since descriptions are written by anyone who opens a pull request.
- zero_major_breaking_is_minor: true
  - While the version is 0.x, a breaking change bumps the minor version (0.9.3 to 0.10.0). false bumps the major (0.9.3 to 1.0.0).
- title_format: {name} {tag}
  - The release title. `{name}` is the repository name, `{tag}` the new tag. Letters, digits, spaces and `. _ : + ( ) -` only.
- include_compare_link: true
  - Ends the notes with a "Full changelog" link from the base tag to the new one. It works once the release is published.

## Runs

- paused: false
  - true makes a scheduled run end at once.
