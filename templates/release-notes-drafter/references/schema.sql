-- Release notes drafter database, schema version 1.
-- Create once at setup:
--   sqlite3 -bail "<db_path>" ".read references/schema.sql"
-- Times the agent did not read from GitHub come from the database clock (UTC).
-- Pull request text reaches this database only as JSON values read from files, never as SQL text.
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE fresh_guard (n INTEGER CONSTRAINT database_not_empty CHECK (n = 0));
INSERT INTO temp.fresh_guard SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%';

BEGIN;

-- One row per repository the owner listed, with the state of its latest ingested fetch.
CREATE TABLE repos (
  repo TEXT PRIMARY KEY CHECK (
    length(repo) BETWEEN 3 AND 140
    AND repo GLOB '?*/?*'
    AND repo NOT GLOB '*/*/*'
    AND repo NOT GLOB '*[^A-Za-z0-9_./-]*'
    AND repo NOT GLOB '[.-]*' AND repo NOT GLOB '*/[.-]*'
  ),
  added_at TEXT NOT NULL,
  default_branch TEXT NOT NULL DEFAULT '' CHECK (
    default_branch = ''
    OR (length(default_branch) <= 200 AND default_branch NOT GLOB '*[^A-Za-z0-9_./-]*' AND default_branch NOT GLOB '[-./]*')
  ),
  -- The base release (empty when the repository has none yet) and the merge cutoff.
  base_tag TEXT NOT NULL DEFAULT '',
  since TEXT NOT NULL DEFAULT '',
  -- The newest merged pull request in the window, and how many there are.
  newest_merged_at TEXT NOT NULL DEFAULT '',
  pr_count INTEGER NOT NULL DEFAULT 0,
  -- Fetch time of the latest ingested read. Empty before the first one.
  fetched_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  note TEXT NOT NULL DEFAULT ''
);

-- One row per ingested fetch, so the digest can name gaps.
CREATE TABLE reads (
  id INTEGER PRIMARY KEY,
  run_id INTEGER REFERENCES runs (id),
  repo TEXT NOT NULL REFERENCES repos (repo),
  fetched_at TEXT NOT NULL,
  base_tag TEXT NOT NULL,
  since TEXT NOT NULL,
  pr_count INTEGER NOT NULL,
  -- 1 when the pull request read hit its limit, so the oldest merges may be missing.
  limit_reached INTEGER NOT NULL CHECK (limit_reached IN (0, 1)),
  ingested_at TEXT NOT NULL
);

-- The repository's releases from the latest fetch, drafts included. Replaced on each ingest.
CREATE TABLE releases (
  repo TEXT NOT NULL REFERENCES repos (repo),
  tag TEXT NOT NULL CHECK (length(tag) BETWEEN 1 AND 200),
  name TEXT NOT NULL DEFAULT '',
  is_draft INTEGER NOT NULL CHECK (is_draft IN (0, 1)),
  is_prerelease INTEGER NOT NULL CHECK (is_prerelease IN (0, 1)),
  is_latest INTEGER NOT NULL CHECK (is_latest IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT '',
  published_at TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (repo, tag)
);

-- Pull requests merged into the default branch after the base release. Replaced on each ingest.
CREATE TABLE prs (
  repo TEXT NOT NULL REFERENCES repos (repo),
  number INTEGER NOT NULL CHECK (typeof(number) = 'integer' AND number > 0),
  title TEXT NOT NULL,
  author TEXT NOT NULL DEFAULT '',
  author_is_bot INTEGER NOT NULL DEFAULT 0 CHECK (author_is_bot IN (0, 1)),
  labels TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(labels) AND json_type(labels) = 'array'),
  body TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  merged_at TEXT NOT NULL CHECK (merged_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  PRIMARY KEY (repo, number)
);

-- A drafted release: the window as it was, the sections, and the computed next tag.
CREATE TABLE drafts (
  id INTEGER PRIMARY KEY,
  run_id INTEGER REFERENCES runs (id),
  repo TEXT NOT NULL REFERENCES repos (repo),
  base_tag TEXT NOT NULL,
  newest_merged_at TEXT NOT NULL,
  -- Entries in the draft, and the size of the whole window (bots included) when it was drafted.
  pr_count INTEGER NOT NULL CHECK (pr_count > 0),
  window_count INTEGER NOT NULL,
  next_tag TEXT NOT NULL CHECK (
    length(next_tag) BETWEEN 5 AND 40 AND next_tag NOT GLOB '*[^v0-9.]*' AND next_tag NOT GLOB '?*v*'
  ),
  bump TEXT NOT NULL CHECK (bump IN ('major', 'minor', 'patch', 'first', 'owner')),
  owner_words TEXT NOT NULL DEFAULT '',
  notes_file TEXT NOT NULL,
  changelog_file TEXT NOT NULL,
  created_at TEXT NOT NULL,
  CHECK (bump <> 'owner' OR length(trim(owner_words)) > 0)
);

CREATE TABLE draft_entries (
  draft_id INTEGER NOT NULL REFERENCES drafts (id),
  number INTEGER NOT NULL,
  section TEXT NOT NULL CHECK (section IN ('breaking', 'features', 'fixes', 'docs', 'internal', 'other')),
  title TEXT NOT NULL,
  author TEXT NOT NULL,
  author_is_bot INTEGER NOT NULL,
  url TEXT NOT NULL,
  PRIMARY KEY (draft_id, number)
);

-- An owner approval for one draft release on GitHub. The command is built by ask-approval.sql,
-- never by the agent. It is bound to the repository as the owner saw it and to the exact bytes
-- of the notes file, and is used once.
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  draft_id INTEGER NOT NULL REFERENCES drafts (id),
  action TEXT NOT NULL CHECK (action = 'create-draft-release'),
  title TEXT NOT NULL,
  notes_file TEXT NOT NULL,
  notes_sha3 TEXT NOT NULL CHECK (length(notes_sha3) = 64),
  exact_step TEXT NOT NULL CHECK (length(exact_step) BETWEEN 1 AND 2000),
  seen_base_tag TEXT NOT NULL,
  seen_newest_merged_at TEXT NOT NULL,
  seen_pr_count INTEGER NOT NULL,
  asked_at TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'granted', 'refused', 'withdrawn')),
  owner_words TEXT NOT NULL DEFAULT '',
  decided_at TEXT,
  used_at TEXT,
  outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'done', 'failed')),
  outcome_note TEXT NOT NULL DEFAULT '',
  outcome_at TEXT,
  CHECK (decision NOT IN ('granted', 'refused') OR length(trim(owner_words)) > 0),
  CHECK (used_at IS NULL OR decision = 'granted'),
  CHECK (outcome = '' OR used_at IS NOT NULL)
);

-- At most one open request per draft.
CREATE UNIQUE INDEX approvals_one_pending ON approvals (draft_id) WHERE decision = 'pending';

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
CREATE TRIGGER approvals_request_fixed BEFORE UPDATE OF draft_id, action, title, notes_file, notes_sha3, exact_step, seen_base_tag, seen_newest_merged_at, seen_pr_count, asked_at ON approvals
BEGIN
  SELECT RAISE(ABORT, 'a request cannot be changed; withdraw it and ask again');
END;
-- A draft and its entries never change after they are saved.
CREATE TRIGGER drafts_fixed BEFORE UPDATE ON drafts
BEGIN
  SELECT RAISE(ABORT, 'a draft cannot be changed; save a new one');
END;
CREATE TRIGGER draft_entries_fixed BEFORE UPDATE ON draft_entries
BEGIN
  SELECT RAISE(ABORT, 'a draft cannot be changed; save a new one');
END;

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
