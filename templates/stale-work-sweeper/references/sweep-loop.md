# Sweep loop

## Commands

Run every command from the workspace root. `<db_path>` is the absolute path from settings.md, with `~` expanded. Write db-input.json with the write tool before each SQL step; it holds the step's input as JSON, with `"step"` set to the step's name. Branch names, titles and comment text go only into db-input.json or draft files, never into a command line.

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
| run-start | kind (`scheduled` or `manual`), stale_days | run_id and the stale cutoff |
| ingest | repo, run_id | counts, partial-read flags, items now gone |
| stale-list | run_id, limit (1 to 50) | the owner's stale items, safest first |
| ask-approval | item_id, action, close_reason | approval_id and the exact command |
| decide-approval | approval_id, decision, owner_words | the decision |
| use-approval | approval_id, exact_step | used_at, or a refusal |
| approval-outcome | approval_id, outcome, note | the closed request |
| run-end | run_id, note | the ended run |
| digest | run_id | one JSON object |

When a step refuses, it prints `CHECK constraint failed: <reason>` and changes nothing. The reason names what is wrong, for example `fetch_again_first`, `item_changed_since_the_request`, `branch_not_merged_or_has_open_pr`, `branch_name_unsafe` or `not_the_owners_item`. Act on it (fetch again, withdraw and ask again, or tell the owner), or fix the input and try once more. If it fails again, stop that item and name the step and the error line in the list.

## Categories

stale-list and digest give each item a category, in this order:

1. `merged-branch`: every commit is in the default branch, or a merged PR had this exact head (squash and rebase merges). No open PR, not protected, not the default branch. Safe to delete.
2. `idle-pr`: an open PR the owner opened. Shows draft, CI (`failing`, `pending`, `passing`, `none`) and `mergeable` (`CONFLICTING` means it needs a rebase).
3. `idle-issue`: an open issue assigned to the owner.
4. `unmerged-branch`: commits that are not in the default branch. Never suggested for deletion; list it for the owner to look at.

A branch with an open PR is left to that PR and not listed.

## Scheduled run

1. Read settings.md. If `paused: true`, end the run with one line saying so.
2. `run-start` with kind `scheduled` and `stale_days` from settings.md. Keep the run_id.
3. For each repository in `repos`, in order: `node references/fetch.mjs <owner/repo>`, then `ingest` with repo and run_id. If a fetch fails, keep the error line for the run-end note and go on.
4. `stale-list` with run_id and `limit` 30.
5. Requests, at most `max_requests_per_run`, in list order, only for actions in `allowed_actions`:
   1. Fetch and ingest each repository that has one again, because ask-approval needs a fetch from the last 15 minutes.
   2. `merged-branch`: `ask-approval` with `delete-branch`.
   3. `idle-pr` with no activity for twice `stale_days`: if `comment` is allowed, write a short note to the draft path (see "Comments"), then `ask-approval` with `comment`; if `close` is allowed, `ask-approval` with `close`. A PR with passing CI and no conflict gets a comment only; suggest closing only for drafts or failing PRs.
   4. `idle-issue`: if `unassign` is allowed, `ask-approval` with `unassign`. A scheduled run never suggests closing an issue; the owner can ask for that in chat.
   5. `unmerged-branch`: no request.
   6. If ask-approval refuses with `UNIQUE constraint failed: approvals.item_id, approvals.action`, a request is already open: leave it.
6. `run-end` with run_id. Put every fetch error line, and any step you stopped on, in `note`.
7. `digest` with run_id. Write the list from its output and templates/digest.md. Never add an item, number or count that is not in the output.

A scheduled run ends here. It never runs decide-approval, use-approval or a `gh` write command.

## Answering requests (in chat, with the owner)

1. A grant must name the request (its approval_id, or a clear group from the latest list such as "delete all the merged branches"). If it is unclear, ask once.
2. If the owner changed a draft, the old request no longer matches: `decide-approval` with `withdrawn`, then `ask-approval` again and show the new command.
3. For each granted request, in order:
   1. `node references/fetch.mjs <owner/repo>`, then `ingest` (run_id null).
   2. `decide-approval` with `granted` and owner_words quoting the owner. If it refuses with `item_changed_since_the_request`, withdraw the request, tell the owner what changed (for example a new commit on the branch), and ask again only if the suggestion still holds.
   3. `use-approval` with the exact_step, character for character.
   4. Run exact_step with exec. OpenClaw asks the owner in its approval prompt as well.
   5. `node references/fetch.mjs <owner/repo>`, then `ingest`, then `approval-outcome` with `done`, or `failed` and the exact error line.
4. For each refused request: `decide-approval` with `refused` and the owner's words.
5. Report each result in one line. For a deleted branch, include the restore command from approval-outcome: `git push <remote> <sha>:refs/heads/<branch>`.

A request older than 14 days, or whose item changed (`item_changed` in the digest), is withdrawn at the next chat with the owner.

## Comments

- One to three short sentences in the owner's voice: what happens to this work now ("Parking this; the fix moved to #123." or "I'm not working on this anymore, unassigning so someone else can pick it up.").
- No @-mentions, no promises about dates, no apologies on behalf of the project.

## Accepted edge cases

- A branch is the owner's when its last commit is theirs. A branch someone else pushed to last is not listed, and an old branch the owner created whose last commit is someone else's is missed.
- Only the newest 100 branches per repository are read. Older ones are left out, and the list says so (`branches_cut`).
- The owner's PRs are found in the repositories listed. A PR the owner opened from a fork to another repository appears only when that other repository is listed too.
- A merged PR is matched by its exact head SHA. A branch that got new commits after its PR merged is unmerged.
