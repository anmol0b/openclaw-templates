-- Record what happened after a used approval. Input: approval_id, outcome (done or failed), note (the exact error line when it failed),
-- issue_url (issue only: the URL gh issue create printed).
-- For done: fetch and ingest the repository again first. done for dismiss is refused unless that fetch shows the alert
-- dismissed with the approved reason (GitHub can turn a dismissal into a dismissal request instead; record failed then).
-- done for issue needs the new issue's URL in this repository.
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
SELECT a.*, al.repo, al.state, al.dismissed_reason, al.last_seen FROM approvals AS a JOIN alerts AS al ON al.id = a.alert_id
WHERE a.id = (SELECT json_extract(j, '$.approval_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT approval_not_used CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(used_at IS NOT NULL) FROM temp.a;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT outcome_not_done_or_failed CHECK (ok = 1));
INSERT INTO temp.g2 SELECT json_extract(j, '$.outcome') IN ('done', 'failed') FROM temp.input;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT fetch_again_after_the_write CHECK (ok = 1));
INSERT INTO temp.g3 SELECT json_extract(i.j, '$.outcome') = 'failed' OR a.last_seen >= a.used_at FROM temp.input AS i, temp.a AS a;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT alert_not_dismissed_after_the_write CHECK (ok = 1));
INSERT INTO temp.g4 SELECT a.action <> 'dismiss' OR json_extract(i.j, '$.outcome') = 'failed'
       OR (a.state = 'dismissed' AND a.dismissed_reason = a.reason)
FROM temp.input AS i, temp.a AS a;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT issue_url_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.g5 SELECT a.action <> 'issue' OR json_extract(i.j, '$.outcome') = 'failed'
       OR (substr(coalesce(json_extract(i.j, '$.issue_url'), ''), 1, length('https://github.com/' || a.repo || '/issues/')) = 'https://github.com/' || a.repo || '/issues/'
           COLLATE NOCASE
           AND substr(json_extract(i.j, '$.issue_url'), length('https://github.com/' || a.repo || '/issues/') + 1) GLOB '[1-9]*'
           AND substr(json_extract(i.j, '$.issue_url'), length('https://github.com/' || a.repo || '/issues/') + 1) NOT GLOB '*[^0-9]*')
FROM temp.input AS i, temp.a AS a;

UPDATE approvals SET
  outcome = (SELECT json_extract(j, '$.outcome') FROM temp.input),
  outcome_note = coalesce((SELECT json_extract(j, '$.note') FROM temp.input), ''),
  issue_url = CASE WHEN action = 'issue' AND (SELECT json_extract(j, '$.outcome') FROM temp.input) = 'done'
                   THEN (SELECT json_extract(j, '$.issue_url') FROM temp.input) ELSE '' END,
  outcome_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = (SELECT json_extract(j, '$.approval_id') FROM temp.input)
RETURNING id AS approval_id, action, exact_step, outcome, outcome_note, issue_url;
