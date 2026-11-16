-- Ingest the files fetch.mjs wrote for one repository: open and recently dismissed Dependabot and code scanning
-- alerts, and whether each source could be read. Input: repo, run_id (or null outside a run).
-- An open alert that a complete read no longer has, and that is not in the dismissed read, is marked closed.
-- A source that is disabled or not readable, or a read that returned its full limit, marks nothing closed.
-- Returns one row with each source's status and counts.
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
       json_extract(s, '$.fetched_at') AS fetched_at,
       json_extract(s, '$.dependabot.status') AS dep_status,
       coalesce(json_extract(s, '$.dependabot.message'), '') AS dep_message,
       json_extract(s, '$.code_scanning.status') AS cs_status,
       coalesce(json_extract(s, '$.code_scanning.message'), '') AS cs_message,
       coalesce(json_extract(s, '$.prs'), 0) AS prs,
       json_extract(s, '$.limits.open') AS open_limit
FROM (SELECT CAST(readfile((SELECT dir FROM temp.r) || 'fetch.json') AS TEXT) AS s) WHERE json_valid(s);
CREATE TEMP TABLE g_fetch (ok INTEGER CONSTRAINT fetch_missing_or_for_another_repo CHECK (ok = 1));
INSERT INTO temp.g_fetch
SELECT coalesce(count(*) = 1 AND min(f.repo = r.repo)
                AND min(f.fetched_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
                AND min(f.dep_status IN ('ok', 'disabled', 'no_access')) AND min(f.cs_status IN ('ok', 'disabled', 'no_access'))
                AND min(f.open_limit > 0), 0)
FROM temp.f AS f, temp.r AS r;

CREATE TEMP TABLE src (source TEXT NOT NULL, doc TEXT NOT NULL CONSTRAINT inbox_file_not_a_list CHECK (json_valid(doc) AND json_type(doc) = 'array'));
INSERT INTO temp.src SELECT 'dependabot', coalesce(CAST(readfile(dir || 'dependabot.json') AS TEXT), 'x') FROM temp.r;
INSERT INTO temp.src SELECT 'code-scanning', coalesce(CAST(readfile(dir || 'code-scanning.json') AS TEXT), 'x') FROM temp.r;
-- A source that could not be read must come with an empty file.
CREATE TEMP TABLE g_empty (ok INTEGER CONSTRAINT alerts_for_a_source_not_read CHECK (ok = 1));
INSERT INTO temp.g_empty
SELECT (f.dep_status = 'ok' OR (SELECT json_array_length(doc) FROM temp.src WHERE source = 'dependabot') = 0)
   AND (f.cs_status = 'ok' OR (SELECT json_array_length(doc) FROM temp.src WHERE source = 'code-scanning') = 0)
FROM temp.f AS f;

-- Every row is checked here, at the trust boundary. A bad row stops the whole step.
CREATE TEMP TABLE b (
  source TEXT NOT NULL,
  number INTEGER,
  number_type TEXT NOT NULL CONSTRAINT number_not_integer CHECK (number_type = 'integer'),
  state TEXT NOT NULL CONSTRAINT alert_state_not_open_or_dismissed CHECK (state IN ('open', 'dismissed')),
  severity TEXT NOT NULL,
  created_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  updated_at TEXT NOT NULL CONSTRAINT time_not_iso_utc CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
  html_url TEXT NOT NULL,
  ecosystem TEXT NOT NULL,
  package TEXT NOT NULL,
  manifest_path TEXT NOT NULL,
  scope TEXT NOT NULL,
  ghsa_id TEXT NOT NULL,
  cve_id TEXT NOT NULL,
  summary TEXT NOT NULL,
  vulnerable_range TEXT NOT NULL,
  patched_version TEXT NOT NULL,
  covering_pr INTEGER,
  covering_type TEXT NOT NULL CONSTRAINT covering_pr_not_integer CHECK (covering_type IN ('integer', 'null')),
  covering_fixes TEXT NOT NULL CONSTRAINT covering_fixes_unknown CHECK (covering_fixes IN ('', 'yes', 'unknown', 'no')),
  rule_id TEXT NOT NULL,
  rule_severity TEXT NOT NULL,
  rule_description TEXT NOT NULL,
  tool TEXT NOT NULL,
  path TEXT NOT NULL,
  start_line INTEGER,
  line_type TEXT NOT NULL CONSTRAINT start_line_not_integer CHECK (line_type IN ('integer', 'null')),
  dismissed_reason TEXT NOT NULL,
  CONSTRAINT alert_without_package_or_rule CHECK ((source = 'dependabot' AND length(package) > 0) OR (source = 'code-scanning' AND length(rule_id) > 0)),
  UNIQUE (source, number)
);

-- Severity: GitHub's four levels. "moderate" (the advisory database's word) is medium; anything else is unrated.
INSERT INTO temp.b
SELECT s.source, json_extract(e.value, '$.number'), coalesce(json_type(e.value, '$.number'), 'missing'),
       coalesce(json_extract(e.value, '$.state'), ''),
       CASE lower(coalesce(json_extract(e.value, '$.severity'), ''))
         WHEN 'critical' THEN 'critical' WHEN 'high' THEN 'high' WHEN 'medium' THEN 'medium' WHEN 'moderate' THEN 'medium'
         WHEN 'low' THEN 'low' ELSE 'unrated' END,
       coalesce(json_extract(e.value, '$.created_at'), ''), coalesce(json_extract(e.value, '$.updated_at'), ''),
       substr(coalesce(json_extract(e.value, '$.html_url'), ''), 1, 300),
       substr(coalesce(json_extract(e.value, '$.ecosystem'), ''), 1, 30),
       substr(coalesce(json_extract(e.value, '$.package'), ''), 1, 214),
       substr(coalesce(json_extract(e.value, '$.manifest_path'), ''), 1, 300),
       substr(coalesce(json_extract(e.value, '$.scope'), ''), 1, 20),
       substr(coalesce(json_extract(e.value, '$.ghsa_id'), ''), 1, 40),
       substr(coalesce(json_extract(e.value, '$.cve_id'), ''), 1, 40),
       substr(coalesce(json_extract(e.value, '$.summary'), ''), 1, 200),
       substr(coalesce(json_extract(e.value, '$.vulnerable_range'), ''), 1, 100),
       substr(coalesce(json_extract(e.value, '$.patched_version'), ''), 1, 64),
       json_extract(e.value, '$.covering_pr'), coalesce(json_type(e.value, '$.covering_pr'), 'null'),
       coalesce(json_extract(e.value, '$.covering_fixes'), ''),
       substr(coalesce(json_extract(e.value, '$.rule_id'), ''), 1, 200),
       substr(coalesce(json_extract(e.value, '$.rule_severity'), ''), 1, 20),
       substr(coalesce(json_extract(e.value, '$.rule_description'), ''), 1, 200),
       substr(coalesce(json_extract(e.value, '$.tool'), ''), 1, 60),
       substr(coalesce(json_extract(e.value, '$.path'), ''), 1, 300),
       json_extract(e.value, '$.start_line'), coalesce(json_type(e.value, '$.start_line'), 'null'),
       substr(coalesce(json_extract(e.value, '$.dismissed_reason'), ''), 1, 40)
