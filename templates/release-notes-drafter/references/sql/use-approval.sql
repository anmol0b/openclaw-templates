-- Run right before the write. Input: approval_id, exact_step (the command you are about to run, character for character).
-- Fails unless the approval is granted and unused, the command is the one the owner approved, the repository was fetched
-- again in the last 10 minutes and has no new release or merge since the request, the tag still does not exist, and the
-- notes file has the exact bytes the owner approved. Marks the approval used.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/use-approval.sql"
-- Input: write db-input.json with the write tool first, with "step": "use-approval".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'use-approval'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE a AS
SELECT a.*, d.repo, d.next_tag, r.base_tag AS now_base, r.newest_merged_at AS now_newest, r.pr_count AS now_count, r.fetched_at
FROM approvals AS a JOIN drafts AS d ON d.id = a.draft_id JOIN repos AS r ON r.repo = d.repo
WHERE a.id = (SELECT json_extract(j, '$.approval_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT approval_not_granted_or_already_used CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(decision = 'granted' AND used_at IS NULL) FROM temp.a;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT not_the_approved_command CHECK (ok = 1));
INSERT INTO temp.g2 SELECT a.exact_step = coalesce(json_extract(i.j, '$.exact_step'), '') FROM temp.a AS a, temp.input AS i;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g3 SELECT fetched_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes') FROM temp.a;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT repo_changed_since_the_request CHECK (ok = 1));
INSERT INTO temp.g4 SELECT now_base = seen_base_tag AND now_newest = seen_newest_merged_at AND now_count = seen_pr_count FROM temp.a;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT tag_already_exists CHECK (ok = 1));
INSERT INTO temp.g5 SELECT NOT EXISTS (SELECT 1 FROM releases AS x, temp.a AS a WHERE x.repo = a.repo AND x.tag = a.next_tag);
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT notes_changed_since_the_request CHECK (ok = 1));
INSERT INTO temp.g6 SELECT coalesce(hex(sha3(readfile(notes_file), 256)), '') = notes_sha3 FROM temp.a;

UPDATE approvals SET used_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = (SELECT json_extract(j, '$.approval_id') FROM temp.input)
RETURNING id AS approval_id, action, exact_step, used_at;
