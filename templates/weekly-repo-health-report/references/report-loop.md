# Report loop

## Commands

Run every command from the workspace root. `<db_path>` is the absolute path from settings.md, with `~` expanded. Write db-input.json with the write tool before each SQL step; it holds the step's input as JSON, with `"step"` set to the step's name.

| What | Command |
|------|---------|
| Read one repository | `node references/fetch.mjs <owner/repo>` |
| A SQL step | `sqlite3 -bail -json "<db_path>" ".read references/sql/<step>.sql"` |
| The digest | `sqlite3 -bail "<db_path>" ".read references/sql/digest.sql"` (no `-json`) |

These are the only commands this agent runs after setup. Each one is the same on every run, so the owner can approve each one once with "Always allow here". Never change their spelling, order or spacing. There is no GitHub write command in this Template, and you never write one.

## Steps

| Step | Input | Returns |
|------|-------|---------|
| setup-check | none | sqlite version, schema version, counts |
| add-repo | repo | the repository row |
| run-start | kind (`scheduled` or `manual`) | run_id |
| ingest | repo, run_id, stale_pr_days, stale_issue_days, exclude_bot_prs | this week's snapshot for the repository |
| run-end | run_id, note | the ended run |
| digest | run_id | one JSON object |

When a step refuses, it prints `CHECK constraint failed: <reason>` and saves nothing. The reason names what is wrong, for example `fetch_again_first`, `repo_not_registered`, `stale_days_not_1_to_365` or `time_not_iso_utc`. Act on it (fetch again, fix the input) and try once more. If it fails again, skip that repository and name the step and the error line in the run-end note.

## What the numbers mean

- **Window:** the 7 days before the fetch. fetch.mjs computes it; it is not a setting.
- **PRs opened, merged, closed unmerged; issues opened, closed:** in the window.
- **Hours to first review:** for PRs merged in the window, from opening to the first submitted review by a person other than the author. Automated reviewers (logins ending in `[bot]` or `-bot`, `app/...`, and Copilot's reviewer) are left out. `merged_without_review` counts merged PRs with none.
- **Hours to merge:** for PRs merged in the window, from opening to merge. Both are medians.
- **Open, draft, stale:** open now. Stale means no update for `stale_pr_days` or `stale_issue_days`.
- **CI pass rate:** completed workflow runs on the default branch created in the window: success divided by success plus failure (including timed out). Cancelled and skipped runs are counted as `ci_other` and left out of the rate.
- **Bots:** with `exclude_bot_prs: true`, PRs opened by bots are left out of every PR number.
- **Week:** the ISO week (UTC) of the fetch. Each repository has one snapshot per week. A second run in the same week replaces that week's snapshot.
- **Deltas:** this week minus the previous ISO week. With no previous snapshot, `deltas` is null and `baseline_note` says why: `no baseline yet` (the first snapshot) or `no snapshot for <week>` (a skipped week). Never write a trend, an up or down arrow, or a zero change when `deltas` is null.
- **Partial reads:** a `*_cut` flag of 1 means a read hit its limit, so that number may be low. Say so next to the number.

## Scheduled run

1. Read settings.md. If `paused: true`, end the run with one line saying so.
2. `run-start` with kind `scheduled`. Keep the run_id.
3. For each repository in `repos`, in order: `node references/fetch.mjs <owner/repo>`, then `ingest` with repo, run_id, and `stale_pr_days`, `stale_issue_days` and `exclude_bot_prs` from settings.md. If a fetch fails, keep its error line for the run-end note and go on.
4. `run-end` with run_id. Put every fetch error line, and any step you stopped on, in `note`.
5. `digest` with run_id. Write the report from its output and templates/report.md to `reports/<week>.md` (one file per week, replaced on a second run that week), and end the run with the same text. Never add a number, trend or claim that is not in the output.

A manual run ("report now", "how did last week go?") is the same with run-start kind `manual`.

## Answering questions

- Answer from the latest digest, or run the digest again for an earlier run_id. For an older week, read `reports/<week>.md`.
- If the owner asks for a number this Template does not compute (for example per-author counts), say so plainly. Do not read GitHub another way to get it.
- If the owner asks you to act on GitHub (comment, close, label, rerun), say this agent only reads and reports.

## Accepted edge cases

- A PR or issue is in the window only if GitHub's search finds it updated in the window. That is true of anything opened, merged or closed in it.
- Review time counts the first submitted review only, from the reviews gh returns per PR. Review requests and plain comments are not reviews. gh does not mark review authors as bots, so a review bot with an ordinary login counts as a reviewer.
- CI counts the newest 200 runs on the default branch. On a very busy branch the oldest runs in the window may be missed; `runs_cut` says so.
- The week is the UTC ISO week of the fetch. A Monday 00:30 run in a UTC+2 time zone counts as the previous week's Sunday.
- Changing `stale_*_days` or `exclude_bot_prs` changes the numbers; `settings_changed` in the digest says when this week used different settings from last week.
