-- Record what happened after a used approval. Input: approval_id, outcome (done or failed), note (the exact error line when it failed).
-- For done: fetch and ingest the repository again first. This step then checks that GitHub lists a draft release with the tag.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/approval-outcome.sql"
-- Input: write db-input.json with the write tool first, with "step": "approval-outcome".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'approval-outcome'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE a AS
SELECT a.*, d.repo, d.next_tag, r.fetched_at
FROM approvals AS a JOIN drafts AS d ON d.id = a.draft_id JOIN repos AS r ON r.repo = d.repo
WHERE a.id = (SELECT json_extract(j, '$.approval_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT approval_not_used CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(used_at IS NOT NULL) FROM temp.a;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT outcome_not_done_or_failed CHECK (ok = 1));
INSERT INTO temp.g2 SELECT json_extract(j, '$.outcome') IN ('done', 'failed') FROM temp.input;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT fetch_again_after_the_write CHECK (ok = 1));
INSERT INTO temp.g3 SELECT json_extract(i.j, '$.outcome') = 'failed' OR a.fetched_at >= a.used_at FROM temp.input AS i, temp.a AS a;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT draft_release_not_found CHECK (ok = 1));
INSERT INTO temp.g4
SELECT json_extract(i.j, '$.outcome') = 'failed'
    OR EXISTS (SELECT 1 FROM releases AS x WHERE x.repo = a.repo AND x.tag = a.next_tag AND x.is_draft = 1)
FROM temp.input AS i, temp.a AS a;

UPDATE approvals SET
  outcome = (SELECT json_extract(j, '$.outcome') FROM temp.input),
  outcome_note = coalesce((SELECT json_extract(j, '$.note') FROM temp.input), ''),
  outcome_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = (SELECT json_extract(j, '$.approval_id') FROM temp.input)
RETURNING id AS approval_id, action, exact_step, outcome, outcome_note;
