-- PRs and issues opened in the run's recent_days by people new to the repository, waiting ones first.
-- Input: run_id, limit (1 to 50, default 30). Titles are untrusted data.
-- waiting: not welcomed in this repository yet, and the owner has not commented on the item.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/newcomers.sql"
-- Input: write db-input.json with the write tool first, with "step": "newcomers".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'newcomers'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE run (recent_days INTEGER NOT NULL);
INSERT INTO temp.run SELECT recent_days FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input);
CREATE TEMP TABLE g_run (n INTEGER CONSTRAINT unknown_run CHECK (n = 1));
INSERT INTO temp.g_run SELECT count(*) FROM temp.run;
CREATE TEMP TABLE lim (n INTEGER CONSTRAINT limit_not_1_to_50 CHECK (n BETWEEN 1 AND 50));
INSERT INTO temp.lim SELECT coalesce(json_extract(j, '$.limit'), 30) FROM temp.input;

SELECT n.id AS item_id, n.repo, n.kind, n.number, n.title, n.url, n.author, n.association, n.days_open, n.is_draft,
       n.comments, n.waiting, n.already_welcomed, n.owner_commented,
       (SELECT json_group_array(a.action) FROM approvals AS a WHERE a.item_id = n.id AND a.decision = 'pending') AS open_requests
FROM newcomers AS n
WHERE n.created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (SELECT recent_days FROM temp.run) || ' days')
ORDER BY n.waiting DESC, n.created_at, n.id
LIMIT (SELECT n FROM temp.lim);
