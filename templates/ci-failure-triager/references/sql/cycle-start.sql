-- Start a triage cycle. Input: kind (scheduled or manual). Returns cycle_id. Pass it to ingest, save-triage, cycle-end and digest.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/cycle-start.sql"
-- Input: write db-input.json with the write tool first, with "step": "cycle-start".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'cycle-start'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

INSERT INTO cycles (kind, started_at)
SELECT json_extract(j, '$.kind'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now') FROM temp.input
RETURNING id AS cycle_id, kind, started_at;
