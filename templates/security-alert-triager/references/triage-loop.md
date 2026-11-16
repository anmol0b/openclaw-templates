# Triage loop

## Commands

Run every command from the workspace root. `<db_path>` is the absolute path from settings.md, with `~` expanded. Write db-input.json with the write tool before each SQL step; it holds the step's input as JSON, with `"step"` set to the step's name. Package names, rules, summaries and comment text go only into db-input.json or draft files, never into a command line.

| What | Command |
|------|---------|
| Read one repository | `node references/fetch.mjs <owner/repo>` |
| A SQL step | `sqlite3 -bail -json "<db_path>" ".read references/sql/<step>.sql"` |
| The digest | `sqlite3 -bail "<db_path>" ".read references/sql/digest.sql"` (no `-json`) |

Each command is the same on every run, so the owner can approve each one once with "Always allow here". Never change their spelling, order or spacing. Never allow-always a `gh` write command; the owner OKs each one.

## Steps

| Step | Input | Returns |
|------|-------|---------|
| setup-check | none | sqlite version, schema version, which sources each repository can read |
| add-repo | repo | the repository row |
| run-start | kind (`scheduled` or `manual`) | run_id |
| ingest | repo, run_id | each source's status and counts, alerts closed now |
| alert-list | run_id, limit (1 to 50) | open alerts, most severe first |
| ask-approval | alert_id, action, reason, with_comment | approval_id and the exact command |
| decide-approval | approval_id, decision, owner_words | the decision |
| use-approval | approval_id, exact_step | used_at, or a refusal |
| approval-outcome | approval_id, outcome, note, issue_url | the closed request |
| run-end | run_id, note | the ended run |
| digest | run_id | one JSON object |

When a step refuses, it prints `CHECK constraint failed: <reason>` and changes nothing. The reason names what is wrong, for example `fetch_again_first`, `alert_changed_since_the_request`, `dismiss_reason_not_in_githubs_list`, `no_issues_for_code_scanning_alerts` or `token_lacks_alert_access`. Act on it (fetch again, withdraw and ask again, or tell the owner), or fix the input and try once more. If it fails again, stop that alert and name the step and the error line in the digest.

## What each source can say

fetch.mjs reads each source and records one of:

- `ok`: read. Zero open alerts means none are open (`no_alerts` in the digest).
- `disabled`: GitHub said the feature is off (Dependabot alerts turned off) or never ran (code scanning has no analysis).
- `no_access`: GitHub said this login is not allowed to read them. The owner needs a role that sees security alerts on that repository, and `gh` needs the `repo` scope (or `security_events`).

Name every `disabled` and `no_access` source in the digest. Never describe a repository as having no alerts unless its source says `ok` with zero open.

## Scheduled run

1. Read settings.md. If `paused: true`, end the run with one line saying so.
2. `run-start` with kind `scheduled`. Keep the run_id.
3. For each repository in `repos`, in order: `node references/fetch.mjs <owner/repo>`, then `ingest` with repo and run_id. If a fetch fails, keep the error line for the run-end note and go on.
4. `alert-list` with run_id and `limit` 30.
5. Requests, only if `issue` is in `allowed_actions`, at most `max_requests_per_run`, in list order:
   1. Fetch and ingest the repository again, because ask-approval needs a fetch from the last 15 minutes.
   2. `ask-approval` with `issue` for each open Dependabot alert at `issue_min_severity` or higher whose `covering_fixes` is not `yes` and that has no open request.
   3. If ask-approval refuses with `tracking_issue_already_opened`, `alert_fields_unsafe_for_a_command`, or `UNIQUE constraint failed`, leave that alert.
   A scheduled run never prepares a dismissal.
6. `run-end` with run_id. Put every fetch error line, and any step you stopped on, in `note`.
7. `digest` with run_id. Write it from its output and templates/digest.md. Never add an alert, number or count that is not in the output.

A scheduled run ends here. It never runs decide-approval, use-approval or a `gh` write command.

## Dismissing (in chat, with the owner)

Only when the owner asks to dismiss specific alerts. The owner chooses the reason; you may explain the options.

- Dependabot reasons: `fix_started`, `inaccurate`, `no_bandwidth`, `not_used`, `tolerable_risk`.
- Code scanning reasons: `false positive`, `won't fix`, `used in tests`.

1. Fetch and ingest the repository, then `ask-approval` with `dismiss` and the reason. If the owner wants a comment, write it first to the draft path (`drafts/<owner>__<repo>-<source>-<number>.md`, at most 280 bytes, the owner's words) and pass `with_comment: true`.
2. Show the exact command and wait for the owner's answer. Then follow "Answering requests".

Never suggest dismissing a critical or high alert as `tolerable_risk` or `no_bandwidth` on your own; if the owner asks for it, say once what the alert is, then do what they decide.

## Answering requests (in chat, with the owner)

1. A grant must name the request (its approval_id, or a clear group from the latest digest). If it is unclear, ask once.
2. If the owner changed a draft, the old request no longer matches: `decide-approval` with `withdrawn`, then `ask-approval` again and show the new command.
3. For each granted request, in order:
   1. `node references/fetch.mjs <owner/repo>`, then `ingest` (run_id null).
   2. `decide-approval` with `granted` and owner_words quoting the owner. If it refuses with `alert_changed_since_the_request`, withdraw the request, tell the owner what changed, and ask again only if the request still makes sense.
   3. `use-approval` with the exact_step, character for character.
   4. Run exact_step with exec. OpenClaw asks the owner in its approval prompt as well.
   5. `node references/fetch.mjs <owner/repo>`, then `ingest`, then `approval-outcome`:
      - dismiss: `done` only when it is accepted; if it refuses with `alert_not_dismissed_after_the_write`, record `failed` with what GitHub said (an organization can require a second person to approve dismissals).
      - issue: `done` with `issue_url`, the URL `gh issue create` printed.
      - Any error: `failed` and the exact error line.
4. For each refused request: `decide-approval` with `refused` and the owner's words.
5. Report each result in one line.

A request older than 14 days, or whose alert changed (`alert_changed` in the digest), is withdrawn at the next chat with the owner.

## Accepted edge cases

- Each source reads the 100 most recently updated open alerts. A repository with more is marked cut and nothing is marked closed for it.
- Dismissed alerts are read from the 30 most recently updated. An alert dismissed long ago that reappears in neither read is shown as closed.
- A bot PR is matched to an alert by package name in its title or branch. Grouped Dependabot PRs ("Bump the npm group with 3 updates") name no package and are only matched by branch, so a fix inside a group can be missed.
- A tracking issue is not read back. Its URL is checked to be an issue in the same repository, and one done issue per alert is allowed.
