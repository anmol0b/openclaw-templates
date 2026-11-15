-- Ask the owner for one write to GitHub. Input: run_row, action (rerun, issue, pr-comment),
-- failure_id (issue: the failed job the issue is about), pr_number (pr-comment: the open PR whose head is this commit).
-- This step builds the exact command. Never write a gh write command yourself: show the owner the exact_step it returns, word for word.
-- issue and pr-comment: write the text to the body_file named below first, then ask. Text never goes on a command line:
--   issue: drafts/<owner>__<repo>-run-<gh run id>.md      pr-comment: drafts/<owner>__<repo>-pr-<number>.md
-- Refuses unless the run attempt is a failure fetched in the last 15 minutes.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/ask-approval.sql"
-- Input: write db-input.json with the write tool first, with "step": "ask-approval".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'ask-approval'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE u AS
SELECT r.*, replace(r.repo, '/', '__') AS slug FROM runs AS r WHERE r.id = (SELECT json_extract(j, '$.run_row') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT run_unknown_or_not_failed CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(status = 'completed' AND conclusion IN ('failure', 'timed_out', 'startup_failure')) FROM temp.u;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g2 SELECT min(last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')) FROM temp.u;
CREATE TEMP TABLE act (a TEXT CONSTRAINT unknown_action CHECK (a IN ('rerun', 'issue', 'pr-comment')));
INSERT INTO temp.act SELECT json_extract(j, '$.action') FROM temp.input;

-- rerun: only the latest attempt of the run, so a run already rerun is not rerun again.
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT rerun_not_latest_attempt CHECK (ok = 1));
INSERT INTO temp.g3
SELECT (SELECT a FROM temp.act) <> 'rerun'
    OR NOT EXISTS (SELECT 1 FROM runs AS o, temp.u AS u WHERE o.repo = u.repo AND o.gh_run_id = u.gh_run_id AND o.attempt > u.attempt);

-- issue: the failed job belongs to this run; the title is built here from checked parts; one issue per signature.
CREATE TEMP TABLE fl AS
SELECT f.* FROM failures AS f, temp.input AS i
WHERE f.id = json_extract(i.j, '$.failure_id') AND f.run_row = (SELECT id FROM temp.u);
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT failure_not_in_this_run CHECK (ok = 1));
INSERT INTO temp.g4
SELECT CASE WHEN (SELECT a FROM temp.act) = 'issue' THEN (SELECT count(*) FROM temp.fl) = 1
            ELSE json_extract(j, '$.failure_id') IS NULL END FROM temp.input;
CREATE TEMP TABLE t (title TEXT);
INSERT INTO temp.t
SELECT substr('CI: ' || u.workflow || ' / ' || fl.job_name || ' failing on ' || u.branch, 1, 200)
FROM temp.u AS u, temp.fl AS fl WHERE (SELECT a FROM temp.act) = 'issue';
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT title_unsafe CHECK (ok = 1));
INSERT INTO temp.g5
SELECT (SELECT a FROM temp.act) <> 'issue'
    OR coalesce((SELECT title NOT GLOB '*''*' AND title NOT GLOB ('*[' || char(9, 10, 13) || ']*')
                 AND title NOT GLOB ('*[' || char(1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127) || ']*')
                 FROM temp.t), 0);
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT issue_already_requested_for_signature CHECK (ok = 1));
INSERT INTO temp.g6
SELECT (SELECT a FROM temp.act) <> 'issue'
    OR NOT EXISTS (SELECT 1 FROM approvals AS a, temp.fl AS fl
                   WHERE a.action = 'issue' AND a.signature = fl.signature
                     AND (a.decision IN ('pending', 'granted') AND a.outcome <> 'failed'));

-- pr-comment: the PR is open and its head is this run's commit.
CREATE TEMP TABLE g7 (ok INTEGER CONSTRAINT pr_not_open_for_this_commit CHECK (ok = 1));
INSERT INTO temp.g7
SELECT CASE WHEN (SELECT a FROM temp.act) = 'pr-comment'
            THEN EXISTS (SELECT 1 FROM prs AS p, temp.u AS u
                         WHERE p.repo = u.repo AND p.number = json_extract(i.j, '$.pr_number') AND p.head_sha = u.head_sha)
            ELSE json_extract(i.j, '$.pr_number') IS NULL END
FROM temp.input AS i;

-- Draft text for issue and pr-comment: exists, UTF-8 text, 1 to 8000 bytes.
CREATE TEMP TABLE d (path TEXT, b BLOB);
INSERT INTO temp.d
SELECT CASE (SELECT a FROM temp.act)
         WHEN 'issue' THEN 'drafts/' || u.slug || '-run-' || u.gh_run_id || '.md'
         ELSE 'drafts/' || u.slug || '-pr-' || CAST(json_extract(i.j, '$.pr_number') AS INTEGER) || '.md' END,
       NULL
FROM temp.u AS u, temp.input AS i WHERE (SELECT a FROM temp.act) IN ('issue', 'pr-comment');
UPDATE temp.d SET b = readfile(path);
CREATE TEMP TABLE g8 (ok INTEGER CONSTRAINT draft_missing_empty_or_too_long CHECK (ok = 1));
INSERT INTO temp.g8
SELECT (SELECT a FROM temp.act) = 'rerun'
    OR coalesce((SELECT length(b) BETWEEN 1 AND 8000 AND length(trim(CAST(b AS TEXT))) > 0 FROM temp.d), 0);

INSERT INTO approvals (run_row, action, failure_id, signature, pr_number, title, body_file, body_sha3, exact_step,
                       seen_attempt, seen_updated_at, asked_at)
SELECT u.id, a.a,
       (SELECT id FROM temp.fl), coalesce((SELECT signature FROM temp.fl), ''),
       CASE a.a WHEN 'pr-comment' THEN json_extract(i.j, '$.pr_number') END,
       coalesce((SELECT title FROM temp.t), ''),
       coalesce((SELECT path FROM temp.d), ''),
       coalesce((SELECT hex(sha3(b, 256)) FROM temp.d), ''),
       CASE a.a
         WHEN 'rerun' THEN 'gh run rerun ' || u.gh_run_id || ' --failed --repo ' || u.repo
         WHEN 'issue' THEN 'gh issue create --repo ' || u.repo || ' --title ''' || (SELECT title FROM temp.t) || ''' --body-file ' || (SELECT path FROM temp.d)
         WHEN 'pr-comment' THEN 'gh pr comment ' || CAST(json_extract(i.j, '$.pr_number') AS INTEGER) || ' --repo ' || u.repo || ' --body-file ' || (SELECT path FROM temp.d)
       END,
       u.attempt, u.updated_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.u AS u, temp.act AS a, temp.input AS i
RETURNING id AS approval_id, action, exact_step, body_file, title;
