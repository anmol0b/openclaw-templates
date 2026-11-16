# Security Alert Triager

An OpenClaw Template for maintainers who have Dependabot alerts or code scanning turned on and do not read the Security tab every day. Each weekday it reads the alerts on your repositories, groups them by package and rule, puts the most severe first, and tells you which ones a Dependabot or Renovate PR already fixes. When a repository has alerts turned off, or your login cannot read them, it says so instead of reporting "no alerts". Nothing changes on GitHub until you OK the exact command.

## What a morning looks like

```
Security alerts 2026-11-16: 6 Dependabot, 3 code scanning.

What could be read
- example-org/example-docs: Dependabot turned off, code scanning not readable with this login
  (check your role on this repository and that gh has the repo or security_events scope)

Dependabot, by package
- critical example-org/example-repo npm/lodash: 2 alerts [1,2], GHSA-aaaa-bbbb-cccc, GHSA-dddd-eeee-ffff, patched in 4.17.21, open 76 days
  Fixed by bot PR #101, merge it.
- high example-org/example-repo npm/@example/parser: 1 alert [4], GHSA-kkkk-mmmm-pppp, no fix yet, open 37 days
- medium example-org/example-repo pip/requests: 1 alert [3], GHSA-gggg-hhhh-jjjj, patched in 2.32.0, open 46 days
  Bot PR #201 does not reach the patched version.

Code scanning, by rule
- critical example-org/example-repo js/sql-injection (CodeQL): 2 alerts [50,51], at src/db.js:12, src/api.js:40, open 62 days

Requests
- [7] example-org/example-repo dependabot alert 4: issue
  Would run: gh issue create --repo example-org/example-repo --title 'Security: GHSA-kkkk-mmmm-pppp in npm package @example/parser (high)' --body 'Dependabot alert 4 in this repository: ...'

Reply "approve <id>", "no <id>", or "dismiss <repo> <source> <number> as <reason>".
```

You answer "dismiss example-org/example-repo code-scanning 52 as used in tests". The agent reads the repository again, shows you the exact `gh api -X PATCH` command with that reason, and runs it only after you approve it. It then reads again and records the dismissal as done only if GitHub shows the alert dismissed with that reason.

## What it reads, and what each answer means

| Source | Read | `disabled` | `no_access` |
|--------|------|------------|-------------|
| Dependabot alerts | 100 most recently updated open, 30 dismissed | GitHub says Dependabot alerts are turned off | GitHub says you are not authorized |
| Code scanning alerts | 100 most recently updated open, 30 dismissed | No analysis has run (code scanning not set up) | GitHub says you are not authorized |
| Dependabot and Renovate PRs | up to 100 open each | | |

A source that was read and has nothing open shows as "no open alerts". The digest names every source that is turned off or not readable.

## Access you need

- A role that can see security alerts on each repository: admin, the security manager role, or someone an admin chose.
- `gh` logged in with the `repo` scope (the default for `gh auth login`), or `security_events` (plus `public_repo` for public repositories). With a fine-grained token: "Dependabot alerts" and "Code scanning alerts" read, write for dismissals, and "Issues" write for tracking issues.

Setup runs one pass and stops with `token_lacks_alert_access` if any repository's alerts cannot be read, so you find out on day one.

## How you stay in control

