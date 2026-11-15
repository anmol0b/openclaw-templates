-- CI failure triager database, schema version 1.
-- Create once at setup:
--   sqlite3 -bail "<db_path>" ".read references/schema.sql"
-- Times the agent did not read from GitHub come from the database clock (UTC).
-- Run, job and log text reaches this database only as JSON values read from files, never as SQL text.
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
  added_at TEXT NOT NULL
);

-- One row per fetch that was ingested, so the digest can name gaps and errors.
CREATE TABLE reads (
  id INTEGER PRIMARY KEY,
  cycle_id INTEGER REFERENCES cycles (id),
  repo TEXT NOT NULL REFERENCES repos (repo),
  fetched_at TEXT NOT NULL,
  run_count INTEGER NOT NULL,
  failed_runs INTEGER NOT NULL,
  new_failed INTEGER NOT NULL,
  logs_left INTEGER NOT NULL,
  -- 1 when the newest-100 list did not reach back to the previous fetch, so runs in between may be missed.
  gap INTEGER NOT NULL CHECK (gap IN (0, 1)),
  errors TEXT NOT NULL DEFAULT '[]',
  ingested_at TEXT NOT NULL
);

-- One triage pass (scheduled or manual).
CREATE TABLE cycles (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  note TEXT NOT NULL DEFAULT ''
);

-- One row per run attempt seen. `gh run list` shows only a run's latest attempt; earlier
-- attempts stay here from earlier fetches, which is how a passing rerun is recognized.
CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL REFERENCES repos (repo),
  gh_run_id INTEGER NOT NULL CHECK (typeof(gh_run_id) = 'integer' AND gh_run_id > 0),
  attempt INTEGER NOT NULL CHECK (typeof(attempt) = 'integer' AND attempt > 0),
  workflow TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  event TEXT NOT NULL DEFAULT '',
  branch TEXT NOT NULL DEFAULT '',
  head_sha TEXT NOT NULL CHECK (head_sha GLOB '[0-9a-f]*' AND length(head_sha) BETWEEN 7 AND 64),
  status TEXT NOT NULL,
  conclusion TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  url TEXT NOT NULL DEFAULT '',
  first_seen TEXT NOT NULL,
  -- fetched_at of the latest fetch whose list showed this attempt.
  last_seen TEXT NOT NULL,
  UNIQUE (repo, gh_run_id, attempt)
);
CREATE INDEX runs_branch ON runs (repo, workflow, branch, created_at);
CREATE INDEX runs_sha ON runs (repo, workflow, head_sha);

-- One row per failed job of a failed run attempt, as fetch.mjs summarized it.
CREATE TABLE failures (
  id INTEGER PRIMARY KEY,
  run_row INTEGER NOT NULL REFERENCES runs (id),
  job_id INTEGER NOT NULL CHECK (typeof(job_id) = 'integer' AND job_id > 0),
  job_name TEXT NOT NULL,
  job_url TEXT NOT NULL DEFAULT '',
  failed_steps TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(failed_steps) AND json_type(failed_steps) = 'array' AND json_array_length(failed_steps) <= 10),
  -- At most 5 error lines of 200 characters and a 3000-character excerpt around the first error,
  -- as fetch.mjs cut and masked them. ingest.sql cuts again, so these limits hold whatever the file says.
  error_lines TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(error_lines) AND json_type(error_lines) = 'array' AND json_array_length(error_lines) <= 5),
  excerpt TEXT NOT NULL DEFAULT '' CHECK (length(excerpt) <= 3000),
  log_found INTEGER NOT NULL CHECK (log_found IN (0, 1)),
  log_error TEXT NOT NULL DEFAULT '',
  signature TEXT NOT NULL CHECK (length(signature) = 16 AND signature NOT GLOB '*[^0-9a-f]*'),
  UNIQUE (run_row, job_id)
);
CREATE INDEX failures_signature ON failures (signature);

