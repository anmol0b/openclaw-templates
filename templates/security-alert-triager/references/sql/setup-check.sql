-- Setup check. No input. Read only. Shows that sqlite3 has what the steps need, the database is version 1,
-- and, once a repository was fetched, that this gh login can read its alerts.
-- Refuses with token_lacks_alert_access when the latest fetch of any repository could not read
-- Dependabot or code scanning alerts for lack of access (not when the feature is turned off).
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/setup-check.sql"
.bail on
CREATE TEMP TABLE version_guard (ok INTEGER CONSTRAINT sqlite_older_than_3_38 CHECK (ok = 1));
INSERT INTO temp.version_guard
SELECT (CAST(substr(v, 1, instr(v, '.') - 1) AS INTEGER) * 1000 + CAST(substr(v, instr(v, '.') + 1, instr(substr(v, instr(v, '.') + 1), '.') - 1) AS INTEGER)) >= 3038
FROM (SELECT sqlite_version() AS v);
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE sha3_guard (ok INTEGER CONSTRAINT sqlite_without_sha3 CHECK (ok = 1));
INSERT INTO temp.sha3_guard SELECT length(sha3('check', 256)) = 32;

CREATE TEMP TABLE latest AS
SELECT f.* FROM fetches AS f WHERE f.id = (SELECT max(id) FROM fetches AS g WHERE g.repo = f.repo);
CREATE TEMP TABLE access_guard (ok INTEGER CONSTRAINT token_lacks_alert_access CHECK (ok = 1));
INSERT INTO temp.access_guard
SELECT NOT EXISTS (SELECT 1 FROM temp.latest WHERE dependabot_status = 'no_access' OR code_scanning_status = 'no_access');

SELECT sqlite_version() AS sqlite_version,
       (SELECT user_version FROM pragma_user_version) AS schema_version,
       (SELECT count(*) FROM repos) AS repos,
       (SELECT count(*) FROM temp.latest) AS repos_fetched,
       (SELECT json_group_array(json_object('repo', repo, 'dependabot', dependabot_status, 'code_scanning', code_scanning_status)) FROM temp.latest) AS access,
       (SELECT count(*) FROM alerts WHERE state = 'open') AS open_alerts,
       (SELECT count(*) FROM approvals WHERE decision = 'pending') AS open_requests,
       'ok' AS result;