- Two writes, each its own request with the exact command shown:
  - **Dismiss** an alert with one of GitHub's fixed reasons (Dependabot: `fix_started`, `inaccurate`, `no_bandwidth`, `not_used`, `tolerable_risk`; code scanning: `false positive`, `won't fix`, `used in tests`). Only when you ask, with the reason you choose. An optional comment comes from a draft file in your words, at most 280 bytes, bound to its exact bytes.
  - **Open a tracking issue** for a Dependabot alert, if you allow `issue`. The title and body are built from the GHSA ID, package, severity and patched version, and a link to the alert that only people with access can open. Nothing else from the advisory goes in. On a public repository the issue is public.
- Code scanning alerts never get an issue. They point at a file and line in your code, and a public issue would point at a hole you have not fixed yet.
- A request is tied to the alert's last update as you saw it. If the alert changes, the request is refused and asked again. Each approval is used once.
- Scheduled runs never write to GitHub and never prepare a dismissal.
- On top of that, setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the read commands once; write commands prompt every time.

These are the agent's rules plus OpenClaw's approval prompt. The agent uses your own `gh` login, which can do anything you can. It is not a sandbox.

## What it never does

Reopen alerts, change dependencies, push code, merge PRs, change repository security settings, or write anything public about a code scanning alert.

## Untrusted text

Advisory text is written by advisory authors, and code scanning paths and rules come from your code and its analysis. This is exactly what reaches the model:

| Source | What the model sees | Cap | Why |
|--------|---------------------|-----|-----|
| Dependabot alerts | advisory summary | 200 characters | to explain the alert |
| Dependabot alerts | package name, manifest path, version range, patched version | 214, 300, 100, 64 characters | to group and explain |
| Code scanning alerts | rule ID and rule description | 200 characters each | to group and explain |
| Code scanning alerts | file path and line | 300 characters | to say where to look |
| Bot PR titles and branches | nothing; packaged code matches them to alerts and keeps only the PR number | | to find the fixing PR |

- Advisory descriptions, code scanning messages and help text are dropped by the fetch and never stored or shown.
- None of this text reaches a command line except checked values: alert numbers, a GHSA ID that matches GitHub's format, and a package name and patched version that pass a strict character check (no quotes or spaces). GitHub is read with one fixed command per repository, and every write command is built by the database.
- Text cannot cause a write. Every write is a request you approve in chat for the exact command, and a scheduled run never writes.
- The agent's instructions tell it to treat this text as data and ignore any instructions in it. Sizes are capped when the text is stored.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in, Node 22 or newer, and sqlite3 3.38 or newer.
- Model cost: a run is one agent turn over at most 30 listed alerts. Cost depends on your model.
- GitHub cost: six read calls per repository per run.

## Add it

From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/security-alert-triager
```

Then open the new agent's chat. Setup asks for your repositories, locks its commands behind the approval prompt, creates the database, checks that your login can read the alerts, runs one pass, and helps you turn on the weekday schedule.

## Settings

`settings.md` in the agent's workspace:

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 10 `owner/repo` names |
| `allowed_actions` | `dismiss` | Which writes it may prepare; add `issue` for tracking issues on Dependabot alerts |
| `issue_min_severity` | `high` | With `issue`, the lowest severity a scheduled run prepares an issue request for |
| `max_requests_per_run` | 5 | Issue requests a scheduled run prepares |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs six fixed `gh` reads with no shell: the open Dependabot and Renovate PRs, then open and recently dismissed alerts from each source through `gh api` GET requests. When GitHub refuses an alert read, it records `disabled` or `no_access` from GitHub's own message and goes on; any other error fails the fetch and leaves the previous files in place. A SQL step loads the files into the database.

## Data

- The database at `db_path` (default `~/security-alert-triager.db`) holds alerts, requests and your answers. It is outside the workspace, so deleting and re-adding the agent keeps the history.
- `inbox/` holds the latest reduced reads; `drafts/` holds dismissal comment drafts. Both are in the workspace.

## Remove it

```sh
openclaw agents delete <agent-id>
```

This removes the workspace and the automation. Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3 3.54:
  - every SQL step and every approval check (`tests/`), with made-up names
  - `fetch.mjs` against a stand-in `gh` that records every call
  - `openclaw templates validate`, `build`, and `add --dry-run`
- Where the fixtures come from:
  - The refusal bodies are what GitHub returned to read-only requests in November 2026: Dependabot turned off (403 "Dependabot alerts are disabled for this repository."), code scanning never run (404 "no analysis found"), and no role (403 "You are not authorized to perform this operation." and "You are not authorized to read code scanning alerts."). So is gh's habit of adding an unrelated scope hint on stderr.
  - The code scanning alert shape follows a real alert's keys; the values are made up.
  - The Dependabot alert shape follows GitHub's REST documentation. No repository available for testing had Dependabot alerts turned on, so it has not been checked against a live response.
  - "Advanced Security must be enabled" and 404 "Not Found" are classified from GitHub's documentation, not observed.
  - `gh api -F field=@file` reading a file's contents is from gh's help text; a dismissal with a comment has not been run.
- Not yet: a run with a model, a live read of a repository with Dependabot alerts on, a dismissal or tracking issue approved end to end, the weekday automation over several weeks, and Linux.

## License

MIT. See [LICENSE](LICENSE).
