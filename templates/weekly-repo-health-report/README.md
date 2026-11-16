# Weekly Repo Health Report

An OpenClaw Template for maintainers and team leads. Once a week it reads the repositories you list and sends a short report: PRs and issues opened and closed, how long PRs waited for a first review and to merge, what is open and going stale, and the CI pass rate on the default branch, each with the change since last week. It only reads. It never writes to GitHub.

## What a Monday looks like

```
Repo health, week 2026-W47 (2026-11-09 to 2026-11-16)

example-org/example-repo
- PRs: 4 opened (+1), 3 merged (-2), 2 closed without merging (0)
- Review: first review after 26 h (-4.5), merged after 24 h (medians); 1 merged with no review (+1)
- Slowest merges: #502 264 h, #501 24 h, #503 6 h
- Issues: 2 opened (0), 2 closed (+1)
- Open now: 4 PRs (1 draft, 2 idle 14+ days), 5 issues (2 idle 30+ days)
- CI on the default branch: 75% passing (-5 pts) (6 passed, 2 failed, 1 cancelled or skipped)

Review got faster; merges dropped from 5 to 3.
```

The first week says "no baseline yet" in place of the changes. Trends start with the second weekly snapshot.

## What it reports

| Number | How it is counted |
|--------|-------------------|
| PRs opened, merged, closed without merging | in the 7 days before the run |
| Issues opened, closed | in the same 7 days |
| Time to first review | for PRs merged in the window: opening to the first submitted review by a person other than the author, automated reviewers such as Copilot left out (median hours) |
| Time to merge | for PRs merged in the window: opening to merge (median hours) |
| Merged with no review | merged PRs in the window with no review from anyone but the author |
| Open, draft, stale | open now; stale means no update for `stale_pr_days` or `stale_issue_days` |
| CI pass rate | completed workflow runs on the default branch in the window: success / (success + failure); cancelled and skipped are counted apart |

Bot PRs are left out of every PR number unless you set `exclude_bot_prs: false`.

## Weeks and trends

- Each repository gets one snapshot per ISO week (UTC), from the latest run that week. Running it again in the same week replaces that week's snapshot.
- The change is this week minus the previous ISO week's snapshot. If there is none, the report says "no baseline yet" (first week) or "no snapshot for <week>" (a skipped week), and shows no changes rather than zeros.
- If you changed a setting since last week, the report says the changes are not like for like.

## It never writes to GitHub

There is no GitHub write command anywhere in this Template, and its instructions forbid writing one. It does not comment, label, review, close, merge or rerun anything. The only things it writes are its own SQLite database at `db_path` and one report per week at `reports/<week>.md` in its workspace.

On top of that, setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the fetch and the SQL steps once; anything else would prompt. The agent uses your own `gh` login, which can do anything you can. These are the agent's rules plus OpenClaw's approval prompt, not a sandbox.

## Untrusted text

Anyone who can open an issue or pull request can write text on GitHub. This agent keeps all of it away from the model:

| Source | What the model sees | Why |
|--------|---------------------|-----|
| PR and issue titles, bodies, comments | nothing (never requested from gh) | not needed for counts |
| Review text, names, labels | nothing (dropped by fetch.mjs before it writes) | not needed for counts |
| Logins | nothing (used inside the database only, to tell a review from the author's own and to spot bots) | review times |
| PR numbers, dates, states, CI conclusions | numbers and fixed values | the report |

- fetch.mjs asks gh only for numbers, dates, states and logins, and keeps only the fields the database reads, so no free text written on GitHub lands in the workspace.
- The SQL steps check every value at ingest (integers, ISO times, fixed state lists, a strict login charset) and refuse the whole file on a bad row.
- The report names PRs by number only. Nothing the agent reads can cause a write, because it has no write to make.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in, Node 22 or newer, and sqlite3 3.38 or newer.
- Model cost: a run is one agent turn over a few numbers per repository. Cost depends on your model.
- GitHub cost: six read calls per repository per run.

## Add it

Not published on ClawHub yet. From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/weekly-repo-health-report
```

Then open the new agent's chat. Setup asks for your repositories, locks its commands behind the approval prompt, creates the database, runs one report, and helps you turn on the weekly schedule.

## Settings

`settings.md` in the agent's workspace:

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 10 `owner/repo` names |
| `stale_pr_days` | 14 | An open PR with no update for this many days is stale |
| `stale_issue_days` | 30 | An open issue with no update for this many days is stale |
| `exclude_bot_prs` | `true` | Leave bot PRs out of every PR number |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs six fixed `gh` reads with no shell: the repository (default branch, issues on or off), PRs and issues updated in the last 7 days (300 each), open PRs and issues (500 each), and the newest 200 workflow runs on the default branch. It computes the 7-day window itself, so the command never changes and you can allow it once. A SQL step loads the files and saves the week's snapshot. The report says when a read hit its limit.

## Data

- The database at `db_path` (default `~/weekly-repo-health-report.db`) holds one snapshot row per repository per week: counts, hours, percentages and up to three PR numbers. It is outside the workspace, so deleting and re-adding the agent keeps the history.
- `inbox/` holds the latest trimmed reads; `reports/` holds one report per week. Both are in the workspace.

## Remove it

```sh
openclaw agents delete <agent-id>
```

This removes the workspace and the automation. Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3 3.54:
  - every SQL step, every named refusal, the numbers, ISO weeks at year ends, same-week replacement, deltas and the no-baseline cases (`tests/steps.test.sh`), going through the real fetch.mjs with fixtures in the exact shape of real `gh` output and made-up names
  - `fetch.mjs` against a stand-in `gh` that records every call, including that no title, body or review text reaches the workspace (`tests/fetch.test.mjs`)
  - a live read-only pass on two public repositories: fetch, ingest and the digest, including a repository whose open-issue and run reads hit their limits
  - `openclaw templates validate`, `build`, and `add --dry-run`
- Not yet: a run with a model, the weekly automation over several weeks (trends were tested with stored snapshots), and Linux.

## License

MIT. See [LICENSE](LICENSE).
