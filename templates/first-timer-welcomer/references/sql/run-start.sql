-- Start a run. Input: kind (scheduled or manual), recent_days (from settings.md, 1 to 90, default 14). Returns run_id.
-- Pass run_id to ingest, newcomers, label-candidates, run-end and digest.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/run-start.sql"
-- Input: write db-input.json with the write tool first, with "step": "run-start".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'run-start'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

INSERT INTO runs (kind, recent_days, started_at)
SELECT json_extract(j, '$.kind'), coalesce(json_extract(j, '$.recent_days'), 14), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input
RETURNING id AS run_id, kind, recent_days, started_at,
          strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || recent_days || ' days') AS opened_after;
