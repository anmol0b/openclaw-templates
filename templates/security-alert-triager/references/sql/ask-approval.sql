-- Ask the owner for one write to GitHub. Input: alert_id, action (dismiss or issue), reason (dismiss only),
-- with_comment (dismiss only, true to send the draft as the dismissal comment).
-- This step builds the exact command. Never write a gh write command yourself: show the owner the exact_step it returns, word for word.
-- dismiss: reason is one of GitHub's fixed reasons for that source.
--   Dependabot: fix_started, inaccurate, no_bandwidth, not_used, tolerable_risk.
--   Code scanning: false positive, won't fix, used in tests.
--   with_comment: write the comment to the body_file it names first (drafts/<owner>__<repo>-<source>-<number>.md,
--   1 to 280 bytes). The text never goes on a command line; gh reads the file (-F field=@file).
-- issue: Dependabot alerts only. The title and body are built here from the GHSA ID, ecosystem, package, severity and
--   patched version, nothing else: no draft and no advisory text. Code scanning alerts never get an issue, because they
--   name a file and line in the owner's code and a public issue would point at an unfixed hole.
-- Refuses unless the alert is open and was fetched in the last 15 minutes.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/ask-approval.sql"
-- Input: write db-input.json with the write tool first, with "step": "ask-approval".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'ask-approval'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE al AS
SELECT a.*, 'drafts/' || replace(a.repo, '/', '__') || '-' || a.source || '-' || a.number || '.md' AS draft_path
FROM alerts AS a WHERE a.id = (SELECT json_extract(j, '$.alert_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT alert_unknown_or_not_open CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(state = 'open') FROM temp.al;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g2 SELECT min(last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')) FROM temp.al;

CREATE TEMP TABLE act (a TEXT CONSTRAINT unknown_action CHECK (a IN ('dismiss', 'issue')));
INSERT INTO temp.act SELECT json_extract(j, '$.action') FROM temp.input;
CREATE TEMP TABLE rsn AS SELECT coalesce(json_extract(j, '$.reason'), '') AS r,
       coalesce(json_extract(j, '$.with_comment'), 0) AS c FROM temp.input;

CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT dismiss_reason_not_in_githubs_list CHECK (ok = 1));
INSERT INTO temp.g3
SELECT (SELECT a FROM temp.act) <> 'dismiss' OR CASE l.source
         WHEN 'dependabot' THEN x.r IN ('fix_started', 'inaccurate', 'no_bandwidth', 'not_used', 'tolerable_risk')
         ELSE x.r IN ('false positive', 'won''t fix', 'used in tests') END
FROM temp.al AS l, temp.rsn AS x;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT reason_and_comment_only_with_dismiss CHECK (ok = 1));
INSERT INTO temp.g4 SELECT (SELECT a FROM temp.act) = 'dismiss' OR (r = '' AND c = 0) FROM temp.rsn;

-- issue: Dependabot only, once per alert, from values that are safe inside single quotes.
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT no_issues_for_code_scanning_alerts CHECK (ok = 1));
INSERT INTO temp.g5 SELECT (SELECT a FROM temp.act) <> 'issue' OR source = 'dependabot' FROM temp.al;
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT tracking_issue_already_opened CHECK (ok = 1));
INSERT INTO temp.g6 SELECT (SELECT a FROM temp.act) <> 'issue'
       OR NOT EXISTS (SELECT 1 FROM approvals AS p WHERE p.alert_id = (SELECT id FROM temp.al) AND p.action = 'issue' AND p.outcome = 'done');
CREATE TEMP TABLE g7 (ok INTEGER CONSTRAINT alert_fields_unsafe_for_a_command CHECK (ok = 1));
INSERT INTO temp.g7 SELECT (SELECT a FROM temp.act) <> 'issue' OR (
  ghsa_id GLOB 'GHSA-[a-z0-9][a-z0-9][a-z0-9][a-z0-9]-[a-z0-9][a-z0-9][a-z0-9][a-z0-9]-[a-z0-9][a-z0-9][a-z0-9][a-z0-9]'
  AND length(ecosystem) BETWEEN 1 AND 30 AND ecosystem NOT GLOB '*[^a-z_]*'
  AND length(package) BETWEEN 1 AND 214 AND package NOT GLOB '*[^A-Za-z0-9@/._:~+-]*'
  AND patched_version NOT GLOB '*[^A-Za-z0-9._+-]*')
FROM temp.al;

-- with_comment: the draft file exists, is text, and is 1 to 280 bytes (GitHub's limit for a dismissal comment).
CREATE TEMP TABLE body (b BLOB);
INSERT INTO temp.body SELECT readfile(draft_path) FROM temp.al WHERE (SELECT c FROM temp.rsn) = 1 AND (SELECT a FROM temp.act) = 'dismiss';
CREATE TEMP TABLE g8 (ok INTEGER CONSTRAINT draft_missing_empty_or_too_long CHECK (ok = 1));
INSERT INTO temp.g8
SELECT CASE WHEN (SELECT c FROM temp.rsn) <> 1 OR (SELECT a FROM temp.act) <> 'dismiss' THEN 1
            ELSE coalesce((SELECT length(b) BETWEEN 1 AND 280 AND length(trim(CAST(b AS TEXT))) > 0 FROM temp.body), 0) END;

INSERT INTO approvals (alert_id, action, reason, body_file, body_sha3, exact_step, seen_updated_at, asked_at)
SELECT l.id, a.a, x.r,
       CASE WHEN x.c = 1 THEN l.draft_path ELSE '' END,
       CASE WHEN x.c = 1 THEN (SELECT hex(sha3(b, 256)) FROM temp.body) ELSE '' END,
       CASE
         WHEN a.a = 'dismiss' AND l.source = 'dependabot' THEN
           'gh api -X PATCH repos/' || l.repo || '/dependabot/alerts/' || l.number || ' -f state=dismissed -f dismissed_reason=' || x.r
           || CASE WHEN x.c = 1 THEN ' -F dismissed_comment=@' || l.draft_path ELSE '' END
         WHEN a.a = 'dismiss' THEN
           'gh api -X PATCH repos/' || l.repo || '/code-scanning/alerts/' || l.number || ' -f state=dismissed -f "dismissed_reason=' || x.r || '"'
           || CASE WHEN x.c = 1 THEN ' -F dismissed_comment=@' || l.draft_path ELSE '' END
         ELSE
           'gh issue create --repo ' || l.repo
           || ' --title ''Security: ' || l.ghsa_id || ' in ' || l.ecosystem || ' package ' || l.package || ' (' || l.severity || ')'''
           || ' --body ''Dependabot alert ' || l.number || ' in this repository: ' || l.ghsa_id || ', ' || l.ecosystem || ' package '
           || l.package || ', severity ' || l.severity || ', '
           || CASE WHEN l.patched_version = '' THEN 'no patched version yet' ELSE 'patched in ' || l.patched_version END
           || '. Details, for people with access to security alerts: https://github.com/' || l.repo || '/security/dependabot/' || l.number || ''''
       END,
       l.updated_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.al AS l, temp.act AS a, temp.rsn AS x
RETURNING id AS approval_id, action, reason, exact_step, body_file, seen_updated_at;
