-- First-timer welcomer database, schema version 1.
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
  -- The labels the owner lets this agent suggest, from settings.md: 1 to 5 plain names.
  allowed_labels TEXT NOT NULL CHECK (
    json_valid(allowed_labels) AND json_type(allowed_labels) = 'array'
    AND json_array_length(allowed_labels) BETWEEN 1 AND 5),
  -- From the latest fetch.
  login TEXT NOT NULL DEFAULT '',
  labels TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(labels) AND json_type(labels) = 'array')
);

CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  recent_days INTEGER NOT NULL CHECK (recent_days BETWEEN 1 AND 90),
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
  prs_total INTEGER NOT NULL,
  issues INTEGER NOT NULL,
  issues_total INTEGER NOT NULL,
  labels INTEGER NOT NULL,
  labels_total INTEGER NOT NULL,
  issues_enabled INTEGER NOT NULL CHECK (issues_enabled IN (0, 1)),
  -- 1 when a read returned fewer items than GitHub has, so older items were not read.
  prs_cut INTEGER NOT NULL CHECK (prs_cut IN (0, 1)),
  issues_cut INTEGER NOT NULL CHECK (issues_cut IN (0, 1)),
  labels_cut INTEGER NOT NULL CHECK (labels_cut IN (0, 1)),
  ingested_at TEXT NOT NULL
);

-- Open PRs and issues. PRs and issues share one number space in a repository.
CREATE TABLE items (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL REFERENCES repos (repo),
  kind TEXT NOT NULL CHECK (kind IN ('pr', 'issue')),
  number INTEGER NOT NULL CHECK (typeof(number) = 'integer' AND number > 0),
  title TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  -- '' for a deleted account.
  author TEXT NOT NULL CHECK (author = '' OR (length(author) BETWEEN 1 AND 39 AND author NOT GLOB '*[^A-Za-z0-9_-]*')),
  author_type TEXT NOT NULL,
  association TEXT NOT NULL,
  created_at TEXT NOT NULL CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  is_draft INTEGER NOT NULL DEFAULT 0 CHECK (is_draft IN (0, 1)),
  labels TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(labels) AND json_type(labels) = 'array'),
  assignees INTEGER NOT NULL DEFAULT 0,
  linked_prs INTEGER NOT NULL DEFAULT 0,
  body_chars INTEGER NOT NULL DEFAULT 0,
  comments INTEGER NOT NULL DEFAULT 0,
  -- createdAt of the owner's latest comment among the last 30, '' if none.
  owner_last_comment_at TEXT NOT NULL DEFAULT '',
  -- 'gone' when a complete read no longer has it (closed or merged).
  state TEXT NOT NULL CHECK (state IN ('open', 'gone')),
  first_seen TEXT NOT NULL,
  -- fetched_at of the latest fetch that included it.
  last_seen TEXT NOT NULL,
  UNIQUE (repo, number)
);

-- People this agent welcomed, once per repository. Filled by approval-outcome when a welcome is done.
CREATE TABLE welcomed (
  repo TEXT NOT NULL REFERENCES repos (repo),
  login TEXT NOT NULL CHECK (length(login) BETWEEN 1 AND 39),
  item_id INTEGER NOT NULL REFERENCES items (id),
  approval_id INTEGER NOT NULL,
  welcomed_at TEXT NOT NULL,
  PRIMARY KEY (repo, login)
);

-- Open items in the latest fetch of their repository. An item a cut read did not reach is left out,
-- so nothing is listed from an old read.
CREATE VIEW current_items AS
SELECT i.* FROM items AS i
WHERE i.state = 'open' AND i.last_seen = (SELECT max(f.fetched_at) FROM fetches AS f WHERE f.repo = i.repo);

-- PRs and issues by people new to the repository: GitHub's FIRST_TIME_CONTRIBUTOR, FIRST_TIMER or NONE,
-- a person (not a bot), and not the owner. `waiting` means not welcomed here yet and the owner has not commented on it.
CREATE VIEW newcomers AS
SELECT i.*,
       CAST(julianday('now') - julianday(i.created_at) AS INTEGER) AS days_open,
       EXISTS (SELECT 1 FROM welcomed AS w WHERE w.repo = i.repo AND lower(w.login) = lower(i.author)) AS already_welcomed,
       i.owner_last_comment_at <> '' AS owner_commented,
       NOT EXISTS (SELECT 1 FROM welcomed AS w WHERE w.repo = i.repo AND lower(w.login) = lower(i.author))
         AND i.owner_last_comment_at = '' AS waiting
FROM current_items AS i JOIN repos AS r ON r.repo = i.repo
WHERE i.association IN ('FIRST_TIME_CONTRIBUTOR', 'FIRST_TIMER', 'NONE')
  AND i.author_type = 'User' AND i.author <> '' AND lower(i.author) <> lower(r.login);

-- Issues that could take a newcomer label: unassigned, no open PR that would close them, a description
-- of at least 80 characters, and none of the repository's allowed labels yet. Whether one is small is the
-- owner's call; the agent suggests from the title only.
CREATE VIEW label_candidates AS
SELECT i.* FROM current_items AS i JOIN repos AS r ON r.repo = i.repo
WHERE i.kind = 'issue' AND i.assignees = 0 AND i.linked_prs = 0 AND i.body_chars >= 80
  AND NOT EXISTS (SELECT 1 FROM json_each(i.labels) AS l, json_each(r.allowed_labels) AS a WHERE l.value = a.value);

-- An owner approval for one write to GitHub. The command is built by ask-approval.sql,
-- never by the agent. It is bound to the item as the owner saw it and used once.
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  item_id INTEGER NOT NULL REFERENCES items (id),
  action TEXT NOT NULL CHECK (action IN ('welcome', 'add-label')),
  label TEXT NOT NULL DEFAULT '',
  -- The author the welcome is for, so one person gets one welcome per repository.
  author TEXT NOT NULL DEFAULT '',
  body_file TEXT NOT NULL DEFAULT '',
  body_sha3 TEXT NOT NULL DEFAULT '',
  exact_step TEXT NOT NULL CHECK (length(exact_step) BETWEEN 1 AND 2000),
  seen_updated_at TEXT NOT NULL,
  seen_owner_comment_at TEXT NOT NULL,
  asked_at TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'granted', 'refused', 'withdrawn')),
  owner_words TEXT NOT NULL DEFAULT '',
  decided_at TEXT,
  used_at TEXT,
  outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'done', 'failed')),
  outcome_note TEXT NOT NULL DEFAULT '',
  outcome_at TEXT,
  CHECK (action <> 'welcome' OR (body_file <> '' AND body_sha3 <> '' AND author <> '' AND label = '')),
  CHECK (action <> 'add-label' OR (label <> '' AND body_file = '')),
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
CREATE TRIGGER approvals_request_fixed BEFORE UPDATE OF item_id, action, label, author, body_file, body_sha3, exact_step, seen_updated_at, seen_owner_comment_at, asked_at ON approvals
BEGIN
  SELECT RAISE(ABORT, 'a request cannot be changed; withdraw it and ask again');
END;

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
