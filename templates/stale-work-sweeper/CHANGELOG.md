# Changelog

## 0.1.0

First version.

- A paused weekly automation reads up to 10 repositories with one fixed read-only command each (`node references/fetch.mjs <owner/repo>`): the owner's login, the default branch, up to 100 branches with merge status in one GraphQL call, the owner's open PRs and the open issues assigned to them.
- One cleanup list, safest first: merged branches (including squash merges through a PR with the same head), idle PRs with CI and conflict state, idle assigned issues, then unmerged branches for a look. Only the owner's own work.
- Every GitHub write (delete a merged branch, comment, close, unassign) is an owner approval for a command the database builds, bound to the branch head or last activity the owner saw and, for a comment, to the exact draft bytes. Used once. A deleted branch's SHA is kept with a restore command.
- README and CLAW.md list exactly which text reaches the model (your own PR and issue titles and branch names).
