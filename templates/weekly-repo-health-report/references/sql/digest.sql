-- The report data for one run, as one JSON object: each repository's snapshot from this run, its numbers,
-- the change since the previous ISO week's snapshot, partial reads, and repositories with no snapshot.
-- Input: run_id. Read only. Write the report from this result and templates/report.md; never from memory.
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

CREATE TEMP TABLE run AS SELECT * FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input);
CREATE TEMP TABLE g_run (n INTEGER CONSTRAINT unknown_run CHECK (n = 1));
INSERT INTO temp.g_run SELECT count(*) FROM temp.run;

-- Each snapshot of this run with the previous ISO week's snapshot of the same repository, if any.
CREATE TEMP TABLE pair AS
SELECT s.id AS sid, p.id AS pid,
       EXISTS (SELECT 1 FROM snapshots AS e WHERE e.repo = s.repo AND e.week < s.week) AS has_earlier
FROM snapshots AS s LEFT JOIN snapshots AS p ON p.repo = s.repo AND p.week = s.prev_week
WHERE s.run_id = (SELECT id FROM temp.run);

SELECT json_object(
  'run', (SELECT json_object('run_id', id, 'kind', kind, 'started_at', started_at, 'ended_at', ended_at, 'note', note) FROM temp.run),
  'reports', (SELECT json_group_array(json_object(
      'repo', s.repo, 'week', s.week, 'window_start', s.window_start, 'window_end', s.fetched_at,
      'settings', json_object('stale_pr_days', s.stale_pr_days, 'stale_issue_days', s.stale_issue_days,
                              'exclude_bot_prs', json(CASE s.exclude_bot_prs WHEN 1 THEN 'true' ELSE 'false' END)),
      'numbers', json_object(
        'prs_opened', s.prs_opened, 'prs_merged', s.prs_merged, 'prs_closed_unmerged', s.prs_closed_unmerged,
        'issues_opened', s.issues_opened, 'issues_closed', s.issues_closed,
        'merged_reviewed', s.merged_reviewed, 'merged_without_review', s.merged_without_review,
        'review_hours_median', s.review_hours_median, 'merge_hours_median', s.merge_hours_median,
        'open_prs', s.open_prs, 'open_draft_prs', s.open_draft_prs, 'open_issues', s.open_issues,
        'stale_prs', s.stale_prs, 'stale_issues', s.stale_issues,
        'ci_runs', s.ci_runs, 'ci_passed', s.ci_passed, 'ci_failed', s.ci_failed, 'ci_other', s.ci_other,
        'ci_pass_rate', s.ci_pass_rate),
      'slowest_merges', json(s.slowest_merges),
      'partial', json_object('window_prs_cut', s.window_prs_cut, 'window_issues_cut', s.window_issues_cut,
                             'open_prs_cut', s.open_prs_cut, 'open_issues_cut', s.open_issues_cut, 'runs_cut', s.runs_cut,
                             'issues_enabled', s.issues_enabled),
      'baseline_week', p.week,
      'baseline_note', CASE WHEN p.id IS NOT NULL THEN NULL
                            WHEN x.has_earlier THEN 'no snapshot for ' || s.prev_week
                            ELSE 'no baseline yet' END,
      'settings_changed', CASE WHEN p.id IS NULL THEN NULL
                               ELSE json(CASE WHEN p.stale_pr_days <> s.stale_pr_days OR p.stale_issue_days <> s.stale_issue_days
                                                   OR p.exclude_bot_prs <> s.exclude_bot_prs THEN 'true' ELSE 'false' END) END,
      'deltas', CASE WHEN p.id IS NULL THEN NULL ELSE json_object(
        'prs_opened', s.prs_opened - p.prs_opened, 'prs_merged', s.prs_merged - p.prs_merged,
        'prs_closed_unmerged', s.prs_closed_unmerged - p.prs_closed_unmerged,
        'issues_opened', s.issues_opened - p.issues_opened, 'issues_closed', s.issues_closed - p.issues_closed,
        'merged_reviewed', s.merged_reviewed - p.merged_reviewed,
        'merged_without_review', s.merged_without_review - p.merged_without_review,
        'review_hours_median', round(s.review_hours_median - p.review_hours_median, 1),
        'merge_hours_median', round(s.merge_hours_median - p.merge_hours_median, 1),
        'open_prs', s.open_prs - p.open_prs, 'open_draft_prs', s.open_draft_prs - p.open_draft_prs,
        'open_issues', s.open_issues - p.open_issues,
        'stale_prs', s.stale_prs - p.stale_prs, 'stale_issues', s.stale_issues - p.stale_issues,
        'ci_runs', s.ci_runs - p.ci_runs, 'ci_passed', s.ci_passed - p.ci_passed, 'ci_failed', s.ci_failed - p.ci_failed,
        'ci_other', s.ci_other - p.ci_other,
        'ci_pass_rate', round(s.ci_pass_rate - p.ci_pass_rate, 1)) END))
    FROM (SELECT * FROM temp.pair ORDER BY sid) AS x
    JOIN snapshots AS s ON s.id = x.sid LEFT JOIN snapshots AS p ON p.id = x.pid),
  'missing', (SELECT json_group_array(repo) FROM (SELECT repo FROM repos
              WHERE repo NOT IN (SELECT repo FROM snapshots WHERE run_id = (SELECT id FROM temp.run)) ORDER BY repo))
);
