-- Ingest the files fetch.mjs wrote for one repository: the login, the default branch, branches, the owner's open PRs
-- and the open issues assigned to them. Input: repo, run_id (or null outside a run).
-- An item a complete read no longer has is marked gone. A read that returned its full limit marks nothing gone.
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
       json_extract(s, '$.default_branch') AS default_branch,
       json_extract(s, '$.fetched_at') AS fetched_at,
       json_extract(s, '$.issues_enabled') AS issues_enabled,
       json_extract(s, '$.limits.branches') AS branch_limit,
       json_extract(s, '$.limits.prs') AS pr_limit,
       json_extract(s, '$.limits.issues') AS issue_limit
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s) WHERE json_valid(s);
CREATE TEMP TABLE g_fetch (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.g_fetch
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo)
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
                AND min(length(f.login) BETWEEN 1 AND 39) AND min(length(f.default_branch) BETWEEN 1 AND 255)
                AND min(f.branch_limit > 0 AND f.pr_limit > 0 AND f.issue_limit > 0), 0)
FROM temp.f AS f, temp.r AS r;

CREATE TEMP TABLE src (kind TEXT NOT NULL, doc TEXT NOT NULL CONSTRAINT inbox_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
-- The branch total comes from the branch read itself, so a partial read is visible even under the limit.
CREATE TEMP TABLE total AS
SELECT coalesce(json_extract(CAST(readfile(dir || 'branches.json') AS TEXT), '$.data.repository.refs.totalCount'), 0) AS branches_total FROM temp.r;
INSERT INTO temp.src SELECT 'branch', coalesce(json_extract(CAST(readfile(dir || 'branches.json') AS TEXT), '$.data.repository.refs.nodes'), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'pr', coalesce(CAST(readfile(dir || 'prs.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'issue', coalesce(CAST(readfile(dir || 'issues.json') AS TEXT), 'x') FROM temp.r;

-- Every row is checked here, at the trust boundary. A bad row stops the whole step.
CREATE TEMP TABLE b (
  kind TEXT NOT NULL,
  ref TEXT NOT NULL CONSTRAINT ref_missing_or_too_long CHECK (length(ref) BETWEEN 1 AND 255),
  number INTEGER,
  number_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (number_type IN ('integer', 'none')),
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  is_owners INTEGER NOT NULL,
  last_activity TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (last_activity GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  head_oid TEXT NOT NULL CONSTRAINT head_not_a_sha CHECK (head_oid = '' OR (length(head_oid) = 40 AND head_oid NOT GLOB '*[^0-9a-f]*')),
  is_draft INTEGER NOT NULL,
  ci_state TEXT NOT NULL,
  mergeable TEXT NOT NULL,
  merged_into_default INTEGER NOT NULL,
  merged_pr INTEGER,
  open_pr INTEGER,
  is_protected INTEGER NOT NULL,
  is_default INTEGER NOT NULL,
  UNIQUE (kind, ref)
);

-- Branches.
INSERT INTO temp.b
SELECT 'branch', coalesce(json_extract(e.value, '$.name'), ''), NULL, 'none', '', '',
       CASE WHEN lower(coalesce(json_extract(e.value, '$.target.author.user.login'), '')) = lower(f.login) THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.target.committedDate'), ''),
       coalesce(json_extract(e.value, '$.target.oid'), ''),
       0, 'none', '',
       CASE WHEN json_extract(e.value, '$.name') <> f.default_branch AND json_extract(e.value, '$.compare.behindBy') = 0 THEN 1 ELSE 0 END,
       (SELECT json_extract(p.value, '$.number') FROM json_each(e.value, '$.associatedPullRequests.nodes') AS p
         WHERE json_extract(p.value, '$.state') = 'MERGED' AND json_extract(p.value, '$.headRefOid') = json_extract(e.value, '$.target.oid') LIMIT 1),
       (SELECT json_extract(p.value, '$.number') FROM json_each(e.value, '$.associatedPullRequests.nodes') AS p
         WHERE json_extract(p.value, '$.state') = 'OPEN' LIMIT 1),
       CASE WHEN json_type(e.value, '$.branchProtectionRule') = 'object' THEN 1 ELSE 0 END,
       CASE WHEN json_extract(e.value, '$.name') = f.default_branch THEN 1 ELSE 0 END
FROM temp.src AS s, json_each(s.doc) AS e, temp.f AS f WHERE s.kind = 'branch';

-- The owner's open PRs. CI: any failed check is failing, else any unfinished one is pending.
INSERT INTO temp.b
SELECT 'pr', CAST(json_extract(e.value, '$.number') AS TEXT), json_extract(e.value, '$.number'),
       coalesce(json_type(e.value, '$.number'), 'missing'),
       substr(coalesce(json_extract(e.value, '$.title'), ''), 1, 300), coalesce(json_extract(e.value, '$.url'), ''),
       CASE WHEN lower(coalesce(json_extract(e.value, '$.author.login'), '')) = lower(f.login) THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.updatedAt'), ''),
       coalesce(json_extract(e.value, '$.headRefOid'), ''),
       CASE WHEN json_extract(e.value, '$.isDraft') THEN 1 ELSE 0 END,
       CASE
         WHEN EXISTS (SELECT 1 FROM json_each(e.value, '$.statusCheckRollup') AS c
                      WHERE upper(coalesce(json_extract(c.value, '$.conclusion'), json_extract(c.value, '$.state'), ''))
                            IN ('FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE')) THEN 'failing'
         WHEN EXISTS (SELECT 1 FROM json_each(e.value, '$.statusCheckRollup') AS c
                      WHERE upper(coalesce(nullif(json_extract(c.value, '$.conclusion'), ''), json_extract(c.value, '$.state'), ''))
                            IN ('', 'PENDING', 'EXPECTED', 'QUEUED', 'IN_PROGRESS')) THEN 'pending'
         WHEN json_array_length(e.value, '$.statusCheckRollup') > 0 THEN 'passing'
         ELSE 'none'
       END,
       coalesce(json_extract(e.value, '$.mergeable'), ''),
       0, NULL, NULL, 0, 0
FROM temp.src AS s, json_each(s.doc) AS e, temp.f AS f WHERE s.kind = 'pr';

-- Open issues assigned to the owner.
INSERT INTO temp.b
SELECT 'issue', CAST(json_extract(e.value, '$.number') AS TEXT), json_extract(e.value, '$.number'),
       coalesce(json_type(e.value, '$.number'), 'missing'),
       substr(coalesce(json_extract(e.value, '$.title'), ''), 1, 300), coalesce(json_extract(e.value, '$.url'), ''),
       CASE WHEN EXISTS (SELECT 1 FROM json_each(e.value, '$.assignees') AS a
                         WHERE lower(json_extract(a.value, '$.login')) = lower(f.login)) THEN 1 ELSE 0 END,
       coalesce(json_extract(e.value, '$.updatedAt'), ''),
       '', 0, 'none', '', 0, NULL, NULL, 0, 0
FROM temp.src AS s, json_each(s.doc) AS e, temp.f AS f WHERE s.kind = 'issue';

CREATE TEMP TABLE cut AS
SELECT ((SELECT count(*) FROM temp.b WHERE kind = 'branch') >= f.branch_limit
        OR (SELECT count(*) FROM temp.b WHERE kind = 'branch') < (SELECT branches_total FROM temp.total)) AS branches_cut,
       (SELECT count(*) FROM temp.b WHERE kind = 'pr') >= f.pr_limit AS prs_cut,
       (SELECT count(*) FROM temp.b WHERE kind = 'issue') >= f.issue_limit AS issues_cut
FROM temp.f AS f;

BEGIN;

UPDATE repos SET login = (SELECT login FROM temp.f), default_branch = (SELECT default_branch FROM temp.f)
WHERE repo = (SELECT repo FROM temp.r);

INSERT INTO items (repo, kind, ref, number, title, url, is_owners, last_activity, head_oid, is_draft, ci_state, mergeable,
                   merged_into_default, merged_pr, open_pr, is_protected, is_default, state, first_seen, last_seen)
SELECT r.repo, x.kind, x.ref, x.number, x.title, x.url, x.is_owners, x.last_activity, x.head_oid, x.is_draft, x.ci_state,
       x.mergeable, x.merged_into_default, x.merged_pr, x.open_pr, x.is_protected, x.is_default, 'open',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), f.fetched_at
FROM temp.b AS x, temp.r AS r, temp.f AS f WHERE true
ON CONFLICT (repo, kind, ref) DO UPDATE SET
  title = excluded.title, url = excluded.url, is_owners = excluded.is_owners,
  last_activity = excluded.last_activity, head_oid = excluded.head_oid, is_draft = excluded.is_draft,
  ci_state = excluded.ci_state, mergeable = excluded.mergeable, merged_into_default = excluded.merged_into_default,
  merged_pr = excluded.merged_pr, open_pr = excluded.open_pr, is_protected = excluded.is_protected,
  is_default = excluded.is_default, state = 'open', last_seen = excluded.last_seen;

-- Gone: only after a complete read of that kind.
UPDATE items SET state = 'gone', last_seen = (SELECT fetched_at FROM temp.f)
WHERE repo = (SELECT repo FROM temp.r) AND state = 'open'
  AND ((kind = 'branch' AND NOT (SELECT branches_cut FROM temp.cut))
    OR (kind = 'pr' AND NOT (SELECT prs_cut FROM temp.cut))
    OR (kind = 'issue' AND NOT (SELECT issues_cut FROM temp.cut)))
  AND NOT EXISTS (SELECT 1 FROM temp.b AS x WHERE x.kind = items.kind AND x.ref = items.ref);

INSERT INTO fetches (run_id, repo, login, fetched_at, branches, branches_total, prs, issues, issues_enabled,
                     branches_cut, prs_cut, issues_cut, ingested_at)
SELECT json_extract(i.j, '$.run_id'), r.repo, f.login, f.fetched_at,
       (SELECT count(*) FROM temp.b WHERE kind = 'branch'), (SELECT branches_total FROM temp.total),
       (SELECT count(*) FROM temp.b WHERE kind = 'pr'), (SELECT count(*) FROM temp.b WHERE kind = 'issue'),
       CASE WHEN f.issues_enabled THEN 1 ELSE 0 END, c.branches_cut, c.prs_cut, c.issues_cut,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input AS i, temp.r AS r, temp.f AS f, temp.cut AS c;

COMMIT;

SELECT repo, login, fetched_at, branches, branches_total, prs, issues, issues_enabled, branches_cut, prs_cut, issues_cut,
       (SELECT count(*) FROM items AS it WHERE it.repo = fe.repo AND it.state = 'gone' AND it.last_seen = fe.fetched_at) AS gone_now
FROM fetches AS fe WHERE id = (SELECT max(id) FROM fetches);
