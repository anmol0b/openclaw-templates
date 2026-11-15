-- Ingest the files fetch.mjs wrote for one repository: runs, open PRs and failed jobs.
-- Input: repo, cycle_id (or null outside a cycle).
-- Returns run_count, failed_runs, new_failed, logs_left (failed runs whose log waits for the
-- next fetch) and gap (1 when runs between this fetch and the last may have been missed).
-- Run from the workspace root, right after `node references/fetch.mjs <repo>`:
--   sqlite3 -bail -json <db_path> ".read references/sql/ingest.sql"
-- Input: write db-input.json with the write tool first, with "step": "ingest".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'ingest'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

-- The repository must be registered (add-repo.sql); its checked name keeps the path inside inbox/.
CREATE TEMP TABLE r (repo TEXT NOT NULL, dir TEXT NOT NULL);
INSERT INTO temp.r SELECT p.repo, 'inbox/' || replace(p.repo, '/', '__') || '/'
FROM repos AS p, temp.input AS i WHERE p.repo = json_extract(i.j, '$.repo');
CREATE TEMP TABLE repo_guard (n INTEGER CONSTRAINT repo_not_registered CHECK (n = 1));
INSERT INTO temp.repo_guard SELECT count(*) FROM temp.r;

CREATE TEMP TABLE f (repo TEXT, fetched_at TEXT, run_limit INTEGER, logs_left INTEGER, errors TEXT);
INSERT INTO temp.f
SELECT json_extract(s, '$.repo'), json_extract(s, '$.fetched_at'), json_extract(s, '$.limits.runs'),
       json_extract(s, '$.logs_left_for_next_fetch'), coalesce(json_extract(s, '$.errors'), '[]')
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s);
CREATE TEMP TABLE fetch_guard (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.fetch_guard
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo) AND min(f.run_limit > 0) AND min(f.logs_left >= 0)
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'), 0)
FROM temp.f AS f, temp.r AS r;

