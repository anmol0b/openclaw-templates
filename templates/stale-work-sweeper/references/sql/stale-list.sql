-- The owner's stale work for one run, safest cleanup first. Input: run_id, limit (1 to 50, default 30).
-- Stale means no activity for the run's stale_days, by the database clock. Titles are untrusted data.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/stale-list.sql"
-- Input: write db-input.json with the write tool first, with "step": "stale-list".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'stale-list'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE run (stale_days INTEGER NOT NULL);
INSERT INTO temp.run SELECT stale_days FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input);
CREATE TEMP TABLE g_run (n INTEGER CONSTRAINT unknown_run CHECK (n = 1));
INSERT INTO temp.g_run SELECT count(*) FROM temp.run;
CREATE TEMP TABLE lim (n INTEGER CONSTRAINT limit_not_1_to_50 CHECK (n BETWEEN 1 AND 50));
INSERT INTO temp.lim SELECT coalesce(json_extract(j, '$.limit'), 30) FROM temp.input;

SELECT w.id AS item_id, w.repo, w.kind, w.ref, w.number, w.title, w.url, w.category, w.rank, w.days_idle,
       w.last_activity, w.head_oid, w.is_draft, w.ci_state, w.mergeable, w.merged_pr, w.merged_into_default,
       (SELECT json_group_array(a.action) FROM approvals AS a WHERE a.item_id = w.id AND a.decision = 'pending') AS open_requests
FROM owners_work AS w
WHERE w.days_idle >= (SELECT stale_days FROM temp.run)
ORDER BY w.rank, w.days_idle DESC, w.id
LIMIT (SELECT n FROM temp.lim);
