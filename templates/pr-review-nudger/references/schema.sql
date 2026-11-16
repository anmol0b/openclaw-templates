-- PR review nudger database, schema version 1.
-- Create once at setup:
--   sqlite3 -bail "<db_path>" ".read references/schema.sql"
-- Times the agent did not read from GitHub come from the database clock (UTC).
-- GitHub text reaches this database only as JSON values read from files, never as SQL text.
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE fresh_guard (n INTEGER CONSTRAINT database_not_empty CHECK (n = 0));
INSERT INTO temp.fresh_guard SELECT count(*) FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%';

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
  -- The owner's login from the latest fetch.
  login TEXT NOT NULL DEFAULT ''
);

-- Thresholds come from settings.md through run-start and are kept with the run.
CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  review_days INTEGER NOT NULL CHECK (review_days BETWEEN 1 AND 60),
  author_days INTEGER NOT NULL CHECK (author_days BETWEEN 1 AND 60),
  conflict_days INTEGER NOT NULL CHECK (conflict_days BETWEEN 1 AND 60),
  nudge_days INTEGER NOT NULL CHECK (nudge_days BETWEEN 1 AND 30),
  skip_bot_prs INTEGER NOT NULL CHECK (skip_bot_prs IN (0, 1)),
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
  prs INTEGER NOT NULL,
  prs_cut INTEGER NOT NULL CHECK (prs_cut IN (0, 1)),
  collaborators_readable INTEGER NOT NULL CHECK (collaborators_readable IN (0, 1)),
  collaborators_cut INTEGER NOT NULL CHECK (collaborators_cut IN (0, 1)),
  codeowners_path TEXT NOT NULL,
  candidates INTEGER NOT NULL,
  ingested_at TEXT NOT NULL
);

