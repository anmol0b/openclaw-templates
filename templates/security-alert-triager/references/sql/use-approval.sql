-- Run right before the write. Input: approval_id, exact_step (the command you are about to run, character for character).
-- Fails unless the approval is granted and unused, the command is the one the owner approved, the alert was fetched again
-- in the last 10 minutes and is still open and unchanged since the request, and a comment's draft still has the approved bytes.
-- Marks the approval used.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/use-approval.sql"
-- Input: write db-input.json with the write tool first, with "step": "use-approval".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'use-approval'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE a AS
SELECT a.*, al.state, al.updated_at, al.last_seen
FROM approvals AS a JOIN alerts AS al ON al.id = a.alert_id
WHERE a.id = (SELECT json_extract(j, '$.approval_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT approval_not_granted_or_already_used CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(decision = 'granted' AND used_at IS NULL) FROM temp.a;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT not_the_approved_command CHECK (ok = 1));
INSERT INTO temp.g2 SELECT a.exact_step = coalesce(json_extract(i.j, '$.exact_step'), '') FROM temp.a AS a, temp.input AS i;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g3 SELECT last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes') FROM temp.a;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT alert_changed_since_the_request CHECK (ok = 1));
INSERT INTO temp.g4 SELECT state = 'open' AND updated_at = seen_updated_at FROM temp.a;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT draft_changed_since_the_request CHECK (ok = 1));
INSERT INTO temp.g5 SELECT body_file = '' OR coalesce(hex(sha3(readfile(body_file), 256)), '') = body_sha3 FROM temp.a;

UPDATE approvals SET used_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = (SELECT json_extract(j, '$.approval_id') FROM temp.input)
RETURNING id AS approval_id, action, exact_step, used_at;
