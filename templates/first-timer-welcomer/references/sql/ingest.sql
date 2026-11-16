-- Ingest the files fetch.mjs wrote for one repository: the owner's login, the repository's labels, and the newest
-- open PRs and issues with their authors' association. Input: repo, run_id (or null outside a run).
-- An item a complete read no longer has is marked gone. A read that did not reach every item marks nothing gone.
-- Returns one row with the counts.
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
       json_extract(s, '$.issues_enabled') AS issues_enabled,
       json_extract(s, '$.prs_total') AS prs_total,
       json_extract(s, '$.issues_total') AS issues_total,
       json_extract(s, '$.labels_total') AS labels_total
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s) WHERE json_valid(s);
CREATE TEMP TABLE g_fetch (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.g_fetch
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo)
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
                AND min(length(f.login) BETWEEN 1 AND 39)
                AND min(typeof(f.prs_total) = 'integer' AND typeof(f.issues_total) = 'integer' AND typeof(f.labels_total) = 'integer'), 0)
FROM temp.f AS f, temp.r AS r;

CREATE TEMP TABLE src (kind TEXT NOT NULL, doc TEXT NOT NULL CONSTRAINT inbox_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
INSERT INTO temp.src SELECT 'label', coalesce(CAST(readfile(dir || 'labels.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'pr', coalesce(CAST(readfile(dir || 'prs.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'issue', coalesce(CAST(readfile(dir || 'issues.json') AS TEXT), 'x') FROM temp.r;

-- The repository's label names, as GitHub has them, capped at 50 characters.
CREATE TEMP TABLE lab (name TEXT NOT NULL CONSTRAINT label_not_text CHECK (length(name) BETWEEN 1 AND 50));
INSERT INTO temp.lab
SELECT CASE WHEN e.type = 'text' THEN substr(e.value, 1, 50) ELSE '' END
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind = 'label';

-- Every row is checked here, at the trust boundary. A bad row stops the whole step.
CREATE TEMP TABLE b (
  kind TEXT NOT NULL,
  number INTEGER,
  number_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (number_type = 'integer'),
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  author TEXT NOT NULL CONSTRAINT author_login_unsafe CHECK (author = '' OR (length(author) BETWEEN 1 AND 39 AND author NOT GLOB '*[^A-Za-z0-9_-]*')),
  author_type TEXT NOT NULL,
  association TEXT NOT NULL CONSTRAINT association_unknown CHECK (association IN
    ('COLLABORATOR', 'CONTRIBUTOR', 'FIRST_TIMER', 'FIRST_TIME_CONTRIBUTOR', 'MANNEQUIN', 'MEMBER', 'NONE', 'OWNER')),
  created_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  updated_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  is_draft INTEGER NOT NULL,
  labels TEXT NOT NULL CONSTRAINT labels_not_a_list_of_names CHECK (labels <> 'x'),
  counts_ok INTEGER NOT NULL CONSTRAINT count_not_integer CHECK (counts_ok = 1),
  assignees INTEGER NOT NULL,
  linked_prs INTEGER NOT NULL,
  body_chars INTEGER NOT NULL,
  comments INTEGER NOT NULL,
  owner_last_comment_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (owner_last_comment_at = '' OR owner_last_comment_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  UNIQUE (number)
);

INSERT INTO temp.b
SELECT s.kind, json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       substr(coalesce(json_extract(e.value, '$.title'), ''), 1, 300),
       coalesce(json_extract(e.value, '$.url'), ''),
       CASE WHEN json_type(e.value, '$.author') = 'object' THEN coalesce(json_extract(e.value, '$.author.login'), '') ELSE '' END,
       coalesce(json_extract(e.value, '$.author.type'), ''),
       coalesce(json_extract(e.value, '$.authorAssociation'), ''),
       coalesce(json_extract(e.value, '$.createdAt'), ''),
       coalesce(json_extract(e.value, '$.updatedAt'), ''),
       CASE WHEN json_extract(e.value, '$.isDraft') THEN 1 ELSE 0 END,
       -- Up to 20 label names of up to 50 characters. Anything but a list of names is refused.
       CASE WHEN json_type(e.value, '$.labels') = 'array'
                 AND NOT EXISTS (SELECT 1 FROM json_each(e.value, '$.labels') AS l WHERE l.type <> 'text')
            THEN (SELECT json_group_array(substr(l.value, 1, 50)) FROM (SELECT value FROM json_each(e.value, '$.labels') LIMIT 20) AS l)
            ELSE 'x' END,
       coalesce(json_type(e.value, '$.assignees') = 'integer' AND json_type(e.value, '$.linkedPrs') = 'integer'
                AND json_type(e.value, '$.bodyChars') = 'integer' AND json_type(e.value, '$.comments') = 'integer', 0),
       coalesce(json_extract(e.value, '$.assignees'), 0), coalesce(json_extract(e.value, '$.linkedPrs'), 0),
       coalesce(json_extract(e.value, '$.bodyChars'), 0), coalesce(json_extract(e.value, '$.comments'), 0),
       coalesce(json_extract(e.value, '$.ownerLastCommentAt'), '')
FROM temp.src AS s, json_each(s.doc) AS e WHERE s.kind IN ('pr', 'issue');

CREATE TEMP TABLE cut AS
SELECT (SELECT count(*) FROM temp.b WHERE kind = 'pr') < f.prs_total AS prs_cut,
       (SELECT count(*) FROM temp.b WHERE kind = 'issue') < f.issues_total AS issues_cut,
       (SELECT count(*) FROM temp.lab) < f.labels_total AS labels_cut
FROM temp.f AS f;

BEGIN;

UPDATE repos SET login = (SELECT login FROM temp.f), labels = (SELECT json_group_array(name) FROM temp.lab)
WHERE repo = (SELECT repo FROM temp.r);

INSERT INTO items (repo, kind, number, title, url, author, author_type, association, created_at, updated_at, is_draft,
                   labels, assignees, linked_prs, body_chars, comments, owner_last_comment_at, state, first_seen, last_seen)
SELECT r.repo, x.kind, x.number, x.title, x.url, x.author, x.author_type, x.association, x.created_at, x.updated_at, x.is_draft,
       x.labels, x.assignees, x.linked_prs, x.body_chars, x.comments, x.owner_last_comment_at, 'open',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), f.fetched_at
FROM temp.b AS x, temp.r AS r, temp.f AS f WHERE true
ON CONFLICT (repo, number) DO UPDATE SET
  kind = excluded.kind, title = excluded.title, url = excluded.url, author = excluded.author, author_type = excluded.author_type,
  association = excluded.association, created_at = excluded.created_at, updated_at = excluded.updated_at,
  is_draft = excluded.is_draft, labels = excluded.labels, assignees = excluded.assignees, linked_prs = excluded.linked_prs,
  body_chars = excluded.body_chars, comments = excluded.comments, owner_last_comment_at = excluded.owner_last_comment_at,
  state = 'open', last_seen = excluded.last_seen;

-- Gone: only after a complete read of that kind.
UPDATE items SET state = 'gone', last_seen = (SELECT fetched_at FROM temp.f)
WHERE repo = (SELECT repo FROM temp.r) AND state = 'open'
  AND ((kind = 'pr' AND NOT (SELECT prs_cut FROM temp.cut))
    OR (kind = 'issue' AND NOT (SELECT issues_cut FROM temp.cut)))
  AND NOT EXISTS (SELECT 1 FROM temp.b AS x WHERE x.number = items.number);

INSERT INTO fetches (run_id, repo, login, fetched_at, prs, prs_total, issues, issues_total, labels, labels_total, issues_enabled,
                     prs_cut, issues_cut, labels_cut, ingested_at)
SELECT json_extract(i.j, '$.run_id'), r.repo, f.login, f.fetched_at,
       (SELECT count(*) FROM temp.b WHERE kind = 'pr'), f.prs_total,
       (SELECT count(*) FROM temp.b WHERE kind = 'issue'), f.issues_total,
       (SELECT count(*) FROM temp.lab), f.labels_total,
       CASE WHEN f.issues_enabled THEN 1 ELSE 0 END, c.prs_cut, c.issues_cut, c.labels_cut,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input AS i, temp.r AS r, temp.f AS f, temp.cut AS c;

COMMIT;

SELECT repo, login, fetched_at, prs, prs_total, issues, issues_total, labels, labels_total, issues_enabled,
       prs_cut, issues_cut, labels_cut,
       (SELECT count(*) FROM items AS it WHERE it.repo = fe.repo AND it.state = 'gone' AND it.last_seen = fe.fetched_at) AS gone_now
FROM fetches AS fe WHERE id = (SELECT max(id) FROM fetches);
