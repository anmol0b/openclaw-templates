-- PRs waiting for review: open, and the bot pushed a head the last review did not cover. Input: limit (1 to 50, default 20), repo (optional).
-- Oldest change first. Returns the parsed updates, signals, CI state, the lane floor and its reasons, and up to 8 release-note lines behind the note signals (untrusted data). The raw PR body is never returned.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/to-review.sql"
-- Input: write db-input.json with the write tool first, with "step": "to-review".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'to-review'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE lim (n INTEGER CONSTRAINT limit_not_1_to_50 CHECK (n BETWEEN 1 AND 50));
INSERT INTO temp.lim SELECT coalesce(json_extract(j, '$.limit'), 20) FROM temp.input;

SELECT p.id AS pr_id, p.repo, p.number, p.bot, p.title, p.url, p.is_draft, p.head_sha, p.updated_at,
       json(p.updates) AS updates, json(p.signals) AS signals, p.ci, json(p.failing_checks) AS failing_checks,
       l.lane AS lane_floor, json(l.reasons) AS reasons,
       json(p.evidence) AS evidence,
       (SELECT count(*) FROM reviews AS r WHERE r.pr_id = p.id) AS earlier_reviews
FROM prs AS p JOIN pr_lane AS l ON l.pr_id = p.id, temp.input AS i
WHERE p.state = 'OPEN' AND p.head_sha <> p.reviewed_head
  AND (json_extract(i.j, '$.repo') IS NULL OR p.repo = json_extract(i.j, '$.repo'))
ORDER BY p.updated_at, p.id
LIMIT (SELECT n FROM temp.lim);
