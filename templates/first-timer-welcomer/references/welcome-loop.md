# Welcome loop

## Commands

Run every command from the workspace root. `<db_path>` is the absolute path from settings.md, with `~` expanded. Write db-input.json with the write tool before each SQL step; it holds the step's input as JSON, with `"step"` set to the step's name. Titles, logins, label names and welcome text go only into db-input.json or draft files, never into a command line.

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
| add-repo | repo, allowed_labels | the repository row |
| run-start | kind (`scheduled` or `manual`), recent_days | run_id and the cutoff |
| ingest | repo, run_id | counts, partial-read flags, items now gone |
| newcomers | run_id, limit (1 to 50) | recent PRs and issues by newcomers, waiting ones first |
| label-candidates | limit (1 to 50) | issues that could take a newcomer label |
| ask-approval | item_id, action (`welcome` or `add-label`), label | approval_id and the exact command |
| decide-approval | approval_id, decision, owner_words | the decision |
| use-approval | approval_id, exact_step | used_at, or a refusal |
| approval-outcome | approval_id, outcome, note | the closed request |
| run-end | run_id, note | the ended run |
| digest | run_id | one JSON object |

When a step refuses, it prints `CHECK constraint failed: <reason>` and changes nothing. The reason names what is wrong, for example `fetch_again_first`, `item_changed_since_the_request`, `already_welcomed_in_this_repo`, `author_not_a_newcomer`, `label_not_allowed` or `label_not_in_repo`. Act on it (fetch again, withdraw and ask again, or tell the owner), or fix the input and try once more. If it fails again, stop that item and name the step and the error line in the list.

## Who counts

- **Newcomer:** the PR or issue author is a person (not a bot), not the owner, and GitHub marks them `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER` or `NONE` for this repository.
- **Waiting:** a newcomer item this agent has not welcomed the person for in this repository, and the owner has not commented on.
- **Label candidate:** an open issue with no assignee, no open PR that would close it, a description of at least 80 characters, and none of the repository's allowed labels yet.

## Scheduled run

1. Read settings.md. If `paused: true`, end the run with one line saying so.
2. `run-start` with kind `scheduled` and `recent_days` from settings.md. Keep the run_id.
3. For each repository in `repos`, in order: `node references/fetch.mjs <owner/repo>`, then `ingest` with repo and run_id. If a fetch fails, keep the error line for the run-end note and go on.
4. `newcomers` with run_id and `limit` 30. `label-candidates` with `limit` 20.
5. Requests, at most `max_requests_per_run` in total:
   1. Fetch and ingest each repository that has one again if more than 10 minutes passed, because ask-approval needs a fetch from the last 15 minutes.
   2. For each waiting newcomer, oldest first, if `welcome` is in `allowed_actions`: write a welcome to `drafts/<owner>__<repo>-<number>.md` (see "Welcomes"), then `ask-approval` with `welcome`. One request per person: when a person has several waiting items, welcome them on the oldest.
   3. If `add-label` is in `allowed_actions`: for at most `max_label_suggestions` candidates whose title reads as small and self-contained, `ask-approval` with `add-label` and the first label from `allowed_labels` that fits. Skip any you are unsure of.
   4. If ask-approval refuses with `UNIQUE constraint failed: approvals.item_id, approvals.action` or `welcome_already_requested_for_this_person`, a request is already open: leave it.
6. `run-end` with run_id. Put every fetch error line, and any step you stopped on, in `note`.
7. `digest` with run_id. Write the list from its output and templates/digest.md. Never add an item, number or count that is not in the output.

A scheduled run ends here. It never runs decide-approval, use-approval or a `gh` write command.

## Answering requests (in chat, with the owner)

1. A grant must name the request (its approval_id, or a clear group from the latest list such as "send all the welcomes"). If it is unclear, ask once.
2. If the owner changes a draft, the old request no longer matches: `decide-approval` with `withdrawn`, then `ask-approval` again and show the new command and text.
3. For each granted request, in order:
   1. `node references/fetch.mjs <owner/repo>`, then `ingest` (run_id null).
   2. `decide-approval` with `granted` and owner_words quoting the owner. If it refuses with `item_changed_since_the_request`, withdraw the request, tell the owner what changed, and ask again only if the suggestion still holds (for example, not when someone else already replied).
   3. `use-approval` with the exact_step, character for character.
   4. Run exact_step with exec. OpenClaw asks the owner in its approval prompt as well.
   5. `node references/fetch.mjs <owner/repo>`, then `ingest`, then `approval-outcome` with `done`, or `failed` and the exact error line. If `done` is refused with `welcome_not_seen_after_the_write` or `label_not_on_the_issue_after_the_write`, fetch once more a minute later and try again; if it is still refused, record `failed` with that reason and tell the owner to check the item.
4. For each refused request: `decide-approval` with `refused` and the owner's words.
5. Report each result in one line with the item's URL.

A request older than 14 days, or whose item changed (`item_changed` in the digest), is withdrawn at the next chat with the owner.

## Welcomes

- One to three short sentences in the owner's voice: thank the person by their login, say what happens next ("I'll take a look this week" only if the owner said so in settings.md `welcome_note`; otherwise "a maintainer will take a look"), and add the `welcome_note` from settings.md when it is set (for example a link to the contributing guide).
- For a draft PR, say there is no rush. For an issue, thank them for the report.
- No other @-mentions, no promises about dates, merges or reviews, no emoji unless settings.md asks for them.

## Accepted edge cases

- `NONE` also marks people who opened issues before but never contributed code. On a busy repository the waiting list includes them; the once-per-person rule and `recent_days` keep it bounded.
- Only the newest 50 open PRs and 100 open issues by last update are read. An older item that nobody touched is not listed, and the list says the read was partial.
- A label must exist in the repository under exactly the name in settings.md. Only the first 100 labels by name are read, so on a repository with more, an allowed label late in the alphabet is refused with `label_not_in_repo`.
- The owner's comments are found among the last 30 comments on an item. On a longer thread an older comment by the owner is missed, and the item may show as waiting.
- A person welcomed before this agent was added is not known to it. If the owner says someone was already welcomed, refuse that request.
