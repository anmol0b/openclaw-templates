-- Run right before the write. Input: approval_id, exact_step (the command you are about to run, character for character).
-- Fails unless the approval is granted and unused, the command is the one the owner approved, the repository was fetched
-- in the last 10 minutes and the run is unchanged since the request, a draft still has the exact bytes the owner approved,
-- and for pr-comment the PR is still open on this commit. Marks the approval used.
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
SELECT a.*, u.repo, u.gh_run_id, u.head_sha, u.updated_at, u.last_seen
FROM approvals AS a JOIN runs AS u ON u.id = a.run_row
WHERE a.id = (SELECT json_extract(j, '$.approval_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT approval_not_granted_or_already_used CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(decision = 'granted' AND used_at IS NULL) FROM temp.a;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT not_the_approved_command CHECK (ok = 1));
INSERT INTO temp.g2 SELECT a.exact_step = coalesce(json_extract(i.j, '$.exact_step'), '') FROM temp.a AS a, temp.input AS i;
-- The repository's latest fetch, not this attempt's: a run already rerun drops out of the list.
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g3
SELECT coalesce((SELECT max(r.fetched_at) FROM reads AS r WHERE r.repo = a.repo), '') >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes')
FROM temp.a AS a;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT run_changed_since_the_request CHECK (ok = 1));
INSERT INTO temp.g4
SELECT a.updated_at = a.seen_updated_at
   AND NOT EXISTS (SELECT 1 FROM runs AS o WHERE o.repo = a.repo AND o.gh_run_id = a.gh_run_id AND o.attempt > a.seen_attempt)
FROM temp.a AS a;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT draft_changed_since_the_request CHECK (ok = 1));
INSERT INTO temp.g5 SELECT action = 'rerun' OR coalesce(hex(sha3(readfile(body_file), 256)), '') = body_sha3 FROM temp.a;
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT pr_not_open_for_this_commit CHECK (ok = 1));
INSERT INTO temp.g6
SELECT action <> 'pr-comment'
    OR EXISTS (SELECT 1 FROM prs AS p WHERE p.repo = a.repo AND p.number = a.pr_number AND p.head_sha = a.head_sha)
FROM temp.a AS a;

UPDATE approvals SET used_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = (SELECT json_extract(j, '$.approval_id') FROM temp.input)
RETURNING id AS approval_id, action, exact_step, used_at;
