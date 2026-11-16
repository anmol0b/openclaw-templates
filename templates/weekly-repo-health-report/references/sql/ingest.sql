-- Ingest the files fetch.mjs wrote for one repository and save this week's snapshot.
-- Input: repo, run_id, stale_pr_days and stale_issue_days (1 to 365), exclude_bot_prs (true or false), all from settings.md.
-- The snapshot's week is the ISO week (UTC) of the fetch. A second ingest in the same week replaces it.
-- Returns the saved snapshot row.
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

-- Settings from the input.
CREATE TEMP TABLE opt (
  -- No declared types here, so a number sent as text stays text and is refused.
  run_id,
  stale_pr_days CONSTRAINT stale_days_not_1_to_365 CHECK (typeof(stale_pr_days) = 'integer' AND stale_pr_days BETWEEN 1 AND 365),
  stale_issue_days CONSTRAINT stale_days_not_1_to_365 CHECK (typeof(stale_issue_days) = 'integer' AND stale_issue_days BETWEEN 1 AND 365),
  bots_type TEXT CONSTRAINT exclude_bot_prs_not_true_or_false CHECK (bots_type IN ('true', 'false')),
  exclude_bots INTEGER NOT NULL
);
INSERT INTO temp.opt
SELECT json_extract(j, '$.run_id'), coalesce(json_extract(j, '$.stale_pr_days'), 14), coalesce(json_extract(j, '$.stale_issue_days'), 30),
       coalesce(json_type(j, '$.exclude_bot_prs'), 'true'), coalesce(json_extract(j, '$.exclude_bot_prs'), 1)
FROM temp.input;
CREATE TEMP TABLE g_run (n INTEGER CONSTRAINT run_unknown_or_ended CHECK (n = 1));
INSERT INTO temp.g_run SELECT count(*) FROM runs WHERE id = (SELECT run_id FROM temp.opt) AND ended_at IS NULL;

-- The repository must be registered (add-repo.sql). Its name is checked there, so the
-- inbox path built from it stays inside inbox/.
CREATE TEMP TABLE r (repo TEXT NOT NULL, dir TEXT NOT NULL);
INSERT INTO temp.r
SELECT p.repo, 'inbox/' || replace(p.repo, '/', '__') || '/'
FROM repos AS p, temp.input AS i WHERE p.repo = json_extract(i.j, '$.repo');
CREATE TEMP TABLE g_repo (n INTEGER CONSTRAINT repo_not_registered CHECK (n = 1));
INSERT INTO temp.g_repo SELECT count(*) FROM temp.r;

CREATE TEMP TABLE f AS
SELECT json_extract(s, '$.repo') AS repo,
       json_extract(s, '$.default_branch') AS default_branch,
       json_extract(s, '$.issues_enabled') AS issues_enabled,
       json_extract(s, '$.window_days') AS window_days,
       json_extract(s, '$.window_start') AS window_start,
       json_extract(s, '$.fetched_at') AS fetched_at,
       json_extract(s, '$.limits.window_prs') AS l_wp,
       json_extract(s, '$.limits.window_issues') AS l_wi,
       json_extract(s, '$.limits.open_prs') AS l_op,
       json_extract(s, '$.limits.open_issues') AS l_oi,
       json_extract(s, '$.limits.runs') AS l_runs
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s) WHERE json_valid(s);
CREATE TEMP TABLE g_fetch (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.g_fetch
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo)
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
                AND min(f.window_days BETWEEN 1 AND 31)
                AND min(f.window_start = strftime('%Y-%m-%dT%H:%M:%SZ', f.fetched_at, '-' || f.window_days || ' days'))
                AND min(length(f.default_branch) BETWEEN 1 AND 255)
                AND min(f.l_wp > 0 AND f.l_wi > 0 AND f.l_op > 0 AND f.l_oi > 0 AND f.l_runs > 0), 0)
