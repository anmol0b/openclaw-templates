-- Setup check. No input. Read only. Shows that sqlite3 has what the steps need and the database is version 1.
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

SELECT sqlite_version() AS sqlite_version,
       (SELECT user_version FROM pragma_user_version) AS schema_version,
       (SELECT count(*) FROM repos) AS repos,
       (SELECT count(*) FROM prs WHERE state = 'OPEN') AS open_prs,
       (SELECT count(*) FROM approvals WHERE decision = 'pending') AS open_requests,
       'ok' AS result;
