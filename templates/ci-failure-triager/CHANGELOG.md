# Changelog

## 0.1.0

First version.

- A paused weekday automation reads failed GitHub Actions runs on up to 5 repositories with one fixed read-only command per repository (`node references/fetch.mjs <owner/repo>`), so the owner can allow it once.
- Each failed run attempt's log is read once and cut to at most 5 error lines and a 20-line, 3000-character excerpt around the first error, with ANSI codes (raw and caret form) and timestamps removed and secret-looking strings masked. Each failed job gets a failure signature that matches the same failure on other runs.
- Untrusted text is disclosed in CLAW.md and the README: exactly which GitHub text reaches the model, with its caps. No commit bodies, PR titles, PR bodies or comments are read.
- Hints from the run history: flaky (the same commit passed), new break (first failure after a pass), still broken, or unclear, with the first bad commit when the history shows it.
- Suggested writes: rerun failed jobs, open one issue per failure signature, or comment on the open PR whose head failed. Each is an owner approval for a command the database builds, bound to the run attempt as seen and, for text, to the exact draft bytes. Used once. Refusals name their reason.
