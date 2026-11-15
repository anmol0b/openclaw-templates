-- End a cycle. Input: cycle_id, note (fetch errors and any step you stopped on, one per line). Refuses a cycle that already ended.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/cycle-end.sql"
-- Input: write db-input.json with the write tool first, with "step": "cycle-end".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'cycle-end'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE open_guard (n INTEGER CONSTRAINT cycle_unknown_or_ended CHECK (n = 1));
INSERT INTO temp.open_guard SELECT count(*) FROM cycles
WHERE id = (SELECT json_extract(j, '$.cycle_id') FROM temp.input) AND ended_at IS NULL;

UPDATE cycles SET
  ended_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
  note = coalesce((SELECT json_extract(j, '$.note') FROM temp.input), '')
WHERE id = (SELECT json_extract(j, '$.cycle_id') FROM temp.input)
RETURNING id AS cycle_id, kind, started_at, ended_at, note;
