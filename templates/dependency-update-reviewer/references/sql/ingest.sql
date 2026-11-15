-- Ingest the files fetch.mjs wrote for one repository. Input: repo, run_id (or null outside a run).
-- A PR that a read no longer lists is marked GONE (merged or closed), unless that read hit its limit.
-- Returns one row per bot with read_count, new_prs and limit_reached.
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
CREATE TEMP TABLE g1 (n INTEGER CONSTRAINT repo_not_registered CHECK (n = 1));
INSERT INTO temp.g1 SELECT count(*) FROM temp.r;

-- The fetch summary must name this repository and carry a real time and limit.
CREATE TEMP TABLE f (repo TEXT, fetched_at TEXT, lim INTEGER, dependabot INTEGER, renovate INTEGER);
INSERT INTO temp.f
SELECT json_extract(s, '$.repo'), json_extract(s, '$.fetched_at'), json_extract(s, '$.limit'),
       json_extract(s, '$.dependabot'), json_extract(s, '$.renovate')
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s);
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.g2
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo) AND min(f.lim > 0)
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'), 0)
FROM temp.f AS f, temp.r AS r;

CREATE TEMP TABLE src (doc TEXT CONSTRAINT prs_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
INSERT INTO temp.src SELECT CAST(readfile(dir || 'prs.json') AS TEXT) FROM temp.r;

-- Every row is checked here, at the trust boundary. A bad row stops the whole step.
CREATE TEMP TABLE b (
  number INTEGER NOT NULL,
  number_type TEXT NOT NULL CONSTRAINT pr_number_not_integer CHECK (number_type = 'integer' AND number > 0),
  bot TEXT CONSTRAINT pr_not_from_a_known_bot CHECK (bot IN ('dependabot', 'renovate')),
  title TEXT NOT NULL CONSTRAINT title_too_long CHECK (length(title) <= 1000),
  url TEXT NOT NULL,
  is_draft INTEGER NOT NULL,
  labels TEXT NOT NULL CONSTRAINT labels_not_a_list CHECK (json_valid(labels) AND json_type(labels) = 'array'),
  head_sha TEXT CONSTRAINT head_sha_not_40_hex CHECK (length(head_sha) = 40 AND head_sha NOT GLOB '*[^0-9a-f]*'),
  head_ref TEXT NOT NULL,
  created TEXT NOT NULL,
  updated TEXT CONSTRAINT updated_at_not_iso_utc CHECK (updated GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  evidence TEXT NOT NULL CONSTRAINT evidence_not_a_list CHECK (json_valid(evidence) AND json_type(evidence) = 'array' AND json_array_length(evidence) <= 8),
  updates TEXT CONSTRAINT updates_not_a_list CHECK (json_valid(updates) AND json_type(updates) = 'array'),
  signals TEXT CONSTRAINT signals_not_a_list CHECK (json_valid(signals) AND json_type(signals) = 'array'),
  ci TEXT CONSTRAINT ci_state_unknown CHECK (ci IN ('passing', 'failing', 'pending', 'none')),
  failing TEXT CONSTRAINT failing_checks_not_a_list CHECK (json_valid(failing) AND json_type(failing) = 'array'),
  UNIQUE (number)
);
INSERT INTO temp.b
SELECT json_extract(e.value, '$.number'),
       coalesce(json_type(e.value, '$.number'), 'missing'),
       json_extract(e.value, '$.bot'),
       coalesce(json_extract(e.value, '$.title'), ''),
       coalesce(json_extract(e.value, '$.url'), ''),
       CASE WHEN json_extract(e.value, '$.isDraft') THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.labels'), '[]'),
       json_extract(e.value, '$.headRefOid'),
       coalesce(json_extract(e.value, '$.headRefName'), ''),
       coalesce(json_extract(e.value, '$.createdAt'), ''),
       json_extract(e.value, '$.updatedAt'),
       coalesce(json_extract(e.value, '$.evidence'), '[]'),
       json_extract(e.value, '$.updates'),
       json_extract(e.value, '$.signals'),
       json_extract(e.value, '$.ci'),
       json_extract(e.value, '$.failingChecks')
FROM temp.src AS s, json_each(s.doc) AS e;

CREATE TEMP TABLE stats (bot TEXT PRIMARY KEY, read_count INTEGER, new_prs INTEGER, limit_reached INTEGER);
INSERT INTO temp.stats
SELECT k.bot,
       (SELECT count(*) FROM temp.b WHERE bot = k.bot),
       (SELECT count(*) FROM temp.b AS x WHERE x.bot = k.bot
         AND NOT EXISTS (SELECT 1 FROM prs AS p, temp.r AS r WHERE p.repo = r.repo AND p.number = x.number)),
       CASE WHEN k.n >= (SELECT lim FROM temp.f) THEN 1 ELSE 0 END
FROM (SELECT 'dependabot' AS bot, (SELECT dependabot FROM temp.f) AS n
      UNION ALL SELECT 'renovate', (SELECT renovate FROM temp.f)) AS k;

BEGIN;

INSERT INTO prs (repo, number, bot, title, url, is_draft, labels, head_sha, head_ref, created_at, updated_at,
                 evidence, updates, signals, ci, failing_checks, state, first_seen, last_seen)
SELECT r.repo, x.number, x.bot, x.title, x.url, x.is_draft, json(x.labels), x.head_sha, x.head_ref, x.created, x.updated,
       json(x.evidence), json(x.updates), json(x.signals), x.ci, json(x.failing), 'OPEN',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), f.fetched_at
FROM temp.b AS x, temp.r AS r, temp.f AS f
WHERE true
ON CONFLICT (repo, number) DO UPDATE SET
  bot = excluded.bot,
  title = excluded.title,
  url = excluded.url,
  is_draft = excluded.is_draft,
  labels = excluded.labels,
  head_sha = excluded.head_sha,
  head_ref = excluded.head_ref,
  updated_at = excluded.updated_at,
  evidence = excluded.evidence,
  updates = excluded.updates,
  signals = excluded.signals,
  ci = excluded.ci,
  failing_checks = excluded.failing_checks,
  state = 'OPEN',
  last_seen = excluded.last_seen;

-- Merged or closed: a full read (under its limit) no longer lists it.
UPDATE prs SET state = 'GONE'
WHERE repo = (SELECT repo FROM temp.r) AND state = 'OPEN'
  AND number NOT IN (SELECT number FROM temp.b)
  AND bot IN (SELECT bot FROM temp.stats WHERE limit_reached = 0);

INSERT INTO reads (run_id, repo, bot, fetched_at, read_count, new_prs, limit_reached, ingested_at)
SELECT json_extract(i.j, '$.run_id'), r.repo, s.bot, f.fetched_at, s.read_count, s.new_prs, s.limit_reached,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.stats AS s, temp.r AS r, temp.f AS f, temp.input AS i;

COMMIT;

SELECT s.bot, s.read_count, s.new_prs, s.limit_reached,
       (SELECT count(*) FROM prs AS p, temp.r AS r WHERE p.repo = r.repo AND p.bot = s.bot AND p.state = 'OPEN' AND p.head_sha <> p.reviewed_head) AS waiting,
       (SELECT fetched_at FROM temp.f) AS fetched_at
FROM temp.stats AS s ORDER BY s.bot;
