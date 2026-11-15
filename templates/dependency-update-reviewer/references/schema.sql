-- Dependency update reviewer database, schema version 1.
-- Create once at setup:
--   sqlite3 -bail "<db_path>" ".read references/schema.sql"
-- Times the agent did not read from GitHub come from the database clock (UTC).
-- PR text reaches this database only as JSON values read from files, never as SQL text.
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
  added_at TEXT NOT NULL
);

CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('scheduled', 'manual')),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  note TEXT NOT NULL DEFAULT ''
);

-- One row per bot list read that was ingested, so the digest can name gaps.
CREATE TABLE reads (
  id INTEGER PRIMARY KEY,
  run_id INTEGER REFERENCES runs (id),
  repo TEXT NOT NULL REFERENCES repos (repo),
  bot TEXT NOT NULL CHECK (bot IN ('dependabot', 'renovate')),
  fetched_at TEXT NOT NULL,
  read_count INTEGER NOT NULL,
  new_prs INTEGER NOT NULL,
  -- 1 when the read returned its full limit, so older open PRs may be missing.
  limit_reached INTEGER NOT NULL CHECK (limit_reached IN (0, 1)),
  ingested_at TEXT NOT NULL
);

CREATE TABLE prs (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL REFERENCES repos (repo),
  number INTEGER NOT NULL CHECK (typeof(number) = 'integer' AND number > 0),
  bot TEXT NOT NULL CHECK (bot IN ('dependabot', 'renovate')),
  title TEXT NOT NULL,
  url TEXT NOT NULL DEFAULT '',
  is_draft INTEGER NOT NULL DEFAULT 0 CHECK (is_draft IN (0, 1)),
  labels TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(labels) AND json_type(labels) = 'array'),
  head_sha TEXT NOT NULL CHECK (length(head_sha) = 40 AND head_sha NOT GLOB '*[^0-9a-f]*'),
  head_ref TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  -- Up to 8 release-note lines behind the note signals (references/parse.mjs, evidenceOf).
  -- The raw PR body is never stored.
  evidence TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(evidence) AND json_type(evidence) = 'array' AND json_array_length(evidence) <= 8),
  -- Parsed by references/parse.mjs: [{package, ecosystem, from, to, bump}].
  updates TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(updates) AND json_type(updates) = 'array'),
  signals TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(signals) AND json_type(signals) = 'array'),
  ci TEXT NOT NULL CHECK (ci IN ('passing', 'failing', 'pending', 'none')),
  failing_checks TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(failing_checks) AND json_type(failing_checks) = 'array'),
  -- OPEN while the latest full read lists it; GONE once a read that did not hit its limit no longer does.
  state TEXT NOT NULL DEFAULT 'OPEN' CHECK (state IN ('OPEN', 'GONE')),
  first_seen TEXT NOT NULL,
  -- fetched_at of the latest fetch that listed this PR.
  last_seen TEXT NOT NULL,
  -- The head SHA the latest review covered. The PR is queued while head_sha differs.
  reviewed_head TEXT NOT NULL DEFAULT '',
  UNIQUE (repo, number)
);

-- The lowest lane a PR can be in, from facts only. The agent may move a PR to a stricter
-- lane after reading the release notes, never to a looser one (see reviews_floor below).
CREATE VIEW pr_lane AS
SELECT p.id AS pr_id,
       CASE
         WHEN p.ci = 'failing' THEN 'blocked-by-ci'
         WHEN p.ci IN ('pending', 'none') OR p.is_draft = 1
              OR EXISTS (SELECT 1 FROM json_each(p.signals) AS s WHERE s.value IN (
                'major-bump', 'zero-major-minor', 'version-unknown', 'no-update-parsed',
                'breaking-note', 'removal-note', 'deprecation-note', 'runtime-floor-note'))
           THEN 'needs-a-look'
         ELSE 'looks-safe'
       END AS lane,
       (SELECT json_group_array(r) FROM (
          SELECT 'ci-failing' AS r WHERE p.ci = 'failing'
          UNION ALL SELECT 'ci-' || p.ci WHERE p.ci IN ('pending', 'none')
          UNION ALL SELECT 'draft' WHERE p.is_draft = 1
          UNION ALL SELECT s.value FROM json_each(p.signals) AS s WHERE s.value IN (
                'major-bump', 'zero-major-minor', 'version-unknown', 'no-update-parsed',
                'breaking-note', 'removal-note', 'deprecation-note', 'runtime-floor-note'))) AS reasons