-- Open PRs. Titles are untrusted data. Bodies, comments and review text are never stored.
CREATE TABLE prs (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL REFERENCES repos (repo),
  number INTEGER NOT NULL CHECK (typeof(number) = 'integer' AND number > 0),
  title TEXT NOT NULL CHECK (length(title) <= 300),
  url TEXT NOT NULL,
  author TEXT NOT NULL CHECK (length(author) <= 60),
  author_is_bot INTEGER NOT NULL CHECK (author_is_bot IN (0, 1)),
  is_draft INTEGER NOT NULL CHECK (is_draft IN (0, 1)),
  review_decision TEXT NOT NULL CHECK (review_decision IN ('', 'REVIEW_REQUIRED', 'CHANGES_REQUESTED', 'APPROVED')),
  mergeable TEXT NOT NULL CHECK (mergeable IN ('', 'MERGEABLE', 'CONFLICTING', 'UNKNOWN')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  head_sha TEXT NOT NULL CHECK (length(head_sha) = 40 AND head_sha NOT GLOB '*[^0-9a-f]*'),
  last_commit_at TEXT,
  -- Logins with an open review request (JSON array) and the number of team requests.
  requested_users TEXT NOT NULL CHECK (json_valid(requested_users) AND json_type(requested_users) = 'array'),
  requested_teams INTEGER NOT NULL,
  -- Latest maintainer review (OWNER, MEMBER or COLLABORATOR) by someone other than the author.
  last_review_at TEXT,
  -- Latest CHANGES_REQUESTED review from a maintainer.
  changes_requested_at TEXT,
  comments INTEGER NOT NULL,
  owner_comments INTEGER NOT NULL,
  owner_last_comment_at TEXT,
  state TEXT NOT NULL CHECK (state IN ('OPEN', 'GONE')),
  first_seen TEXT NOT NULL,
  -- fetched_at of the latest fetch that included it.
  last_seen TEXT NOT NULL,
  UNIQUE (repo, number)
);

-- Reviewer candidates, only from fetched lists: collaborators with push access, CODEOWNERS
-- user entries, and maintainers who reviewed an open PR. Replaced on every ingest.
CREATE TABLE candidates (
  repo TEXT NOT NULL REFERENCES repos (repo),
  login TEXT NOT NULL CHECK (
    length(login) BETWEEN 1 AND 39
    AND login NOT GLOB '*[^A-Za-z0-9-]*'
    AND login NOT GLOB '-*' AND login NOT GLOB '*-'
  ),
  source TEXT NOT NULL CHECK (source IN ('collaborator', 'codeowner', 'reviewer')),
  PRIMARY KEY (repo, login, source)
);

-- Each open PR with its category and how long it has waited, by the database clock.
-- draft: skipped. merge-conflict: needs a rebase. waiting-on-author: a maintainer asked for changes
-- and no commit landed since. waiting-on-review: not approved, and no maintainer review since the
-- latest commit. ok: approved, or reviewed since the latest commit.
CREATE VIEW pr_status AS
SELECT x.*,
       CAST(julianday('now') - julianday(x.waiting_since) AS INTEGER) AS days_waiting
FROM (
  SELECT p.*,
         CASE
           WHEN p.is_draft = 1 THEN 'draft'
           WHEN p.mergeable = 'CONFLICTING' THEN 'merge-conflict'
           WHEN p.changes_requested_at IS NOT NULL AND p.review_decision = 'CHANGES_REQUESTED'
                AND coalesce(p.last_commit_at, '') <= p.changes_requested_at THEN 'waiting-on-author'
           WHEN p.review_decision = 'APPROVED' THEN 'ok'
           WHEN p.last_review_at IS NOT NULL AND p.last_review_at >= coalesce(p.last_commit_at, p.created_at) THEN 'ok'
           ELSE 'waiting-on-review'
         END AS category,
         CASE
           WHEN p.mergeable = 'CONFLICTING' THEN p.updated_at
           WHEN p.changes_requested_at IS NOT NULL AND p.review_decision = 'CHANGES_REQUESTED'
                AND coalesce(p.last_commit_at, '') <= p.changes_requested_at THEN p.changes_requested_at
           ELSE max(p.created_at, coalesce(p.last_commit_at, p.created_at))
         END AS waiting_since
  FROM prs AS p WHERE p.state = 'OPEN'
) AS x;

-- An owner approval for one write to GitHub. The command is built by ask-approval.sql,
-- never by the agent. It is bound to the PR as the owner saw it and used once.
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  pr_id INTEGER NOT NULL REFERENCES prs (id),
  action TEXT NOT NULL CHECK (action IN ('request-review', 'comment')),
  reviewer TEXT NOT NULL DEFAULT '',
  body_file TEXT NOT NULL DEFAULT '',
  body_sha3 TEXT NOT NULL DEFAULT '',
  exact_step TEXT NOT NULL CHECK (length(exact_step) BETWEEN 1 AND 2000),
  seen_head_sha TEXT NOT NULL,
  seen_updated_at TEXT NOT NULL,
  seen_owner_comments INTEGER NOT NULL,
  asked_at TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'granted', 'refused', 'withdrawn')),
  owner_words TEXT NOT NULL DEFAULT '',
  decided_at TEXT,
  used_at TEXT,
  outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'done', 'failed')),
  outcome_note TEXT NOT NULL DEFAULT '',
  outcome_at TEXT,
  CHECK (action <> 'comment' OR (body_file <> '' AND body_sha3 <> '')),
  CHECK ((action = 'request-review') = (reviewer <> '')),
  CHECK (decision NOT IN ('granted', 'refused') OR length(trim(owner_words)) > 0),
  CHECK (used_at IS NULL OR decision = 'granted'),
  CHECK (outcome = '' OR used_at IS NOT NULL)
);

CREATE UNIQUE INDEX approvals_one_pending ON approvals (pr_id, action) WHERE decision = 'pending';

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
CREATE TRIGGER approvals_request_fixed BEFORE UPDATE OF pr_id, action, reviewer, body_file, body_sha3, exact_step, seen_head_sha, seen_updated_at, seen_owner_comments, asked_at ON approvals
BEGIN
  SELECT RAISE(ABORT, 'a request cannot be changed; withdraw it and ask again');
END;

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
