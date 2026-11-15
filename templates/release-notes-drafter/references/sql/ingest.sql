-- Ingest the files fetch.mjs wrote for one repository: its releases and the pull requests merged
-- since the base release. Input: repo, run_id (or null outside a run).
-- Replaces the repository's releases and window, and records the state the next draft is bound to.
-- Returns base_tag, since, pr_count, newest_merged_at, limit_reached and existing draft releases.
-- Run from the workspace root:
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

CREATE TEMP TABLE r (repo TEXT NOT NULL, dir TEXT NOT NULL);
INSERT INTO temp.r
SELECT p.repo, 'inbox/' || replace(p.repo, '/', '__') || '/'
FROM repos AS p, temp.input AS i WHERE p.repo = json_extract(i.j, '$.repo');
CREATE TEMP TABLE repo_guard (n INTEGER CONSTRAINT repo_not_registered CHECK (n = 1));
INSERT INTO temp.repo_guard SELECT count(*) FROM temp.r;

-- The fetch summary must name this repository.
CREATE TEMP TABLE f (repo TEXT, branch TEXT, base_tag TEXT, since TEXT, fetched_at TEXT, pr_limit INTEGER);
INSERT INTO temp.f
SELECT json_extract(s, '$.repo'), json_extract(s, '$.default_branch'), json_extract(s, '$.base_tag'),
       json_extract(s, '$.since'), json_extract(s, '$.fetched_at'), json_extract(s, '$.limits.prs')
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s);
CREATE TEMP TABLE fetch_guard (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.fetch_guard
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo) AND min(f.pr_limit > 0)
                AND min(f.since GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'), 0)
FROM temp.f AS f, temp.r AS r;

CREATE TEMP TABLE src (name TEXT NOT NULL, doc TEXT NOT NULL CONSTRAINT inbox_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
INSERT INTO temp.src SELECT 'releases', CAST(readfile(dir || 'releases.json') AS TEXT) FROM temp.r;
INSERT INTO temp.src SELECT 'prs', CAST(readfile(dir || 'prs.json') AS TEXT) FROM temp.r;

-- Every row is checked here, at the trust boundary. A bad row stops the whole step.
CREATE TEMP TABLE rel (
  tag TEXT NOT NULL CONSTRAINT release_tag_missing CHECK (length(tag) BETWEEN 1 AND 200),
  name TEXT NOT NULL, is_draft INTEGER NOT NULL, is_pre INTEGER NOT NULL, is_latest INTEGER NOT NULL,
  created TEXT NOT NULL, published TEXT NOT NULL,
  UNIQUE (tag)
);
INSERT INTO temp.rel
SELECT json_extract(e.value, '$.tagName'), substr(coalesce(json_extract(e.value, '$.name'), ''), 1, 200),
       CASE WHEN json_extract(e.value, '$.isDraft') THEN 1 ELSE 0 END,
       CASE WHEN json_extract(e.value, '$.isPrerelease') THEN 1 ELSE 0 END,
       CASE WHEN json_extract(e.value, '$.isLatest') THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.createdAt'), ''), coalesce(json_extract(e.value, '$.publishedAt'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.name = 'releases';

-- The base the fetch chose must be one of the releases it read.
CREATE TEMP TABLE base_guard (ok INTEGER CONSTRAINT base_tag_not_in_releases CHECK (ok = 1));
INSERT INTO temp.base_guard
SELECT f.base_tag IS NULL OR EXISTS (SELECT 1 FROM temp.rel WHERE tag = f.base_tag AND is_draft = 0) FROM temp.f AS f;

CREATE TEMP TABLE b (
  number INTEGER NOT NULL CONSTRAINT pr_number_not_integer CHECK (typeof(number) = 'integer' AND number > 0),
  number_type TEXT NOT NULL CONSTRAINT pr_number_not_json_integer CHECK (number_type = 'integer'),
  title TEXT NOT NULL CONSTRAINT pr_title_too_long CHECK (length(title) <= 1000),
  author TEXT NOT NULL, is_bot INTEGER NOT NULL, labels TEXT NOT NULL, body TEXT NOT NULL, url TEXT NOT NULL,
  merged TEXT NOT NULL CONSTRAINT pr_merged_at_not_iso CHECK (merged GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  UNIQUE (number)
);
INSERT INTO temp.b
SELECT json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       coalesce(json_extract(e.value, '$.title'), ''), coalesce(json_extract(e.value, '$.author.login'), ''),
       CASE WHEN json_extract(e.value, '$.author.is_bot') THEN 1 ELSE 0 END,
       coalesce((SELECT json_group_array(json_extract(l.value, '$.name')) FROM json_each(e.value, '$.labels') AS l), '[]'),
       substr(coalesce(json_extract(e.value, '$.body'), ''), 1, 4000),
       coalesce(json_extract(e.value, '$.url'), ''), coalesce(json_extract(e.value, '$.mergedAt'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.name = 'prs';

-- Every pull request must be merged after the cutoff (the search said so; check it).
CREATE TEMP TABLE window_guard (n INTEGER CONSTRAINT pr_merged_before_the_base CHECK (n = 0));
INSERT INTO temp.window_guard SELECT count(*) FROM temp.b, temp.f WHERE b.merged <= f.since;

BEGIN;
DELETE FROM releases WHERE repo = (SELECT repo FROM temp.r);
INSERT INTO releases (repo, tag, name, is_draft, is_prerelease, is_latest, created_at, published_at)
SELECT r.repo, x.tag, x.name, x.is_draft, x.is_pre, x.is_latest, x.created, x.published FROM temp.rel AS x, temp.r AS r;
DELETE FROM prs WHERE repo = (SELECT repo FROM temp.r);
INSERT INTO prs (repo, number, title, author, author_is_bot, labels, body, url, merged_at)
SELECT r.repo, x.number, x.title, x.author, x.is_bot, x.labels, x.body, x.url, x.merged FROM temp.b AS x, temp.r AS r;
-- The default branch is checked by the repos table: letters, digits and ./-_ only, no leading . - or /.
UPDATE repos SET
  default_branch = (SELECT branch FROM temp.f),
  base_tag = coalesce((SELECT base_tag FROM temp.f), ''),
  since = (SELECT since FROM temp.f),
  newest_merged_at = coalesce((SELECT max(merged) FROM temp.b), ''),
  pr_count = (SELECT count(*) FROM temp.b),
  fetched_at = (SELECT fetched_at FROM temp.f)
WHERE repo = (SELECT repo FROM temp.r);
INSERT INTO reads (run_id, repo, fetched_at, base_tag, since, pr_count, limit_reached, ingested_at)
SELECT json_extract(i.j, '$.run_id'), r.repo, f.fetched_at, coalesce(f.base_tag, ''), f.since,
       (SELECT count(*) FROM temp.b), (SELECT count(*) FROM temp.b) >= f.pr_limit,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.r AS r, temp.f AS f, temp.input AS i;
COMMIT;

SELECT p.repo, p.default_branch, p.base_tag, p.since, p.pr_count, p.newest_merged_at, d.limit_reached, p.fetched_at,
       (SELECT json_group_array(tag) FROM releases WHERE repo = p.repo AND is_draft = 1) AS draft_releases
FROM repos AS p JOIN reads AS d ON d.id = (SELECT max(id) FROM reads WHERE repo = p.repo)
WHERE p.repo = (SELECT repo FROM temp.r);
