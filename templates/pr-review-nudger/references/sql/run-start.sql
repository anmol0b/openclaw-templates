-- Start a run. Input: kind (scheduled or manual) and the thresholds from settings.md:
-- review_days, author_days, conflict_days (1 to 60), nudge_days (1 to 30), skip_bot_prs (true or false). Returns run_id.
-- Pass run_id to ingest, stuck-list, run-end and digest. Days are counted by the database clock.
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

INSERT INTO runs (kind, review_days, author_days, conflict_days, nudge_days, skip_bot_prs, started_at)
SELECT json_extract(j, '$.kind'), coalesce(json_extract(j, '$.review_days'), 2), coalesce(json_extract(j, '$.author_days'), 7),
       coalesce(json_extract(j, '$.conflict_days'), 3), coalesce(json_extract(j, '$.nudge_days'), 3),
       CASE coalesce(json_extract(j, '$.skip_bot_prs'), 1) WHEN 1 THEN 1 WHEN 0 THEN 0 ELSE -1 END,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input
RETURNING id AS run_id, kind, review_days, author_days, conflict_days, nudge_days, skip_bot_prs, started_at;
