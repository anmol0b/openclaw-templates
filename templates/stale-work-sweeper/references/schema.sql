-- Stale work sweeper database, schema version 1.
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
  added_at TEXT NOT NULL,
  -- From the latest fetch.
  login TEXT NOT NULL DEFAULT '',
  default_branch TEXT NOT NULL DEFAULT ''
);

CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  stale_days INTEGER NOT NULL CHECK (stale_days BETWEEN 1 AND 365),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  note TEXT NOT NULL DEFAULT ''
);

-- One row per ingested fetch, so the digest can name partial reads.
CREATE TABLE fetches (
  id INTEGER PRIMARY KEY,
  run_id INTEGER REFERENCES runs (id),
  repo TEXT NOT NULL REFERENCES repos (repo),
  login TEXT NOT NULL,
  fetched_at TEXT NOT NULL,
  branches INTEGER NOT NULL,
  branches_total INTEGER NOT NULL,
  prs INTEGER NOT NULL,
  issues INTEGER NOT NULL,
  issues_enabled INTEGER NOT NULL CHECK (issues_enabled IN (0, 1)),
  -- 1 when a read returned its full limit, so older items may be missing.
  branches_cut INTEGER NOT NULL CHECK (branches_cut IN (0, 1)),
  prs_cut INTEGER NOT NULL CHECK (prs_cut IN (0, 1)),
  issues_cut INTEGER NOT NULL CHECK (issues_cut IN (0, 1)),
  ingested_at TEXT NOT NULL
);

-- Branches, PRs and issues. `ref` is the branch name, or the PR or issue number as text.
CREATE TABLE items (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL REFERENCES repos (repo),
  kind TEXT NOT NULL CHECK (kind IN ('branch', 'pr', 'issue')),
  ref TEXT NOT NULL CHECK (length(ref) BETWEEN 1 AND 255),
  number INTEGER CHECK (number IS NULL OR (typeof(number) = 'integer' AND number > 0)),
  title TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  -- 1 when the item is the owner's: their branch (last commit), their PR, or an issue assigned to them.
  is_owners INTEGER NOT NULL CHECK (is_owners IN (0, 1)),
  -- Last commit time for a branch, updatedAt for a PR or issue.
  last_activity TEXT NOT NULL CHECK (last_activity GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  head_oid TEXT NOT NULL DEFAULT '',
  is_draft INTEGER NOT NULL DEFAULT 0 CHECK (is_draft IN (0, 1)),
  ci_state TEXT NOT NULL DEFAULT 'none' CHECK (ci_state IN ('none', 'passing', 'failing', 'pending')),
  mergeable TEXT NOT NULL DEFAULT '',
  -- Branches: every commit is in the default branch (compare behindBy = 0),
  -- or a merged PR had this exact head (squash and rebase merges).
  merged_into_default INTEGER NOT NULL DEFAULT 0 CHECK (merged_into_default IN (0, 1)),
  merged_pr INTEGER,
  open_pr INTEGER,
  is_protected INTEGER NOT NULL DEFAULT 0 CHECK (is_protected IN (0, 1)),
  is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
  -- 'gone' when a complete read no longer has it (deleted, closed, merged or unassigned).
  state TEXT NOT NULL CHECK (state IN ('open', 'gone')),
  first_seen TEXT NOT NULL,
  -- fetched_at of the latest fetch that included it.
  last_seen TEXT NOT NULL,
  UNIQUE (repo, kind, ref),
  CHECK ((kind = 'branch') = (number IS NULL))
);

-- The owner's open work with its category and rank. Steps filter it by the run's stale_days.
-- Rank 1 is safe to clean up: a branch fully merged into the default branch (or whose exact head was merged
-- through a PR), with no open PR, not protected and not the default branch. A branch with an open PR is left
-- to that PR. An unmerged branch is never suggested for deletion.
CREATE VIEW owners_work AS
SELECT i.*,
       CAST(julianday('now') - julianday(i.last_activity) AS INTEGER) AS days_idle,
       CASE
         WHEN i.kind = 'branch' AND (i.merged_into_default = 1 OR i.merged_pr IS NOT NULL)
              AND i.open_pr IS NULL AND i.is_protected = 0 AND i.is_default = 0 THEN 'merged-branch'
         WHEN i.kind = 'pr' THEN 'idle-pr'
         WHEN i.kind = 'issue' THEN 'idle-issue'
         ELSE 'unmerged-branch'
       END AS category,
       CASE
         WHEN i.kind = 'branch' AND (i.merged_into_default = 1 OR i.merged_pr IS NOT NULL)
              AND i.open_pr IS NULL AND i.is_protected = 0 AND i.is_default = 0 THEN 1
         WHEN i.kind = 'pr' THEN 2
         WHEN i.kind = 'issue' THEN 3
         ELSE 4
       END AS rank
FROM items AS i
WHERE i.state = 'open' AND i.is_owners = 1 AND i.is_default = 0
  AND NOT (i.kind = 'branch' AND i.open_pr IS NOT NULL);

-- An owner approval for one write to GitHub. The command is built by ask-approval.sql,
-- never by the agent. It is bound to the item as the owner saw it and used once.
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  item_id INTEGER NOT NULL REFERENCES items (id),
  action TEXT NOT NULL CHECK (action IN ('delete-branch', 'comment', 'close', 'unassign')),
  close_reason TEXT NOT NULL DEFAULT '' CHECK (close_reason IN ('', 'completed', 'not planned')),
  body_file TEXT NOT NULL DEFAULT '',
  body_sha3 TEXT NOT NULL DEFAULT '',
  exact_step TEXT NOT NULL CHECK (length(exact_step) BETWEEN 1 AND 2000),
  seen_head_oid TEXT NOT NULL,
  seen_last_activity TEXT NOT NULL,
  asked_at TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'granted', 'refused', 'withdrawn')),
  owner_words TEXT NOT NULL DEFAULT '',
  decided_at TEXT,
  used_at TEXT,
  outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'done', 'failed')),
  outcome_note TEXT NOT NULL DEFAULT '',
  outcome_at TEXT,
  CHECK (action <> 'comment' OR (body_file <> '' AND body_sha3 <> '')),
  CHECK (action <> 'delete-branch' OR seen_head_oid <> ''),
  CHECK (decision NOT IN ('granted', 'refused') OR length(trim(owner_words)) > 0),
  CHECK (used_at IS NULL OR decision = 'granted'),
  CHECK (outcome = '' OR used_at IS NOT NULL)
);

CREATE UNIQUE INDEX approvals_one_pending ON approvals (item_id, action) WHERE decision = 'pending';

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
CREATE TRIGGER approvals_request_fixed BEFORE UPDATE OF item_id, action, close_reason, body_file, body_sha3, exact_step, seen_head_oid, seen_last_activity, asked_at ON approvals
BEGIN
  SELECT RAISE(ABORT, 'a request cannot be changed; withdraw it and ask again');
END;

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
