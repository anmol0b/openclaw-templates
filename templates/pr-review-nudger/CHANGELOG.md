# Changelog

## 0.1.0

First version.

- The avatar and catalog icon is a Blobster rendered with `openclaw agents render-blobster`.

- A paused weekday automation reads up to 10 repositories with one fixed read-only command each (`node references/fetch.mjs <owner/repo>`): the owner's login, the 30 most recently opened PRs, collaborators with push access, and the first CODEOWNERS file GitHub would use. PR, comment and review bodies are dropped before anything is written.
- Stuck PRs in three categories, with thresholds from settings: waiting on review (no maintainer review since the latest commit), waiting on the author (changes requested, nothing pushed since), and merge conflicts. Drafts, approved PRs and, by default, bot PRs are left out.
- Reviewer suggestions only from CODEOWNERS users, push collaborators and maintainer reviewers, ranked by source and then by who has the fewest open requests. Never the author, the owner or someone already requested.
- Every GitHub write (request a reviewer, post a nudge comment) is an owner approval for a command the database builds, bound to the PR head and update time the owner saw and, for a comment, to the exact draft bytes. Used once, at most one nudge per PR per window, and recorded as done only when a fresh read shows it on GitHub.
- README and CLAW.md list exactly which text reaches the model (PR titles and author logins).
