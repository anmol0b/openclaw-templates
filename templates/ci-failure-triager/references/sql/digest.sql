-- The digest data for one cycle, as one JSON object: reads (with gaps and fetch errors), triaged runs grouped
-- by verdict, repeating signatures, runs still waiting, and open requests.
-- Input: cycle_id. Read only. Write the digest from this result and templates/digest.md; never from memory.
-- Run from the workspace root:
--   sqlite3 -bail <db_path> ".read references/sql/digest.sql"
-- No -json flag here: the step prints one JSON object as it is.
-- Input: write db-input.json with the write tool first, with "step": "digest".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'digest'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE cycle_guard (n INTEGER CONSTRAINT unknown_cycle CHECK (n = 1));
INSERT INTO temp.cycle_guard SELECT count(*) FROM cycles WHERE id = (SELECT json_extract(j, '$.cycle_id') FROM temp.input);

SELECT json_object(
  'cycle', (SELECT json_object('cycle_id', id, 'kind', kind, 'started_at', started_at, 'ended_at', ended_at, 'note', note)
            FROM cycles WHERE id = (SELECT json_extract(j, '$.cycle_id') FROM temp.input)),
  'reads', (SELECT json_group_array(json_object('repo', repo, 'run_count', run_count, 'failed_runs', failed_runs,
                   'new_failed', new_failed, 'logs_left', logs_left, 'gap', gap, 'errors', json(errors), 'fetched_at', fetched_at))
            FROM reads WHERE cycle_id = (SELECT json_extract(j, '$.cycle_id') FROM temp.input)),
  'triaged', (SELECT json_group_array(json_object('repo', u.repo, 'workflow', u.workflow, 'branch', u.branch,
                     'gh_run_id', u.gh_run_id, 'attempt', u.attempt, 'url', u.url, 'head_sha', substr(u.head_sha, 1, 12),
                     'verdict', t.verdict, 'first_bad_sha', substr(t.first_bad_sha, 1, 12), 'reason', t.reason,
                     'suggested_action', t.suggested_action,
                     'jobs', (SELECT json_group_array(fl.job_name) FROM failures AS fl WHERE fl.run_row = u.id)))
              FROM (SELECT * FROM triage WHERE cycle_id = (SELECT json_extract(j, '$.cycle_id') FROM temp.input) ORDER BY id) AS t
              JOIN runs AS u ON u.id = t.run_row),
  'repeating', (SELECT json_group_array(json_object('signature', signature, 'job_name', job_name, 'runs', n, 'last_seen', last_at))
                FROM (SELECT fl.signature, max(fl.job_name) AS job_name, count(DISTINCT fl.run_row) AS n, max(u.created_at) AS last_at
                      FROM failures AS fl JOIN runs AS u ON u.id = fl.run_row
                      GROUP BY fl.signature HAVING count(DISTINCT fl.run_row) > 1
                      ORDER BY n DESC, last_at DESC LIMIT 10)),
  'still_waiting', (SELECT count(*) FROM runs AS u
                    WHERE u.status = 'completed' AND u.conclusion IN ('failure', 'timed_out', 'startup_failure')
                      AND NOT EXISTS (SELECT 1 FROM triage AS t WHERE t.run_row = u.id)),
  'open_requests', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', u.repo, 'gh_run_id', u.gh_run_id,
                           'action', a.action, 'exact_step', a.exact_step, 'decision', a.decision, 'asked_at', a.asked_at,
                           'run_changed', u.updated_at <> a.seen_updated_at
                              OR EXISTS (SELECT 1 FROM runs AS o WHERE o.repo = u.repo AND o.gh_run_id = u.gh_run_id AND o.attempt > a.seen_attempt)))
                    FROM (SELECT * FROM approvals WHERE decision = 'pending' OR (decision = 'granted' AND used_at IS NULL) ORDER BY id) AS a
                    JOIN runs AS u ON u.id = a.run_row)
);
