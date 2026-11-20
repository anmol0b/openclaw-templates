# Changelog

## 0.1.2

- The avatar and catalog icon is now a Blobster rendered with `openclaw agents render-blobster`. Its design is in `blobsters/dependency-update-reviewer.json` at the repository root.

## 0.1.1

- Fix: an approval is pinned to the exact commit you reviewed. The approve command now posts the review through GitHub's reviews API with `commit_id` set to that commit (`gh api -X POST repos/<repo>/pulls/<n>/reviews -f event=APPROVE -f commit_id=<sha>`). Before, `gh pr review --approve` approved whatever the head was when it ran, so a bot push between the final check and the command could receive your approval. ClawScan flagged this in 0.1.0.
- approval-outcome records an approve as done only when the review landed on the approved commit (`review_commit_id`, printed by the command).

## 0.1.0

First version.

- A paused weekday automation reads open Dependabot and Renovate PRs on up to 5 repositories, with one fixed read-only command per repository (`node references/fetch.mjs <owner/repo>`: two `gh pr list` reads, no shell, one retry on a GitHub 5xx).
- Deterministic parsing of package, ecosystem, from and to versions and bump type from both bots' title and body formats, including Dependabot groups and Renovate multi-package tables. Signals for major bumps, 0.x minor bumps, breaking, removal, deprecation and runtime-floor notes, and security fixes. The bots' own help text is ignored.
- A fact-based lane for every PR (looks safe, needs a look, blocked by CI). The agent may only make a lane stricter after reading the notes.
- Approve, comment and a fixed `@dependabot rebase` or `recreate` comment, each an owner approval for a command the database builds, bound to the PR's head SHA and update time, used once. Approve needs a looks-safe review of the current head and passing CI. Never merges or closes.
- The model sees at most 8 release-note lines of 200 characters that raised a signal, never the PR body, which is no longer stored. README and CLAW.md list what reaches the model.