FROM temp.f AS f, temp.r AS r;
-- A snapshot is this week's numbers, so the fetch must be from the last hour.
CREATE TEMP TABLE g_fresh (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g_fresh
SELECT fetched_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-60 minutes')
   AND fetched_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+5 minutes')
FROM temp.f;

CREATE TEMP TABLE src (kind TEXT NOT NULL, doc TEXT NOT NULL CONSTRAINT inbox_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
INSERT INTO temp.src SELECT 'window_prs', coalesce(CAST(readfile(dir || 'window_prs.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'window_issues', coalesce(CAST(readfile(dir || 'window_issues.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'open_prs', coalesce(CAST(readfile(dir || 'open_prs.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'open_issues', coalesce(CAST(readfile(dir || 'open_issues.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'runs', coalesce(CAST(readfile(dir || 'runs.json') AS TEXT), 'x') FROM temp.r;

-- Every row is checked here, at the trust boundary. A bad row stops the whole step.
CREATE TEMP TABLE wp (
  number INTEGER NOT NULL UNIQUE,
  number_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (number_type = 'integer'),
  state TEXT NOT NULL CONSTRAINT state_unknown CHECK (state IN ('OPEN', 'CLOSED', 'MERGED')),
  created_at TEXT NOT NULL,
  merged_at TEXT,
  closed_at TEXT,
  author TEXT NOT NULL CONSTRAINT login_not_valid CHECK (length(author) <= 60 AND author NOT GLOB '*[^A-Za-z0-9_./-]*'),
  is_bot INTEGER NOT NULL,
  reviews TEXT NOT NULL CONSTRAINT reviews_not_a_list CHECK (json_valid(reviews) AND json_type(reviews) = 'array'),
  CONSTRAINT time_not_iso_utc CHECK (
    created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
    AND (merged_at IS NULL OR merged_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
    AND (closed_at IS NULL OR closed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')),
  CONSTRAINT merged_pr_without_merge_time CHECK (state <> 'MERGED' OR merged_at IS NOT NULL)
);
INSERT INTO temp.wp
SELECT json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       coalesce(json_extract(e.value, '$.state'), ''), coalesce(json_extract(e.value, '$.createdAt'), ''),
       json_extract(e.value, '$.mergedAt'), json_extract(e.value, '$.closedAt'),
       coalesce(json_extract(e.value, '$.author'), ''),
       CASE WHEN json_extract(e.value, '$.authorIsBot') THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.reviews'), '[]')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind = 'window_prs';

CREATE TEMP TABLE rv (
  number INTEGER NOT NULL,
  author TEXT NOT NULL CONSTRAINT login_not_valid CHECK (length(author) <= 60 AND author NOT GLOB '*[^A-Za-z0-9_./-]*'),
  is_bot INTEGER NOT NULL,
  state TEXT NOT NULL,
  submitted_at TEXT CONSTRAINT time_not_iso_utc CHECK (submitted_at IS NULL OR submitted_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
);
INSERT INTO temp.rv
SELECT p.number, coalesce(json_extract(v.value, '$.author'), ''),
       CASE WHEN json_extract(v.value, '$.authorIsBot') THEN 1 ELSE 0 END, coalesce(json_extract(v.value, '$.state'), ''),
       json_extract(v.value, '$.submittedAt')
FROM temp.wp AS p, json_each(p.reviews) AS v;

CREATE TEMP TABLE wi (
  number INTEGER NOT NULL UNIQUE,
  number_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (number_type = 'integer'),
  state TEXT NOT NULL CONSTRAINT state_unknown CHECK (state IN ('OPEN', 'CLOSED')),
  created_at TEXT NOT NULL,
  closed_at TEXT,
  CONSTRAINT time_not_iso_utc CHECK (
    created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
    AND (closed_at IS NULL OR closed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'))
);
INSERT INTO temp.wi
SELECT json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       coalesce(json_extract(e.value, '$.state'), ''), coalesce(json_extract(e.value, '$.createdAt'), ''),
       json_extract(e.value, '$.closedAt')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind = 'window_issues';

-- Open PRs and issues (kind 'pr' or 'issue').
CREATE TEMP TABLE op (
  kind TEXT NOT NULL,
  number INTEGER NOT NULL,
  number_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (number_type = 'integer'),
  is_draft INTEGER NOT NULL,
  is_bot INTEGER NOT NULL,
  updated_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  UNIQUE (kind, number)
);
INSERT INTO temp.op
SELECT CASE s.kind WHEN 'open_prs' THEN 'pr' ELSE 'issue' END,
       json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       CASE WHEN json_extract(e.value, '$.isDraft') THEN 1 ELSE 0 END,
       CASE WHEN json_extract(e.value, '$.authorIsBot') THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.updatedAt'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind IN ('open_prs', 'open_issues');

CREATE TEMP TABLE ru (
  id INTEGER NOT NULL UNIQUE,
  id_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (id_type = 'integer'),
  status TEXT NOT NULL CONSTRAINT state_unknown CHECK (length(status) BETWEEN 1 AND 30 AND status NOT GLOB '*[^a-z_]*'),
  conclusion TEXT NOT NULL CONSTRAINT state_unknown CHECK (length(conclusion) <= 30 AND conclusion NOT GLOB '*[^a-z_]*'),
  created_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
);
INSERT INTO temp.ru
SELECT json_extract(e.value, '$.id'), coalesce(json_type(e.value, '$.id'), 'missing'),
       coalesce(json_extract(e.value, '$.status'), ''), coalesce(json_extract(e.value, '$.conclusion'), ''),
       coalesce(json_extract(e.value, '$.createdAt'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind = 'runs';

-- The numbers. PRs from bots are left out of every PR number when exclude_bot_prs is true.
CREATE TEMP TABLE pr AS
SELECT p.* FROM temp.wp AS p, temp.opt AS o WHERE NOT (o.exclude_bots AND p.is_bot);
CREATE TEMP TABLE merged AS
SELECT p.number,
       round((julianday(p.merged_at) - julianday(p.created_at)) * 24, 1) AS merge_hours,
       round((julianday((SELECT min(v.submitted_at) FROM temp.rv AS v
                         WHERE v.number = p.number AND v.submitted_at IS NOT NULL AND v.state <> 'PENDING'
                           AND v.is_bot = 0 AND lower(v.author) <> lower(p.author)))
              - julianday(p.created_at)) * 24, 1) AS review_hours
FROM temp.pr AS p, temp.f AS f
WHERE p.state = 'MERGED' AND p.merged_at >= f.window_start;

CREATE TEMP TABLE m AS
SELECT
  (SELECT count(*) FROM temp.pr AS p WHERE p.created_at >= f.window_start) AS prs_opened,
  (SELECT count(*) FROM temp.merged) AS prs_merged,
  (SELECT count(*) FROM temp.pr AS p WHERE p.state = 'CLOSED' AND p.closed_at >= f.window_start) AS prs_closed_unmerged,
  (SELECT count(*) FROM temp.wi AS i WHERE i.created_at >= f.window_start) AS issues_opened,
  (SELECT count(*) FROM temp.wi AS i WHERE i.state = 'CLOSED' AND i.closed_at >= f.window_start) AS issues_closed,
  (SELECT count(*) FROM temp.merged WHERE review_hours IS NOT NULL) AS merged_reviewed,
  (SELECT count(*) FROM temp.merged WHERE review_hours IS NULL) AS merged_without_review,
  (SELECT round(avg(h), 1) FROM (SELECT review_hours AS h, row_number() OVER (ORDER BY review_hours) AS rn, count(*) OVER () AS c
                                 FROM temp.merged WHERE review_hours IS NOT NULL) WHERE rn IN ((c + 1) / 2, (c + 2) / 2)) AS review_hours_median,
  (SELECT round(avg(h), 1) FROM (SELECT merge_hours AS h, row_number() OVER (ORDER BY merge_hours) AS rn, count(*) OVER () AS c
                                 FROM temp.merged) WHERE rn IN ((c + 1) / 2, (c + 2) / 2)) AS merge_hours_median,
  (SELECT json_group_array(json_object('number', number, 'merge_hours', merge_hours))
     FROM (SELECT number, merge_hours FROM temp.merged ORDER BY merge_hours DESC, number LIMIT 3)) AS slowest_merges,
  (SELECT count(*) FROM temp.op AS x WHERE x.kind = 'pr' AND NOT (o.exclude_bots AND x.is_bot)) AS open_prs,
  (SELECT count(*) FROM temp.op AS x WHERE x.kind = 'pr' AND x.is_draft AND NOT (o.exclude_bots AND x.is_bot)) AS open_draft_prs,
  (SELECT count(*) FROM temp.op AS x WHERE x.kind = 'issue') AS open_issues,
  (SELECT count(*) FROM temp.op AS x WHERE x.kind = 'pr' AND NOT (o.exclude_bots AND x.is_bot)
     AND x.updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', f.fetched_at, '-' || o.stale_pr_days || ' days')) AS stale_prs,
  (SELECT count(*) FROM temp.op AS x WHERE x.kind = 'issue'
     AND x.updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', f.fetched_at, '-' || o.stale_issue_days || ' days')) AS stale_issues,
  (SELECT count(*) FROM temp.ru AS u WHERE u.status = 'completed' AND u.created_at >= f.window_start) AS ci_runs,
  (SELECT count(*) FROM temp.ru AS u WHERE u.status = 'completed' AND u.created_at >= f.window_start
     AND u.conclusion = 'success') AS ci_passed,
  (SELECT count(*) FROM temp.ru AS u WHERE u.status = 'completed' AND u.created_at >= f.window_start
     AND u.conclusion IN ('failure', 'timed_out', 'startup_failure')) AS ci_failed,
  (SELECT count(*) FROM temp.wp) >= f.l_wp AS window_prs_cut,
  (SELECT count(*) FROM temp.wi) >= f.l_wi AS window_issues_cut,
  (SELECT count(*) FROM temp.op WHERE kind = 'pr') >= f.l_op AS open_prs_cut,
  (SELECT count(*) FROM temp.op WHERE kind = 'issue') >= f.l_oi AS open_issues_cut,
  -- The run read is the newest runs; it is cut only when even the oldest one read is inside the window.
  coalesce((SELECT count(*) >= f.l_runs AND min(created_at) >= f.window_start FROM temp.ru), 0) AS runs_cut
FROM temp.f AS f, temp.opt AS o;

BEGIN;

UPDATE repos SET default_branch = (SELECT default_branch FROM temp.f) WHERE repo = (SELECT repo FROM temp.r);

INSERT INTO snapshots (repo, run_id, fetched_at, window_start, stale_pr_days, stale_issue_days, exclude_bot_prs,
                       prs_opened, prs_merged, prs_closed_unmerged, issues_opened, issues_closed,
                       merged_reviewed, merged_without_review, review_hours_median, merge_hours_median, slowest_merges,
                       open_prs, open_draft_prs, open_issues, stale_prs, stale_issues,
                       ci_runs, ci_passed, ci_failed, ci_other, ci_pass_rate,
                       window_prs_cut, window_issues_cut, open_prs_cut, open_issues_cut, runs_cut, issues_enabled, ingested_at)
SELECT r.repo, o.run_id, f.fetched_at, f.window_start, o.stale_pr_days, o.stale_issue_days, o.exclude_bots,
       m.prs_opened, m.prs_merged, m.prs_closed_unmerged, m.issues_opened, m.issues_closed,
       m.merged_reviewed, m.merged_without_review, m.review_hours_median, m.merge_hours_median, m.slowest_merges,
       m.open_prs, m.open_draft_prs, m.open_issues, m.stale_prs, m.stale_issues,
       m.ci_runs, m.ci_passed, m.ci_failed, m.ci_runs - m.ci_passed - m.ci_failed,
       CASE WHEN m.ci_passed + m.ci_failed > 0 THEN round(100.0 * m.ci_passed / (m.ci_passed + m.ci_failed), 1) END,
       m.window_prs_cut, m.window_issues_cut, m.open_prs_cut, m.open_issues_cut, m.runs_cut,
       CASE WHEN f.issues_enabled THEN 1 ELSE 0 END, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.r AS r, temp.f AS f, temp.opt AS o, temp.m AS m WHERE true
ON CONFLICT (repo, week) DO UPDATE SET
  run_id = excluded.run_id, fetched_at = excluded.fetched_at, window_start = excluded.window_start,
  stale_pr_days = excluded.stale_pr_days, stale_issue_days = excluded.stale_issue_days, exclude_bot_prs = excluded.exclude_bot_prs,
  prs_opened = excluded.prs_opened, prs_merged = excluded.prs_merged, prs_closed_unmerged = excluded.prs_closed_unmerged,
  issues_opened = excluded.issues_opened, issues_closed = excluded.issues_closed,
  merged_reviewed = excluded.merged_reviewed, merged_without_review = excluded.merged_without_review,
  review_hours_median = excluded.review_hours_median, merge_hours_median = excluded.merge_hours_median,
  slowest_merges = excluded.slowest_merges, open_prs = excluded.open_prs, open_draft_prs = excluded.open_draft_prs,
  open_issues = excluded.open_issues, stale_prs = excluded.stale_prs, stale_issues = excluded.stale_issues,
  ci_runs = excluded.ci_runs, ci_passed = excluded.ci_passed, ci_failed = excluded.ci_failed, ci_other = excluded.ci_other,
  ci_pass_rate = excluded.ci_pass_rate, window_prs_cut = excluded.window_prs_cut, window_issues_cut = excluded.window_issues_cut,
  open_prs_cut = excluded.open_prs_cut, open_issues_cut = excluded.open_issues_cut, runs_cut = excluded.runs_cut,
  issues_enabled = excluded.issues_enabled, ingested_at = excluded.ingested_at;

COMMIT;

SELECT repo, week, prev_week, fetched_at, window_start, prs_opened, prs_merged, prs_closed_unmerged, issues_opened, issues_closed,
       merged_reviewed, merged_without_review, review_hours_median, merge_hours_median, json(slowest_merges) AS slowest_merges,
       open_prs, open_draft_prs, open_issues, stale_prs, stale_issues, ci_runs, ci_passed, ci_failed, ci_other, ci_pass_rate,
       window_prs_cut, window_issues_cut, open_prs_cut, open_issues_cut, runs_cut, issues_enabled
FROM snapshots WHERE repo = (SELECT repo FROM temp.r) AND fetched_at = (SELECT fetched_at FROM temp.f);
