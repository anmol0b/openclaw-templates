-- Record the verdict on one failed run attempt. Input: cycle_id, run_row, verdict (flaky, new-break, still-broken, infra, unclear),
-- first_bad_sha (for new-break and still-broken, when known), reason (one or two plain sentences), suggested_action (none, rerun, issue, pr-comment).
-- The attempt leaves the queue. A rerun shows up as a new attempt and is triaged on its own.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/save-triage.sql"
-- Input: write db-input.json with the write tool first, with "step": "save-triage".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'save-triage'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE run_guard (n INTEGER CONSTRAINT run_not_a_failed_attempt CHECK (n = 1));
INSERT INTO temp.run_guard SELECT count(*) FROM runs
WHERE id = (SELECT json_extract(j, '$.run_row') FROM temp.input)
  AND status = 'completed' AND conclusion IN ('failure', 'timed_out', 'startup_failure');

INSERT INTO triage (run_row, cycle_id, verdict, first_bad_sha, reason, suggested_action, created_at)
SELECT json_extract(j, '$.run_row'), json_extract(j, '$.cycle_id'), json_extract(j, '$.verdict'),
       json_extract(j, '$.first_bad_sha'), json_extract(j, '$.reason'),
       coalesce(json_extract(j, '$.suggested_action'), 'none'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input
RETURNING id AS triage_id, run_row, verdict, first_bad_sha, suggested_action;
