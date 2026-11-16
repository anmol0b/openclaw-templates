-- Ingest the files fetch.mjs wrote for one repository: open PRs and reviewer candidates.
-- Input: repo, run_id (or null outside a run).
-- A PR a complete read no longer has is marked GONE (merged or closed). A read that returned its full limit marks nothing gone.
-- Candidates are replaced with the ones this fetch read. Returns one row with the counts.
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
       json_extract(s, '$.login') AS login,
       json_extract(s, '$.fetched_at') AS fetched_at,
       json_extract(s, '$.collaborators_readable') AS collaborators_readable,
       json_extract(s, '$.collaborators_cut') AS collaborators_cut,
       coalesce(json_extract(s, '$.codeowners_path'), '') AS codeowners_path,
       json_extract(s, '$.limits.prs') AS pr_limit
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s) WHERE json_valid(s);
CREATE TEMP TABLE g_fetch (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.g_fetch
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo)
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
                AND min(length(f.login) BETWEEN 1 AND 39) AND min(f.pr_limit > 0)
                AND min(f.codeowners_path IN ('', '.github/CODEOWNERS', 'CODEOWNERS', 'docs/CODEOWNERS')), 0)
FROM temp.f AS f, temp.r AS r;

CREATE TEMP TABLE src (kind TEXT NOT NULL, doc TEXT NOT NULL CONSTRAINT inbox_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
INSERT INTO temp.src SELECT 'pr', coalesce(CAST(readfile(dir || 'prs.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'candidate', coalesce(CAST(readfile(dir || 'candidates.json') AS TEXT), 'x') FROM temp.r;

-- Every row is checked here, at the trust boundary. A bad row stops the whole step.
CREATE TEMP TABLE b (
  number INTEGER,
  number_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (number_type = 'integer'),
  title TEXT NOT NULL CONSTRAINT title_too_long CHECK (length(title) <= 300),
  url TEXT NOT NULL,
  author TEXT NOT NULL CONSTRAINT author_too_long CHECK (length(author) <= 60),
  author_is_bot INTEGER NOT NULL,
  is_draft INTEGER NOT NULL,
  review_decision TEXT NOT NULL CONSTRAINT unknown_review_decision CHECK (review_decision IN ('', 'REVIEW_REQUIRED', 'CHANGES_REQUESTED', 'APPROVED')),
  mergeable TEXT NOT NULL CONSTRAINT unknown_mergeable CHECK (mergeable IN ('', 'MERGEABLE', 'CONFLICTING', 'UNKNOWN')),
  created_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  updated_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  head_sha TEXT NOT NULL CONSTRAINT head_not_a_sha CHECK (length(head_sha) = 40 AND head_sha NOT GLOB '*[^0-9a-f]*'),
  last_commit_at TEXT CONSTRAINT time_not_iso_utc CHECK (last_commit_at IS NULL OR last_commit_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  requested_users TEXT NOT NULL,
  -- 1 when requested_users is a JSON list of plain logins (computed below; CHECK cannot hold a subquery).
  requested_ok INTEGER NOT NULL CONSTRAINT requested_users_not_logins CHECK (requested_ok = 1),
  requested_teams INTEGER NOT NULL,
  last_review_at TEXT CONSTRAINT time_not_iso_utc CHECK (last_review_at IS NULL OR last_review_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  changes_requested_at TEXT CONSTRAINT time_not_iso_utc CHECK (changes_requested_at IS NULL OR changes_requested_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  comments INTEGER NOT NULL CONSTRAINT count_not_integer CHECK (typeof(comments) = 'integer' AND comments >= 0),
  owner_comments INTEGER NOT NULL CONSTRAINT count_not_integer CHECK (typeof(owner_comments) = 'integer' AND owner_comments >= 0),
  owner_last_comment_at TEXT CONSTRAINT time_not_iso_utc CHECK (owner_last_comment_at IS NULL OR owner_last_comment_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  UNIQUE (number)
);

INSERT INTO temp.b
SELECT json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       coalesce(json_extract(e.value, '$.title'), ''), coalesce(json_extract(e.value, '$.url'), ''),
       coalesce(json_extract(e.value, '$.author'), ''),
       CASE WHEN json_extract(e.value, '$.author_is_bot') THEN 1 ELSE 0 END,
       CASE WHEN json_extract(e.value, '$.is_draft') THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.review_decision'), ''), coalesce(json_extract(e.value, '$.mergeable'), ''),
       coalesce(json_extract(e.value, '$.created_at'), ''), coalesce(json_extract(e.value, '$.updated_at'), ''),
       coalesce(json_extract(e.value, '$.head_sha'), ''), json_extract(e.value, '$.last_commit_at'),
       coalesce(json_extract(e.value, '$.requested_users'), 'x'),
       CASE WHEN json_type(e.value, '$.requested_users') = 'array'
            THEN NOT EXISTS (SELECT 1 FROM json_each(e.value, '$.requested_users') AS u
                             WHERE u.type <> 'text' OR length(u.value) NOT BETWEEN 1 AND 39 OR u.value GLOB '*[^A-Za-z0-9-]*'
                                OR u.value GLOB '-*' OR u.value GLOB '*-')
            ELSE 0 END,
       coalesce(json_extract(e.value, '$.requested_teams'), 0),
       -- A maintainer review by someone other than the author ends the wait for a review.
       (SELECT max(json_extract(v.value, '$.submitted_at')) FROM json_each(e.value, '$.reviews') AS v
         WHERE json_extract(v.value, '$.maintainer') AND lower(json_extract(v.value, '$.login')) <> lower(json_extract(e.value, '$.author'))
           AND json_extract(v.value, '$.state') IN ('APPROVED', 'CHANGES_REQUESTED', 'COMMENTED')),
       (SELECT max(json_extract(v.value, '$.submitted_at')) FROM json_each(e.value, '$.reviews') AS v
         WHERE json_extract(v.value, '$.maintainer') AND json_extract(v.value, '$.state') = 'CHANGES_REQUESTED'),
       json_extract(e.value, '$.comments'), json_extract(e.value, '$.owner_comments'), json_extract(e.value, '$.owner_last_comment_at')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind = 'pr';

CREATE TEMP TABLE c (
  login TEXT NOT NULL CONSTRAINT candidate_login_unsafe CHECK (
    length(login) BETWEEN 1 AND 39 AND login NOT GLOB '*[^A-Za-z0-9-]*' AND login NOT GLOB '-*' AND login NOT GLOB '*-'),
  source TEXT NOT NULL CONSTRAINT unknown_candidate_source CHECK (source IN ('collaborator', 'codeowner', 'reviewer')),
  UNIQUE (login, source)
);
-- Plain INSERT (not OR IGNORE, which would also skip a failed check); DISTINCT folds repeats.
INSERT INTO temp.c
SELECT DISTINCT coalesce(json_extract(e.value, '$.login'), ''), coalesce(json_extract(e.value, '$.source'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind = 'candidate';

CREATE TEMP TABLE cut AS SELECT (SELECT count(*) FROM temp.b) >= f.pr_limit AS prs_cut FROM temp.f AS f;

BEGIN;

UPDATE repos SET login = (SELECT login FROM temp.f) WHERE repo = (SELECT repo FROM temp.r);

INSERT INTO prs (repo, number, title, url, author, author_is_bot, is_draft, review_decision, mergeable, created_at, updated_at,
                 head_sha, last_commit_at, requested_users, requested_teams, last_review_at, changes_requested_at,
                 comments, owner_comments, owner_last_comment_at, state, first_seen, last_seen)
SELECT r.repo, x.number, x.title, x.url, x.author, x.author_is_bot, x.is_draft, x.review_decision, x.mergeable, x.created_at,
       x.updated_at, x.head_sha, x.last_commit_at, json(x.requested_users), x.requested_teams, x.last_review_at,
       x.changes_requested_at, x.comments, x.owner_comments, x.owner_last_comment_at, 'OPEN',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), f.fetched_at
FROM temp.b AS x, temp.r AS r, temp.f AS f WHERE true
ON CONFLICT (repo, number) DO UPDATE SET
  title = excluded.title, url = excluded.url, author = excluded.author, author_is_bot = excluded.author_is_bot,
  is_draft = excluded.is_draft, review_decision = excluded.review_decision, mergeable = excluded.mergeable,
  created_at = excluded.created_at, updated_at = excluded.updated_at, head_sha = excluded.head_sha,
  last_commit_at = excluded.last_commit_at, requested_users = excluded.requested_users,
  requested_teams = excluded.requested_teams, last_review_at = excluded.last_review_at,
  changes_requested_at = excluded.changes_requested_at, comments = excluded.comments,
  owner_comments = excluded.owner_comments, owner_last_comment_at = excluded.owner_last_comment_at,
  state = 'OPEN', last_seen = excluded.last_seen;

-- Gone: only after a complete read.
UPDATE prs SET state = 'GONE', last_seen = (SELECT fetched_at FROM temp.f)
WHERE repo = (SELECT repo FROM temp.r) AND state = 'OPEN' AND NOT (SELECT prs_cut FROM temp.cut)
  AND NOT EXISTS (SELECT 1 FROM temp.b AS x WHERE x.number = prs.number);

DELETE FROM candidates WHERE repo = (SELECT repo FROM temp.r);
INSERT INTO candidates (repo, login, source) SELECT r.repo, c.login, c.source FROM temp.c AS c, temp.r AS r;

INSERT INTO fetches (run_id, repo, login, fetched_at, prs, prs_cut, collaborators_readable, collaborators_cut,
                     codeowners_path, candidates, ingested_at)
SELECT json_extract(i.j, '$.run_id'), r.repo, f.login, f.fetched_at, (SELECT count(*) FROM temp.b), c.prs_cut,
       CASE WHEN f.collaborators_readable THEN 1 ELSE 0 END, CASE WHEN f.collaborators_cut THEN 1 ELSE 0 END,
       f.codeowners_path, (SELECT count(DISTINCT login) FROM temp.c), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input AS i, temp.r AS r, temp.f AS f, temp.cut AS c;

COMMIT;

SELECT repo, login, fetched_at, prs, prs_cut, collaborators_readable, collaborators_cut, codeowners_path, candidates,
       (SELECT count(*) FROM prs AS p WHERE p.repo = fe.repo AND p.state = 'GONE' AND p.last_seen = fe.fetched_at) AS gone_now
FROM fetches AS fe WHERE id = (SELECT max(id) FROM fetches);
