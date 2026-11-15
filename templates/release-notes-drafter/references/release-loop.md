# Release loop

## Commands

Run every command from the workspace root. `<db_path>` is the absolute path from settings.md, with `~` expanded. Write db-input.json with the write tool before each SQL step; it holds the step's input as JSON, with `"step"` set to the step's name. Pull request text goes only into db-input.json or the draft files, never into a command line.

| What | Command |
|------|---------|
| Read one repository | `node references/fetch.mjs <owner/repo>` |
| A SQL step | `sqlite3 -bail -json "<db_path>" ".read references/sql/<step>.sql"` |
| render-draft and digest | `sqlite3 -bail "<db_path>" ".read references/sql/<step>.sql"` (no `-json`) |

Each command is the same on every run, so the owner can approve each one once with "Always allow here". fetch.mjs computes the search date itself, so the command does not change when a new release appears. Never change the commands' spelling. Never allow-always `gh release create`; the owner OKs each one.

## Steps

| Step | Input | Returns |
|------|-------|---------|
| setup-check | none | sqlite version, schema version, counts |
| add-repo | repo | the repository row |
| run-start | kind (`scheduled` or `manual`) | run_id |
| ingest | repo, run_id | base_tag, since, pr_count, newest_merged_at, limit_reached, draft_releases |
| pending-prs | repo, include_bots, include_bodies | the window, oldest merge first, with suggested_section, base_tag, newest_merged_at |
| save-draft | run_id, repo, base_tag, newest_merged_at, include_bots, zero_major_breaking_is_minor, entries, (next_tag and owner_words only when the owner chose the version) | draft_id, next_tag, bump, notes_file, changelog_file |
| render-draft | draft_id | one JSON object: sections in order, contributors, compare_url, file paths |
| ask-approval | draft_id, title | approval_id and the exact command |
| decide-approval | approval_id, decision, owner_words | the decision |
| use-approval | approval_id, exact_step | used_at, or a refusal |
| approval-outcome | approval_id, outcome, note | the closed request |
| run-end | run_id, note | the ended run |
| digest | run_id | one JSON object |

When a step refuses, it prints `constraint failed: <reason>` and changes nothing. The reason names what is wrong, for example `fetch_again_first`, `repo_changed_since_the_draft`, `entries_do_not_match_the_window`, `tag_already_exists` or `notes_changed_since_the_request`. Act on it, or fix the input and try once more. If it fails again, stop that repository and name the step and the error line in the run-end note.

## Drafting run

1. Read settings.md. If `paused: true`, end with one line saying so.
2. `run-start`. Keep the run_id.
3. For each repository in `repos`:
   1. `node references/fetch.mjs <owner/repo>`. If it fails, keep the error line for the run-end note and go on.
   2. `ingest` with repo and run_id. If `pr_count` is 0, there is nothing to release: note it and go on. If `draft_releases` already lists a tag, mention it in the digest; the owner may already be working on that release.
   3. `pending-prs` with repo, `include_bots` (true when settings.md has `list_bot_prs: true`) and `include_bodies` (true only when settings.md has `include_pr_bodies: true`).
   4. For each pull request, keep `suggested_section` unless the title (or the body excerpt, when bodies are on) clearly says otherwise. Decide every `other` yourself; `other` is fine when nothing fits.
   5. `save-draft` with base_tag and newest_merged_at exactly as pending-prs showed them, every pull request once, and `zero_major_breaking_is_minor` from settings.md. If it refuses with `repo_changed_since_pending_prs`, fetch, ingest and start this repository again.
   6. `render-draft` with draft_id. Write `notes_file` (the GitHub release body) and `changelog_file` (the changelog section) from its output and templates/release-notes.md.
   7. `ask-approval` with draft_id and a title from `title_format` in settings.md (letters, digits, spaces and `. _ : + ( ) -` only).
4. `run-end` with run_id and every fetch error or stopped step in `note`.
5. `digest` with run_id. Show, per repository: the base tag, the proposed tag and why (the bump), the counts per section, the request with its exact command, and the two file paths. Never add anything that is not in the output.

A scheduled run ends here. It never runs decide-approval, use-approval or a `gh` write command.

## Answering requests (in chat, with the owner)

1. Read the owner's words. A grant names the request (approval_id or the repository and tag). If unclear, ask once.
2. If the owner wants changes (another section for a pull request, a different version, other wording), the request no longer matches: `decide-approval` with `withdrawn`, then:
   - a section or version change: fetch, ingest, pending-prs, save-draft again (next_tag with owner_words for a version), render-draft, write the files, ask-approval;
   - wording only: edit notes_file, then ask-approval again for the same draft.
3. For a granted request:
   1. `node references/fetch.mjs <owner/repo>`, then `ingest` (run_id null).
   2. `decide-approval` with `granted` and owner_words quoting the owner. If it refuses with `repo_changed_since_the_request` (a new merge or release), withdraw, tell the owner what changed, and draft again.
   3. `use-approval` with the exact_step, character for character.
   4. Run exact_step with exec. OpenClaw asks the owner in its approval prompt as well.
   5. `node references/fetch.mjs <owner/repo>`, then `ingest`, then `approval-outcome` with `done` (it checks GitHub lists the draft release), or with `failed` and the exact error line.
4. For a refused request: `decide-approval` with `refused` and the owner's words.
5. Report in one line: the command, done or failed, and the release page (`https://github.com/<owner/repo>/releases`). Remind the owner that the release is a draft until they publish it on GitHub.

## Accepted edge cases

- The window is every pull request merged into the default branch after the base release's tagged commit (GitHub search, `merged:>`). A pull request merged in the same second as that commit is left out; one merged to another branch and released from it is not listed.
- A repository with more than 300 merges since its last release is read only in part. ingest flags it (`limit_reached`), and the digest says so.
- With several release lines (for example backports to an older major), the base is the release GitHub marks as latest. Backport releases are not drafted.
- Direct pushes without a pull request are not listed. The compare link in the notes shows every commit.
