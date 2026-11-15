-- Ask the owner for one write to GitHub. Input: item_id, action, close_reason (close on an issue: completed or not planned).
-- Actions by kind: branch: delete-branch. pr: comment, close. issue: comment, close, unassign.
-- This step builds the exact command. Never write a gh write command yourself: show the owner the exact_step it returns, word for word.
-- delete-branch: only a merged branch (category merged-branch) with a plain name; the command is `gh api -X DELETE .../git/refs/heads/<branch>`.
-- comment: write the text to the body_file it names first (drafts/<owner>__<repo>-<number>.md). The text never goes on a command line.
-- Refuses unless the item is the owner's, still open, and was fetched in the last 15 minutes.
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

CREATE TEMP TABLE it AS
SELECT i.*, w.category,
       'drafts/' || replace(i.repo, '/', '__') || '-' || coalesce(i.number, 0) || '.md' AS draft_path,
       CASE i.kind WHEN 'issue' THEN 'issue' WHEN 'pr' THEN 'pr' ELSE '' END AS cli
FROM items AS i LEFT JOIN owners_work AS w ON w.id = i.id
WHERE i.id = (SELECT json_extract(j, '$.item_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT item_unknown_or_gone CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(state = 'open') FROM temp.it;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT not_the_owners_item CHECK (ok = 1));
INSERT INTO temp.g2 SELECT min(is_owners = 1) FROM temp.it;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g3 SELECT min(last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')) FROM temp.it;

CREATE TEMP TABLE act (a TEXT CONSTRAINT unknown_action CHECK (a IN ('delete-branch', 'comment', 'close', 'unassign')));
INSERT INTO temp.act SELECT json_extract(j, '$.action') FROM temp.input;
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT action_not_for_this_kind CHECK (ok = 1));
INSERT INTO temp.g4 SELECT CASE t.kind
  WHEN 'branch' THEN a.a = 'delete-branch'
  WHEN 'pr' THEN a.a IN ('comment', 'close')
  ELSE a.a IN ('comment', 'close', 'unassign') END
FROM temp.it AS t, temp.act AS a;

-- delete-branch: merged, no open PR, not protected, not the default branch (owners_work category), and a plain name:
-- letters, digits, dot, dash, underscore and slash, no "..", "//", "@{", no part starting with "." or "-", not ending in "/", "." or ".lock".
CREATE TEMP TABLE g5a (ok INTEGER CONSTRAINT branch_is_default_or_protected CHECK (ok = 1));
INSERT INTO temp.g5a SELECT (SELECT a FROM temp.act) <> 'delete-branch' OR (is_default = 0 AND is_protected = 0) FROM temp.it;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT branch_not_merged_or_has_open_pr CHECK (ok = 1));
INSERT INTO temp.g5 SELECT (SELECT a FROM temp.act) <> 'delete-branch' OR coalesce(category = 'merged-branch', 0) FROM temp.it;
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT branch_name_unsafe CHECK (ok = 1));
INSERT INTO temp.g6 SELECT (SELECT a FROM temp.act) <> 'delete-branch' OR (
  length(ref) BETWEEN 1 AND 200
  AND ref NOT GLOB '*[^A-Za-z0-9._/-]*'
  AND ref NOT GLOB '*..*' AND ref NOT GLOB '*//*'
  AND ref NOT GLOB '[./-]*' AND ref NOT GLOB '*/[.-]*'
  AND ref NOT GLOB '*/' AND ref NOT GLOB '*.' AND ref NOT GLOB '*.lock')
FROM temp.it;

-- close: an issue needs completed or not planned; a PR and other actions take none.
CREATE TEMP TABLE g7 (ok INTEGER CONSTRAINT close_reason_not_allowed CHECK (ok = 1));
INSERT INTO temp.g7
SELECT CASE WHEN (SELECT a FROM temp.act) = 'close' AND (SELECT kind FROM temp.it) = 'issue'
            THEN coalesce(json_extract(j, '$.close_reason'), '') IN ('completed', 'not planned')
            ELSE coalesce(json_extract(j, '$.close_reason'), '') = '' END
FROM temp.input;

-- comment: the draft file exists, is UTF-8 text, and is 1 to 6000 bytes.
CREATE TEMP TABLE body (b BLOB);
INSERT INTO temp.body SELECT readfile(draft_path) FROM temp.it WHERE (SELECT a FROM temp.act) = 'comment';
CREATE TEMP TABLE g8 (ok INTEGER CONSTRAINT draft_missing_empty_or_too_long CHECK (ok = 1));
INSERT INTO temp.g8
SELECT CASE WHEN (SELECT a FROM temp.act) <> 'comment' THEN 1
            ELSE coalesce((SELECT length(b) BETWEEN 1 AND 6000 AND length(trim(CAST(b AS TEXT))) > 0 FROM temp.body), 0) END;

INSERT INTO approvals (item_id, action, close_reason, body_file, body_sha3, exact_step, seen_head_oid, seen_last_activity, asked_at)
SELECT t.id, a.a, coalesce(json_extract(i.j, '$.close_reason'), ''),
       CASE a.a WHEN 'comment' THEN t.draft_path ELSE '' END,
       CASE a.a WHEN 'comment' THEN (SELECT hex(sha3(b, 256)) FROM temp.body) ELSE '' END,
       CASE a.a
         WHEN 'delete-branch' THEN 'gh api -X DELETE repos/' || t.repo || '/git/refs/heads/' || t.ref
         WHEN 'comment' THEN 'gh ' || t.cli || ' comment ' || t.number || ' --repo ' || t.repo || ' --body-file ' || t.draft_path
         WHEN 'close' THEN 'gh ' || t.cli || ' close ' || t.number || ' --repo ' || t.repo ||
              CASE WHEN t.kind = 'issue' THEN ' --reason ''' || json_extract(i.j, '$.close_reason') || '''' ELSE '' END
         WHEN 'unassign' THEN 'gh issue edit ' || t.number || ' --repo ' || t.repo || ' --remove-assignee @me'
       END,
       t.head_oid, t.last_activity, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.it AS t, temp.act AS a, temp.input AS i
RETURNING id AS approval_id, action, exact_step, body_file, seen_head_oid, seen_last_activity;
