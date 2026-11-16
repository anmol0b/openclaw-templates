-- Security alert triager database, schema version 1.
-- Create once at setup:
--   sqlite3 -bail "<db_path>" ".read references/schema.sql"
-- All times the agent did not read from GitHub come from the database clock (UTC).
-- GitHub text reaches this database only as JSON values read from files, never as SQL text.
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

CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  note TEXT NOT NULL DEFAULT ''
);

-- One row per ingested fetch. Each source is 'ok' (read; zero alerts means none open),
-- 'disabled' (the feature is off or never ran) or 'no_access' (this login cannot read it).
CREATE TABLE fetches (
  id INTEGER PRIMARY KEY,
  run_id INTEGER REFERENCES runs (id),
  repo TEXT NOT NULL REFERENCES repos (repo),
  fetched_at TEXT NOT NULL,
  dependabot_status TEXT NOT NULL CHECK (dependabot_status IN ('ok', 'disabled', 'no_access')),
  dependabot_message TEXT NOT NULL,
  dependabot_open INTEGER NOT NULL,
  dependabot_cut INTEGER NOT NULL CHECK (dependabot_cut IN (0, 1)),
  code_scanning_status TEXT NOT NULL CHECK (code_scanning_status IN ('ok', 'disabled', 'no_access')),
  code_scanning_message TEXT NOT NULL,
  code_scanning_open INTEGER NOT NULL,
  code_scanning_cut INTEGER NOT NULL CHECK (code_scanning_cut IN (0, 1)),
  prs INTEGER NOT NULL,
  ingested_at TEXT NOT NULL
);

-- Dependabot and code scanning alerts. Fields that do not apply to a source stay ''.
CREATE TABLE alerts (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL REFERENCES repos (repo),
  source TEXT NOT NULL CHECK (source IN ('dependabot', 'code-scanning')),
  number INTEGER NOT NULL CHECK (typeof(number) = 'integer' AND number > 0),
  -- open or dismissed as GitHub reported it; closed when a complete read of open alerts
  -- no longer has it and it is not in the dismissed read (fixed, or dismissed long ago).
  state TEXT NOT NULL CHECK (state IN ('open', 'dismissed', 'closed')),
  severity TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low', 'unrated')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  html_url TEXT NOT NULL DEFAULT '',
  -- Dependabot
  ecosystem TEXT NOT NULL DEFAULT '',
  package TEXT NOT NULL DEFAULT '',
  manifest_path TEXT NOT NULL DEFAULT '',
  scope TEXT NOT NULL DEFAULT '',
  ghsa_id TEXT NOT NULL DEFAULT '',
  cve_id TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  vulnerable_range TEXT NOT NULL DEFAULT '',
  patched_version TEXT NOT NULL DEFAULT '',
  covering_pr INTEGER,
  covering_fixes TEXT NOT NULL DEFAULT '' CHECK (covering_fixes IN ('', 'yes', 'unknown', 'no')),
  -- Code scanning
  rule_id TEXT NOT NULL DEFAULT '',
  rule_severity TEXT NOT NULL DEFAULT '',
  rule_description TEXT NOT NULL DEFAULT '',
  tool TEXT NOT NULL DEFAULT '',
  path TEXT NOT NULL DEFAULT '',
  start_line INTEGER,
  dismissed_reason TEXT NOT NULL DEFAULT '',
  first_seen TEXT NOT NULL,
  -- fetched_at of the latest fetch that included it.
  last_seen TEXT NOT NULL,
  UNIQUE (repo, source, number)
);

-- Open alerts with a sortable severity rank (1 = critical) and a group key:
-- ecosystem/package for Dependabot, the rule for code scanning.
CREATE VIEW open_alerts AS
SELECT a.*,
       CASE a.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END AS severity_rank,
       CASE a.source WHEN 'dependabot' THEN a.ecosystem || '/' || a.package ELSE a.rule_id END AS group_key,
       CAST(julianday('now') - julianday(a.created_at) AS INTEGER) AS days_open
FROM alerts AS a
WHERE a.state = 'open';

-- An owner approval for one write to GitHub. The command is built by ask-approval.sql,
-- never by the agent. It is bound to the alert as the owner saw it and used once.
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  alert_id INTEGER NOT NULL REFERENCES alerts (id),
  action TEXT NOT NULL CHECK (action IN ('dismiss', 'issue')),
  reason TEXT NOT NULL DEFAULT '',
  body_file TEXT NOT NULL DEFAULT '',
  body_sha3 TEXT NOT NULL DEFAULT '',
  exact_step TEXT NOT NULL CHECK (length(exact_step) BETWEEN 1 AND 2000),
  seen_updated_at TEXT NOT NULL,
  asked_at TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'granted', 'refused', 'withdrawn')),
  owner_words TEXT NOT NULL DEFAULT '',
  decided_at TEXT,
  used_at TEXT,
  outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'done', 'failed')),
  outcome_note TEXT NOT NULL DEFAULT '',
  issue_url TEXT NOT NULL DEFAULT '',
  outcome_at TEXT,
  CHECK (action <> 'dismiss' OR reason <> ''),
  CHECK (action <> 'issue' OR (reason = '' AND body_file = '')),
  CHECK ((body_file = '') = (body_sha3 = '')),
  CHECK (decision NOT IN ('granted', 'refused') OR length(trim(owner_words)) > 0),
  CHECK (used_at IS NULL OR decision = 'granted'),
  CHECK (outcome = '' OR used_at IS NOT NULL)
);

CREATE UNIQUE INDEX approvals_one_pending ON approvals (alert_id, action) WHERE decision = 'pending';
-- One tracking issue per alert.
CREATE UNIQUE INDEX approvals_one_issue ON approvals (alert_id) WHERE action = 'issue' AND outcome = 'done';

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
CREATE TRIGGER approvals_request_fixed BEFORE UPDATE OF alert_id, action, reason, body_file, body_sha3, exact_step, seen_updated_at, asked_at ON approvals
BEGIN
  SELECT RAISE(ABORT, 'a request cannot be changed; withdraw it and ask again');
END;

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
