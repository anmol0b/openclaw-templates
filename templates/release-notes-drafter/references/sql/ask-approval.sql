-- Ask the owner to create one draft release on GitHub. Input: draft_id, title (letters, digits, spaces and . _ : + ( ) - only, up to 100).
-- This step builds the exact command. Never write a gh write command yourself: show the owner the exact_step it returns, word for word.
-- Write the release body to the draft's notes_file first. The text never goes on a command line.
-- Refuses unless the repository was fetched in the last 15 minutes and has not changed since the draft
-- (same base release, same newest merge), and the tag does not exist yet.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/ask-approval.sql"
-- Input: write db-input.json with the write tool first, with "step": "ask-approval".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'ask-approval'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE d AS
SELECT d.*, r.default_branch, r.base_tag AS now_base, r.newest_merged_at AS now_newest, r.pr_count AS now_count, r.fetched_at
FROM drafts AS d JOIN repos AS r ON r.repo = d.repo
WHERE d.id = (SELECT json_extract(j, '$.draft_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT unknown_draft CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 FROM temp.d;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g2 SELECT fetched_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes') FROM temp.d;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT repo_changed_since_the_draft CHECK (ok = 1));
INSERT INTO temp.g3 SELECT now_base = base_tag AND now_newest = newest_merged_at AND now_count = window_count FROM temp.d;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT tag_already_exists CHECK (ok = 1));
INSERT INTO temp.g4 SELECT NOT EXISTS (SELECT 1 FROM releases AS x, temp.d AS d WHERE x.repo = d.repo AND x.tag = d.next_tag);
CREATE TEMP TABLE t (title TEXT NOT NULL CONSTRAINT title_unsafe CHECK (
  length(trim(title)) BETWEEN 1 AND 100 AND title NOT GLOB '*[^A-Za-z0-9 ._:+()-]*'
));
INSERT INTO temp.t SELECT coalesce(json_extract(j, '$.title'), '') FROM temp.input;
-- The notes file exists and holds 1 to 125000 bytes of text (GitHub's release body limit).
CREATE TEMP TABLE body (b BLOB);
INSERT INTO temp.body SELECT readfile(notes_file) FROM temp.d;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT notes_missing_empty_or_too_long CHECK (ok = 1));
INSERT INTO temp.g5 SELECT coalesce((SELECT length(b) BETWEEN 1 AND 125000 AND length(trim(CAST(b AS TEXT))) > 0 FROM temp.body), 0);
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT default_branch_unknown CHECK (ok = 1));
INSERT INTO temp.g6 SELECT default_branch <> '' FROM temp.d;

INSERT INTO approvals (draft_id, action, title, notes_file, notes_sha3, exact_step, seen_base_tag, seen_newest_merged_at, seen_pr_count, asked_at)
SELECT d.id, 'create-draft-release', t.title, d.notes_file, (SELECT hex(sha3(b, 256)) FROM temp.body),
       'gh release create ' || d.next_tag || ' --repo ' || d.repo || ' --draft --target ' || d.default_branch ||
       ' --title ''' || t.title || ''' --notes-file ' || d.notes_file,
       d.now_base, d.now_newest, d.now_count, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.d AS d, temp.t AS t
RETURNING id AS approval_id, action, exact_step, notes_file;
