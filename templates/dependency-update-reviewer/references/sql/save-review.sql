-- Record the review of one PR. Input: run_id, pr_id, head_sha (as to-review showed it), verdict (looks-safe, needs-a-look, blocked-by-ci),
-- note (one or two plain sentences), suggested_action (none, approve, comment, bot-command).
-- The verdict may be stricter than the lane floor, never looser. approve is only for looks-safe. Refuses when the bot pushed again since to-review.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/save-review.sql"
-- Input: write db-input.json with the write tool first, with "step": "save-review".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'save-review'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE g (n INTEGER CONSTRAINT head_changed_since_to_review CHECK (n = 1));
INSERT INTO temp.g SELECT count(*) FROM prs
WHERE id = (SELECT json_extract(j, '$.pr_id') FROM temp.input) AND state = 'OPEN'
  AND head_sha = (SELECT json_extract(j, '$.head_sha') FROM temp.input);

BEGIN;
INSERT INTO reviews (pr_id, run_id, head_sha, lane_floor, verdict, note, suggested_action, created_at)
SELECT json_extract(i.j, '$.pr_id'), json_extract(i.j, '$.run_id'), json_extract(i.j, '$.head_sha'), l.lane,
       json_extract(i.j, '$.verdict'), json_extract(i.j, '$.note'),
       coalesce(json_extract(i.j, '$.suggested_action'), 'none'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input AS i JOIN pr_lane AS l ON l.pr_id = json_extract(i.j, '$.pr_id');
UPDATE prs SET reviewed_head = head_sha WHERE id = (SELECT json_extract(j, '$.pr_id') FROM temp.input);
COMMIT;

SELECT r.id AS review_id, r.pr_id, p.repo, p.number, r.lane_floor, r.verdict, r.suggested_action
FROM reviews AS r JOIN prs AS p ON p.id = r.pr_id WHERE r.id = last_insert_rowid();