FROM temp.src AS s, json_each(s.doc) AS e;

-- A read of open alerts that returned its full limit may have left some out.
CREATE TEMP TABLE cut AS
SELECT f.dep_status = 'ok' AND (SELECT count(*) FROM temp.b WHERE source = 'dependabot' AND state = 'open') >= f.open_limit AS dep_cut,
       f.cs_status = 'ok' AND (SELECT count(*) FROM temp.b WHERE source = 'code-scanning' AND state = 'open') >= f.open_limit AS cs_cut
FROM temp.f AS f;

BEGIN;

INSERT INTO alerts (repo, source, number, state, severity, created_at, updated_at, html_url, ecosystem, package, manifest_path,
                    scope, ghsa_id, cve_id, summary, vulnerable_range, patched_version, covering_pr, covering_fixes,
                    rule_id, rule_severity, rule_description, tool, path, start_line, dismissed_reason, first_seen, last_seen)
SELECT r.repo, x.source, x.number, x.state, x.severity, x.created_at, x.updated_at, x.html_url, x.ecosystem, x.package,
       x.manifest_path, x.scope, x.ghsa_id, x.cve_id, x.summary, x.vulnerable_range, x.patched_version, x.covering_pr,
       x.covering_fixes, x.rule_id, x.rule_severity, x.rule_description, x.tool, x.path, x.start_line, x.dismissed_reason,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), f.fetched_at
FROM temp.b AS x, temp.r AS r, temp.f AS f WHERE true
ON CONFLICT (repo, source, number) DO UPDATE SET
  state = excluded.state, severity = excluded.severity, created_at = excluded.created_at, updated_at = excluded.updated_at,
  html_url = excluded.html_url, ecosystem = excluded.ecosystem, package = excluded.package,
  manifest_path = excluded.manifest_path, scope = excluded.scope, ghsa_id = excluded.ghsa_id, cve_id = excluded.cve_id,
  summary = excluded.summary, vulnerable_range = excluded.vulnerable_range, patched_version = excluded.patched_version,
  covering_pr = excluded.covering_pr, covering_fixes = excluded.covering_fixes, rule_id = excluded.rule_id,
  rule_severity = excluded.rule_severity, rule_description = excluded.rule_description, tool = excluded.tool,
  path = excluded.path, start_line = excluded.start_line, dismissed_reason = excluded.dismissed_reason,
  last_seen = excluded.last_seen;

-- Closed: only for a source that was read in full.
UPDATE alerts SET state = 'closed', last_seen = (SELECT fetched_at FROM temp.f)
WHERE repo = (SELECT repo FROM temp.r) AND state = 'open'
  AND ((source = 'dependabot' AND (SELECT dep_status = 'ok' AND NOT dep_cut FROM temp.f, temp.cut))
    OR (source = 'code-scanning' AND (SELECT cs_status = 'ok' AND NOT cs_cut FROM temp.f, temp.cut)))
  AND NOT EXISTS (SELECT 1 FROM temp.b AS x WHERE x.source = alerts.source AND x.number = alerts.number);

INSERT INTO fetches (run_id, repo, fetched_at, dependabot_status, dependabot_message, dependabot_open, dependabot_cut,
                     code_scanning_status, code_scanning_message, code_scanning_open, code_scanning_cut, prs, ingested_at)
SELECT json_extract(i.j, '$.run_id'), r.repo, f.fetched_at,
       f.dep_status, substr(f.dep_message, 1, 200), (SELECT count(*) FROM temp.b WHERE source = 'dependabot' AND state = 'open'), c.dep_cut,
       f.cs_status, substr(f.cs_message, 1, 200), (SELECT count(*) FROM temp.b WHERE source = 'code-scanning' AND state = 'open'), c.cs_cut,
       f.prs, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.input AS i, temp.r AS r, temp.f AS f, temp.cut AS c;

COMMIT;

SELECT repo, fetched_at, dependabot_status, dependabot_open, dependabot_cut, code_scanning_status, code_scanning_open,
       code_scanning_cut, prs,
       (SELECT count(*) FROM alerts AS a WHERE a.repo = fe.repo AND a.state = 'closed' AND a.last_seen = fe.fetched_at) AS closed_now
FROM fetches AS fe WHERE id = (SELECT max(id) FROM fetches);
