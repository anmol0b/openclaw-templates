# Changelog

## 0.1.0

First version.

- A paused weekly automation reads up to 10 repositories with one fixed read-only command each (`node references/fetch.mjs <owner/repo>`): one GraphQL query for the owner's login, the repository's labels, and the newest 50 open PRs and 100 open issues with each author's association to the repository.
- Newcomers are authors GitHub marks `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER` or `NONE`, people (not bots) other than the owner. The list shows the ones opened in the last `recent_days` that nobody welcomed yet and the owner has not answered.
- Label candidates are open issues that are unassigned, have no open PR that would close them, have a description of at least 80 characters, and carry none of the allowed labels yet.
- Two writes, each an owner approval for a command the database builds: a welcome comment (from a draft file bound to its exact bytes) and adding one of the allowed labels (`good first issue`, `help wanted` by default) that exists in the repository. Each person is welcomed once per repository. A write counts as done only when a read afterward shows it.
- Issue bodies are read only to count their characters, and comments only to see whether the owner wrote one. Neither reaches the model.