CREATE TEMP TABLE src (name TEXT NOT NULL, doc TEXT NOT NULL CONSTRAINT inbox_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
INSERT INTO temp.src SELECT 'runs', CAST(readfile(dir || 'runs.json') AS TEXT) FROM temp.r;
INSERT INTO temp.src SELECT 'prs', CAST(readfile(dir || 'prs.json') AS TEXT) FROM temp.r;
INSERT INTO temp.src SELECT 'failures', CAST(readfile(dir || 'failures.json') AS TEXT) FROM temp.r;

-- Every row is checked here, at the trust boundary. JSON types are checked before column
-- affinity could turn a string like "12" into 12. A bad row stops the whole step.
CREATE TEMP TABLE b (
  gh_run_id INTEGER NOT NULL,
  id_type TEXT NOT NULL CONSTRAINT run_id_not_integer CHECK (id_type = 'integer'),
  attempt INTEGER NOT NULL,
  attempt_type TEXT NOT NULL CONSTRAINT attempt_not_integer CHECK (attempt_type = 'integer'),
  workflow TEXT NOT NULL CONSTRAINT workflow_name_too_long CHECK (length(workflow) <= 100),
  title TEXT NOT NULL,
  event TEXT NOT NULL,
  branch TEXT NOT NULL CONSTRAINT branch_too_long CHECK (length(branch) <= 255),
  head_sha TEXT NOT NULL,
  status TEXT NOT NULL,
  conclusion TEXT NOT NULL,
  created TEXT NOT NULL,
  updated TEXT NOT NULL,
  url TEXT NOT NULL,
  UNIQUE (gh_run_id, attempt)
);
INSERT INTO temp.b
SELECT json_extract(e.value, '$.databaseId'), coalesce(json_type(e.value, '$.databaseId'), 'missing'),
       json_extract(e.value, '$.attempt'), coalesce(json_type(e.value, '$.attempt'), 'missing'),
       coalesce(json_extract(e.value, '$.workflowName'), ''),
       -- The run title is the commit headline or PR title: free text, cut to 120 characters.
       substr(coalesce(json_extract(e.value, '$.displayTitle'), ''), 1, 120),
       coalesce(json_extract(e.value, '$.event'), ''),
       coalesce(json_extract(e.value, '$.headBranch'), ''),
       coalesce(json_extract(e.value, '$.headSha'), ''),
       coalesce(json_extract(e.value, '$.status'), ''),
       coalesce(json_extract(e.value, '$.conclusion'), ''),
       coalesce(json_extract(e.value, '$.createdAt'), ''),
       coalesce(json_extract(e.value, '$.updatedAt'), ''),
       coalesce(json_extract(e.value, '$.url'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.name = 'runs';

CREATE TEMP TABLE pr (number INTEGER NOT NULL, n_type TEXT NOT NULL CONSTRAINT pr_number_not_integer CHECK (n_type = 'integer'),
                      head_sha TEXT NOT NULL, url TEXT NOT NULL);
INSERT INTO temp.pr
SELECT json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       coalesce(json_extract(e.value, '$.headRefOid'), ''), coalesce(json_extract(e.value, '$.url'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.name = 'prs';

CREATE TEMP TABLE fl (
  gh_run_id INTEGER NOT NULL, attempt INTEGER NOT NULL,
  job_id INTEGER NOT NULL, job_type TEXT NOT NULL CONSTRAINT job_id_not_integer CHECK (job_type = 'integer'),
  job_name TEXT NOT NULL, job_url TEXT NOT NULL, failed_steps TEXT NOT NULL, error_lines TEXT NOT NULL,
  excerpt TEXT NOT NULL, log_found INTEGER NOT NULL, log_error TEXT NOT NULL, signature TEXT NOT NULL
);
INSERT INTO temp.fl
SELECT json_extract(e.value, '$.run_id'), json_extract(e.value, '$.attempt'),
       json_extract(e.value, '$.job_id'), coalesce(json_type(e.value, '$.job_id'), 'missing'),
       substr(coalesce(json_extract(e.value, '$.job_name'), ''), 1, 100),
       coalesce(json_extract(e.value, '$.job_url'), ''),
       -- The caps are applied again here, whatever the file holds.
       (SELECT json_group_array(substr(CAST(v.value AS TEXT), 1, 100)) FROM json_each(e.value, '$.failed_steps') AS v WHERE v.key < 10),
       (SELECT json_group_array(substr(CAST(v.value AS TEXT), 1, 200)) FROM json_each(e.value, '$.error_lines') AS v WHERE v.key < 5),
       substr(coalesce(json_extract(e.value, '$.excerpt'), ''), 1, 3000),
       CASE WHEN json_extract(e.value, '$.log_found') THEN 1 ELSE 0 END,
       substr(coalesce(json_extract(e.value, '$.log_error'), ''), 1, 300),
       coalesce(json_extract(e.value, '$.signature'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.name = 'failures';

CREATE TEMP TABLE before (newest TEXT);
INSERT INTO temp.before SELECT max(created_at) FROM runs WHERE repo = (SELECT repo FROM temp.r);

CREATE TEMP TABLE stats (run_count INTEGER, failed_runs INTEGER, new_failed INTEGER, gap INTEGER);
INSERT INTO temp.stats
SELECT (SELECT count(*) FROM temp.b),
       (SELECT count(*) FROM temp.b WHERE status = 'completed' AND conclusion IN ('failure', 'timed_out', 'startup_failure')),
       (SELECT count(*) FROM temp.b AS x
         WHERE x.status = 'completed' AND x.conclusion IN ('failure', 'timed_out', 'startup_failure')
           AND NOT EXISTS (SELECT 1 FROM runs AS u, temp.r AS r
                           WHERE u.repo = r.repo AND u.gh_run_id = x.gh_run_id AND u.attempt = x.attempt)),
       CASE WHEN (SELECT count(*) FROM temp.b) >= (SELECT run_limit FROM temp.f)
             AND (SELECT newest FROM temp.before) IS NOT NULL
             AND (SELECT min(created) FROM temp.b) > (SELECT newest FROM temp.before)
            THEN 1 ELSE 0 END;

BEGIN;

INSERT INTO runs (repo, gh_run_id, attempt, workflow, title, event, branch, head_sha, status, conclusion,
                  created_at, updated_at, url, first_seen, last_seen)
SELECT r.repo, x.gh_run_id, x.attempt, x.workflow, x.title, x.event, x.branch, x.head_sha, x.status, x.conclusion,
       x.created, x.updated, x.url, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), f.fetched_at
FROM temp.b AS x, temp.r AS r, temp.f AS f
WHERE true
ON CONFLICT (repo, gh_run_id, attempt) DO UPDATE SET
  title = excluded.title,
  status = excluded.status,
  conclusion = excluded.conclusion,
  updated_at = excluded.updated_at,
  last_seen = excluded.last_seen;

INSERT INTO failures (run_row, job_id, job_name, job_url, failed_steps, error_lines, excerpt, log_found, log_error, signature)
SELECT u.id, x.job_id, x.job_name, x.job_url, x.failed_steps, x.error_lines, x.excerpt, x.log_found, x.log_error, x.signature
FROM temp.fl AS x JOIN runs AS u ON u.repo = (SELECT repo FROM temp.r) AND u.gh_run_id = x.gh_run_id AND u.attempt = x.attempt
WHERE true
ON CONFLICT (run_row, job_id) DO NOTHING;

DELETE FROM prs WHERE repo = (SELECT repo FROM temp.r);
INSERT INTO prs (repo, number, head_sha, url)
SELECT r.repo, p.number, p.head_sha, p.url FROM temp.pr AS p, temp.r AS r;

INSERT INTO reads (cycle_id, repo, fetched_at, run_count, failed_runs, new_failed, logs_left, gap, errors, ingested_at)
SELECT json_extract(i.j, '$.cycle_id'), r.repo, f.fetched_at, s.run_count, s.failed_runs, s.new_failed, f.logs_left, s.gap,
       json(f.errors), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.stats AS s, temp.r AS r, temp.f AS f, temp.input AS i;

COMMIT;

SELECT repo, run_count, failed_runs, new_failed, logs_left, gap, json(errors) AS errors, fetched_at
FROM reads WHERE id = (SELECT max(id) FROM reads);