FROM prs AS p;

CREATE TABLE reviews (
  id INTEGER PRIMARY KEY,
  pr_id INTEGER NOT NULL REFERENCES prs (id),
  run_id INTEGER REFERENCES runs (id),
  head_sha TEXT NOT NULL,
  lane_floor TEXT NOT NULL CHECK (lane_floor IN ('looks-safe', 'needs-a-look', 'blocked-by-ci')),
  verdict TEXT NOT NULL CHECK (verdict IN ('looks-safe', 'needs-a-look', 'blocked-by-ci')),
  note TEXT NOT NULL CHECK (length(trim(note)) BETWEEN 1 AND 1000),
  suggested_action TEXT NOT NULL DEFAULT 'none' CHECK (suggested_action IN ('none', 'approve', 'comment', 'bot-command')),
  created_at TEXT NOT NULL
);
CREATE INDEX reviews_pr ON reviews (pr_id, id);

-- The verdict is never looser than the facts allow.
CREATE TRIGGER reviews_floor BEFORE INSERT ON reviews
WHEN (CASE NEW.verdict WHEN 'looks-safe' THEN 0 WHEN 'needs-a-look' THEN 1 ELSE 2 END)
   < (CASE NEW.lane_floor WHEN 'looks-safe' THEN 0 WHEN 'needs-a-look' THEN 1 ELSE 2 END)
BEGIN
  SELECT RAISE(ABORT, 'verdict_looser_than_the_facts');
END;
CREATE TRIGGER reviews_approve_only_safe BEFORE INSERT ON reviews
WHEN NEW.suggested_action = 'approve' AND NEW.verdict <> 'looks-safe'
BEGIN
  SELECT RAISE(ABORT, 'approve_suggested_for_a_pr_that_needs_a_look');
END;

-- An owner approval for one write to GitHub. The command is built by ask-approval.sql,
-- never by the agent. It is bound to the PR as the owner saw it, head SHA included, and used once.
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  pr_id INTEGER NOT NULL REFERENCES prs (id),
  action TEXT NOT NULL CHECK (action IN ('approve', 'comment', 'bot-command')),
  bot_command TEXT NOT NULL DEFAULT '' CHECK (bot_command IN ('', 'rebase', 'recreate')),
  body_file TEXT NOT NULL DEFAULT '',
  body_sha3 TEXT NOT NULL DEFAULT '',
  exact_step TEXT NOT NULL CHECK (length(exact_step) BETWEEN 1 AND 2000),
  seen_head_sha TEXT NOT NULL,
  seen_updated_at TEXT NOT NULL,
  asked_at TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'granted', 'refused', 'withdrawn')),
  owner_words TEXT NOT NULL DEFAULT '',
  decided_at TEXT,
  used_at TEXT,
  outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'done', 'failed')),
  outcome_note TEXT NOT NULL DEFAULT '',
  outcome_at TEXT,
  CHECK (action <> 'comment' OR (body_file <> '' AND body_sha3 <> '')),
  CHECK ((action = 'bot-command') = (bot_command <> '')),
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
CREATE TRIGGER approvals_request_fixed BEFORE UPDATE OF pr_id, action, bot_command, body_file, body_sha3, exact_step, seen_head_sha, seen_updated_at, asked_at ON approvals
BEGIN
  SELECT RAISE(ABORT, 'a request cannot be changed; withdraw it and ask again');
END;

COMMIT;
PRAGMA user_version = 1;
SELECT 'schema version 1 created' AS result;