-- Open pull requests from the latest fetch, replaced as a whole on every ingest. Only what
-- matches a failing commit to its PR: no titles or bodies.
CREATE TABLE prs (
  repo TEXT NOT NULL REFERENCES repos (repo),
  number INTEGER NOT NULL CHECK (typeof(number) = 'integer' AND number > 0),
  head_sha TEXT NOT NULL,
  url TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (repo, number)
);

-- The agent's verdict on one failed run attempt. The attempt leaves the queue once triaged.
CREATE TABLE triage (
  id INTEGER PRIMARY KEY,
  run_row INTEGER NOT NULL UNIQUE REFERENCES runs (id),
  cycle_id INTEGER REFERENCES cycles (id),
  verdict TEXT NOT NULL CHECK (verdict IN ('flaky', 'new-break', 'still-broken', 'infra', 'unclear')),
  first_bad_sha TEXT CHECK (first_bad_sha IS NULL OR (first_bad_sha GLOB '[0-9a-f]*' AND length(first_bad_sha) BETWEEN 7 AND 64)),
  reason TEXT NOT NULL CHECK (length(trim(reason)) BETWEEN 1 AND 1000),
  suggested_action TEXT NOT NULL DEFAULT 'none' CHECK (suggested_action IN ('none', 'rerun', 'issue', 'pr-comment')),
  created_at TEXT NOT NULL
);

-- An owner approval for one write to GitHub. The command is built by ask-approval.sql,
-- never by the agent. It is bound to the run attempt as the owner saw it and used once.
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  run_row INTEGER NOT NULL REFERENCES runs (id),
  action TEXT NOT NULL CHECK (action IN ('rerun', 'issue', 'pr-comment')),
  failure_id INTEGER REFERENCES failures (id),
  signature TEXT NOT NULL DEFAULT '',
  pr_number INTEGER,
  title TEXT NOT NULL DEFAULT '',
  body_file TEXT NOT NULL DEFAULT '',
  body_sha3 TEXT NOT NULL DEFAULT '',
  exact_step TEXT NOT NULL CHECK (length(exact_step) BETWEEN 1 AND 2000),
  seen_attempt INTEGER NOT NULL,
  seen_updated_at TEXT NOT NULL,
  asked_at TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'granted', 'refused', 'withdrawn')),
  owner_words TEXT NOT NULL DEFAULT '',
  decided_at TEXT,
  used_at TEXT,
  outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'done', 'failed')),
  outcome_note TEXT NOT NULL DEFAULT '',
  outcome_at TEXT,
  CHECK (action = 'rerun' OR (body_file <> '' AND body_sha3 <> '')),
  CHECK (action <> 'issue' OR (failure_id IS NOT NULL AND signature <> '' AND title <> '')),
  CHECK (action <> 'pr-comment' OR pr_number IS NOT NULL),
  CHECK (decision NOT IN ('granted', 'refused') OR length(trim(owner_words)) > 0),
  CHECK (used_at IS NULL OR decision = 'granted'),
  CHECK (outcome = '' OR used_at IS NOT NULL)
);

-- At most one open request per run attempt and action.
CREATE UNIQUE INDEX approvals_one_pending ON approvals (run_row, action) WHERE decision = 'pending';

CREATE TRIGGER approvals_decided_once BEFORE UPDATE OF decision ON approvals
WHEN OLD.decision <> 'pending'
BEGIN
  SELECT RAISE(ABORT, 'this request was already decided');
END;
CREATE TRIGGER approvals_used_once BEFORE UPDATE OF used_at ON approvals
WHEN OLD.used_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'this approval was already used');
END;
CREATE TRIGGER approvals_outcome_once BEFORE UPDATE OF outcome ON approvals
WHEN OLD.outcome <> ''
BEGIN
  SELECT RAISE(ABORT, 'this outcome was already recorded');
END;
CREATE TRIGGER approvals_request_fixed BEFORE UPDATE OF run_row, action, failure_id, signature, pr_number, title, body_file, body_sha3, exact_step, seen_attempt, seen_updated_at, asked_at ON approvals
BEGIN
  SELECT RAISE(ABORT, 'a request cannot be changed; withdraw it and ask again');
END;

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
