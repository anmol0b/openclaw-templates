# Nudge loop

## Commands

Run every command from the workspace root. `<db_path>` is the absolute path from settings.md, with `~` expanded. Write db-input.json with the write tool before each SQL step; it holds the step's input as JSON, with `"step"` set to the step's name. Titles, logins and comment text go only into db-input.json or draft files, never into a command line.

| What | Command |
|------|---------|
| Read one repository | `node references/fetch.mjs <owner/repo>` |
| A SQL step | `sqlite3 -bail -json "<db_path>" ".read references/sql/<step>.sql"` |
| The digest | `sqlite3 -bail "<db_path>" ".read references/sql/digest.sql"` (no `-json`) |

Each command is the same on every run, so the owner can approve each one once with "Always allow here". Never change their spelling, order or spacing. Never allow-always a `gh` write command; the owner OKs each one.

## Steps

| Step | Input | Returns |
|------|-------|---------|
| setup-check | none | sqlite version, schema version, counts |
| add-repo | repo | the repository row |
| run-start | kind (`scheduled` or `manual`), review_days, author_days, conflict_days, nudge_days, skip_bot_prs | run_id and the thresholds |
| ingest | repo, run_id | counts, partial-read flags, PRs now gone |
| stuck-list | run_id, limit (1 to 50) | stuck PRs with category, days waiting and suggested reviewers |
| ask-approval | pr_id, action, reviewer (request-review only) | approval_id and the exact command |
| decide-approval | approval_id, decision, owner_words | the decision |
| use-approval | approval_id, exact_step | used_at, or a refusal |
| approval-outcome | approval_id, outcome, note | the closed request |
| run-end | run_id, note | the ended run |
| digest | run_id | one JSON object |

run-start takes its values from settings.md: `review_wait_days` as review_days, `author_wait_days` as author_days, `conflict_wait_days` as conflict_days, `nudge_window_days` as nudge_days, and `skip_bot_prs` as true or false.

When a step refuses, it prints `CHECK constraint failed: <reason>` and changes nothing. The reason names what is wrong, for example `fetch_again_first`, `pr_changed_since_the_request`, `reviewer_not_a_fetched_candidate`, `reviewer_is_the_author`, `reviewer_already_requested` or `nudged_within_window`. Act on it (fetch again, withdraw and ask again, pick another suggested reviewer, or tell the owner), or fix the input and try once more. If it fails again, stop that PR and name the step and the error line in the list.

## Categories

The database sorts each open PR:

1. `waiting-on-review`: not approved, and no review from a maintainer (OWNER, MEMBER or COLLABORATOR, other than the author) since the latest commit. Days count from the latest commit, or from when it was opened. A review by a bot or an outside account does not count.
2. `merge-conflict`: GitHub reports a conflict. Days count from the PR's last update.
3. `waiting-on-author`: a maintainer requested changes and no commit landed since. Days count from that review.
4. `draft` and `ok` (approved, or reviewed since the latest commit) are never listed.

A PR is stuck when it has waited at least the run's days for its category. Bot PRs are left out when skip_bot_prs is true.

## Scheduled run

1. Read settings.md. If `paused: true`, end the run with one line saying so.
2. `run-start` with kind `scheduled` and the values from settings.md. Keep the run_id.
3. For each repository in `repos`, in order: `node references/fetch.mjs <owner/repo>`, then `ingest` with repo and run_id. If a fetch fails, keep the error line for the run-end note and go on.
4. `stuck-list` with run_id and `limit` 30.
5. Requests, at most `max_requests_per_run`, in list order, only for actions in `allowed_actions`:
   1. Fetch and ingest each repository that has one again, because ask-approval needs a fetch from the last 15 minutes.
   2. `waiting-on-review` with no one requested (`requested_users` empty and `requested_teams` 0): `ask-approval` with `request-review` and the first login in `suggested_reviewers`. If `suggested_reviewers` is empty, no request; say in the list that the repository has no candidate.
   3. `waiting-on-review` with a request already out, and no nudge within the window (`last_nudge_at`): write a short note to the draft path (see "Comments"), then `ask-approval` with `comment`.
   4. `merge-conflict` and `waiting-on-author`: a short note to the draft path, then `ask-approval` with `comment`.
   5. If ask-approval refuses with `UNIQUE constraint failed: approvals.pr_id, approvals.action`, a request is already open: leave it. If it refuses with `nudged_within_window`, leave the PR for this run.
6. `run-end` with run_id. Put every fetch error line, and any step you stopped on, in `note`.
7. `digest` with run_id. Write the list from its output and templates/digest.md. Never add a PR, number or count that is not in the output.

A scheduled run ends here. It never runs decide-approval, use-approval or a `gh` write command.

## Answering requests (in chat, with the owner)

1. A grant must name the request (its approval_id, or a clear group from the latest list such as "send all the conflict nudges"). If it is unclear, ask once.
2. If the owner wants another reviewer, withdraw the request (`decide-approval` with `withdrawn`) and `ask-approval` again with the login they named. ask-approval accepts it only if it is a fetched candidate; if it refuses, tell the owner why.
3. If the owner changed a draft, the old request no longer matches: withdraw it, then `ask-approval` again and show the new command.
4. For each granted request, in order:
   1. `node references/fetch.mjs <owner/repo>`, then `ingest` (run_id null).
   2. `decide-approval` with `granted` and owner_words quoting the owner. If it refuses with `pr_changed_since_the_request`, withdraw the request, tell the owner what changed (for example a new commit or a review), and ask again only if the PR is still stuck.
   3. `use-approval` with the exact_step, character for character.
   4. Run exact_step with exec. OpenClaw asks the owner in its approval prompt as well.
   5. `node references/fetch.mjs <owner/repo>`, then `ingest`, then `approval-outcome` with `done`, or `failed` and the exact error line. If `done` is refused with `reviewer_not_requested_on_github` or `comment_not_on_github`, the write did not show up: record `failed` with the command's output line.
5. For each refused request: `decide-approval` with `refused` and the owner's words.
6. Report each result in one line.

A request older than 7 days, or whose PR changed (`pr_changed` in the digest), is withdrawn at the next chat with the owner.

## Comments

- One to three short sentences in the owner's voice saying what is needed next: "This has a conflict with main now; could you rebase when you get a chance?" or "Friendly check-in on the requested changes. Still planning to pick this up?"
- Mention only the PR author or reviewers already requested on that PR. No promises about dates, no blame, no apologies on behalf of the project.

## Accepted edge cases

- Only the 30 most recently opened PRs are read (gh's default order; a larger page hits GitHub's 500,000-node query limit with commits and comments). In a repository with more open PRs, older ones are left out; that is deliberate, since long-abandoned PRs are cleanup work rather than review nudges. Only the first 100 collaborators are read. The list says when either read was cut.
- `waiting-on-author` uses commit times. A rebase that keeps old commit dates may look like no push; the PR then shows as waiting on its author until the next review.
- Team owners in CODEOWNERS and team review requests are not suggested; a PR with only a team request counts as requested.
- A nudge is confirmed by the owner's comment count on the PR. A PR with more than 100 comments may hit gh's own comment limit, so the count may not move; the outcome then needs the comment time, or is recorded as failed for the owner to check.
