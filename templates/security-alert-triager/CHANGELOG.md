# Changelog

## 0.1.0

First version.

- A paused weekday automation reads up to 10 repositories with one fixed read-only command each (`node references/fetch.mjs <owner/repo>`): open and recently dismissed Dependabot and code scanning alerts, and the open Dependabot and Renovate PRs.
- Each source is reported as having alerts, having none, turned off, or not readable with this login, using the messages GitHub returns. Setup stops when the login cannot read a repository's alerts.
- One digest: Dependabot alerts grouped by package and code scanning alerts grouped by rule, most severe first, with the bot PR that already fixes a Dependabot alert (or does not reach the patched version).
- Two writes, each an owner approval for a command the database builds, bound to the alert as the owner saw it and used once: dismiss an alert with one of GitHub's fixed reasons (an optional comment is read from a hash-bound draft file), or open a tracking issue for a Dependabot alert from its GHSA ID, package, severity and patched version only. Code scanning alerts never get an issue.
- A dismissal is recorded as done only when a fetch after it shows the alert dismissed with the approved reason.
- Advisory descriptions, code scanning messages and help text are dropped by the fetch and never reach the model.
