-- Weekly repo health report database, schema version 1.
-- Create once at setup:
--   sqlite3 -bail "<db_path>" ".read references/schema.sql"
-- All times the agent did not read from GitHub come from the database clock (UTC).
-- GitHub data reaches this database only as JSON values read from files, never as SQL text.
-- There is no approvals table: this agent never writes to GitHub.
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE fresh_guard (n INTEGER CONSTRAINT database_not_empty CHECK (n = 0));
INSERT INTO temp.fresh_guard SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%';

BEGIN;

CREATE TABLE repos (
  repo TEXT PRIMARY KEY CHECK (
    length(repo) BETWEEN 3 AND 140
    AND repo GLOB '?*/?*'
    AND repo NOT GLOB '*/*/*'
    AND repo NOT GLOB '*[^A-Za-z0-9_./-]*'
    AND repo NOT GLOB '[.-]*' AND repo NOT GLOB '*/[.-]*'
  ),
  added_at TEXT NOT NULL,
  default_branch TEXT NOT NULL DEFAULT ''
);

CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  note TEXT NOT NULL DEFAULT ''
);

-- One row per repository per ISO week (UTC), from the latest fetch in that week.
-- A second ingest in the same week replaces the row. Every value is a count, an hour figure,
-- a percentage or a PR number: no text written on GitHub is stored.
CREATE TABLE snapshots (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL REFERENCES repos (repo),
  run_id INTEGER NOT NULL REFERENCES runs (id),
  fetched_at TEXT NOT NULL CHECK (fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  window_start TEXT NOT NULL CHECK (window_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND window_start < fetched_at),
  -- The Thursday of fetched_at's ISO week names the week: its year is the ISO year.
  week_thursday TEXT GENERATED ALWAYS AS (
    date(fetched_at, '-' || ((CAST(strftime('%w', fetched_at) AS INTEGER) + 6) % 7) || ' days', '+3 days')
  ) VIRTUAL,
  week TEXT GENERATED ALWAYS AS (
    strftime('%Y', week_thursday) || '-W' || printf('%02d', (CAST(strftime('%j', week_thursday) AS INTEGER) - 1) / 7 + 1)
  ) STORED,
  prev_week TEXT GENERATED ALWAYS AS (
    strftime('%Y', date(week_thursday, '-7 days')) || '-W'
    || printf('%02d', (CAST(strftime('%j', date(week_thursday, '-7 days')) AS INTEGER) - 1) / 7 + 1)
  ) STORED,
  -- The settings this snapshot was computed with, so a changed setting is visible next to a jump.
  stale_pr_days INTEGER NOT NULL DEFAULT 14 CHECK (stale_pr_days BETWEEN 1 AND 365),
  stale_issue_days INTEGER NOT NULL DEFAULT 30 CHECK (stale_issue_days BETWEEN 1 AND 365),
  exclude_bot_prs INTEGER NOT NULL DEFAULT 1 CHECK (exclude_bot_prs IN (0, 1)),
  -- In the window.
  prs_opened INTEGER NOT NULL DEFAULT 0,
  prs_merged INTEGER NOT NULL DEFAULT 0,
  prs_closed_unmerged INTEGER NOT NULL DEFAULT 0,
  issues_opened INTEGER NOT NULL DEFAULT 0,
  issues_closed INTEGER NOT NULL DEFAULT 0,
  -- Merged PRs in the window: hours from open to the first review by a person other than the author
-- (automated reviewers such as Copilot left out),
  -- and from open to merge. NULL when there is nothing to measure.
  merged_reviewed INTEGER NOT NULL DEFAULT 0,
  merged_without_review INTEGER NOT NULL DEFAULT 0,
  review_hours_median REAL,
  merge_hours_median REAL,
  -- Up to 3 merged PRs that took longest, as [{"number":n,"merge_hours":h}].
  slowest_merges TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(slowest_merges) AND json_array_length(slowest_merges) <= 3),
  -- Open now.
  open_prs INTEGER NOT NULL DEFAULT 0,
  open_draft_prs INTEGER NOT NULL DEFAULT 0,
  open_issues INTEGER NOT NULL DEFAULT 0,
  stale_prs INTEGER NOT NULL DEFAULT 0,
  stale_issues INTEGER NOT NULL DEFAULT 0,
  -- Completed workflow runs on the default branch created in the window. The pass rate is
  -- success / (success + failure), as a percentage; cancelled and skipped runs are counted apart.
  ci_runs INTEGER NOT NULL DEFAULT 0,
  ci_passed INTEGER NOT NULL DEFAULT 0,
  ci_failed INTEGER NOT NULL DEFAULT 0,
  ci_other INTEGER NOT NULL DEFAULT 0,
  ci_pass_rate REAL CHECK (ci_pass_rate IS NULL OR ci_pass_rate BETWEEN 0 AND 100),
  -- 1 when a read returned its full limit, so a number may be low.
  window_prs_cut INTEGER NOT NULL DEFAULT 0 CHECK (window_prs_cut IN (0, 1)),
  window_issues_cut INTEGER NOT NULL DEFAULT 0 CHECK (window_issues_cut IN (0, 1)),
  open_prs_cut INTEGER NOT NULL DEFAULT 0 CHECK (open_prs_cut IN (0, 1)),
  open_issues_cut INTEGER NOT NULL DEFAULT 0 CHECK (open_issues_cut IN (0, 1)),
  runs_cut INTEGER NOT NULL DEFAULT 0 CHECK (runs_cut IN (0, 1)),
  issues_enabled INTEGER NOT NULL DEFAULT 1 CHECK (issues_enabled IN (0, 1)),
  ingested_at TEXT NOT NULL,
  UNIQUE (repo, week)
);

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
