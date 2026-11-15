-- Ask the owner for one write to GitHub. Input: pr_id, action (approve, comment, bot-command), bot_command (bot-command only: rebase or recreate).
-- This step builds the exact command. Never write a gh write command yourself: show the owner the exact_step it returns, word for word.
-- comment: write the text to the body_file it names first (drafts/<owner>__<repo>-<number>.md). The text never goes on a command line.
-- bot-command is only for Dependabot PRs and only posts the fixed comment "@dependabot rebase" or "@dependabot recreate".
-- approve needs a saved review for the current head with verdict looks-safe, and passing CI.
-- Refuses unless the PR is open and was fetched in the last 15 minutes, so the owner sees it as it is now.
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

CREATE TEMP TABLE pr AS
SELECT p.*, 'drafts/' || replace(p.repo, '/', '__') || '-' || p.number || '.md' AS draft_path,
       (SELECT r.verdict FROM reviews AS r WHERE r.pr_id = p.id AND r.head_sha = p.head_sha ORDER BY r.id DESC LIMIT 1) AS verdict
FROM prs AS p WHERE p.id = (SELECT json_extract(j, '$.pr_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT pr_unknown_or_gone CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(state = 'OPEN') FROM temp.pr;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g2 SELECT min(last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')) FROM temp.pr;

CREATE TEMP TABLE act (a TEXT CONSTRAINT unknown_action CHECK (a IN ('approve', 'comment', 'bot-command')));
INSERT INTO temp.act SELECT json_extract(j, '$.action') FROM temp.input;

CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT approve_needs_a_looks_safe_review_of_this_head CHECK (ok = 1));
INSERT INTO temp.g3 SELECT (SELECT a FROM temp.act) <> 'approve' OR coalesce((SELECT verdict = 'looks-safe' FROM temp.pr), 0);
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT ci_not_passing CHECK (ok = 1));
INSERT INTO temp.g4 SELECT (SELECT a FROM temp.act) <> 'approve' OR coalesce((SELECT ci = 'passing' FROM temp.pr), 0);

-- Bot commands: a fixed list, for Dependabot only.
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT bot_command_not_allowed CHECK (ok = 1));
INSERT INTO temp.g5
SELECT CASE WHEN (SELECT a FROM temp.act) = 'bot-command'
            THEN coalesce(json_extract(j, '$.bot_command'), '') IN ('rebase', 'recreate') AND (SELECT bot FROM temp.pr) = 'dependabot'
            ELSE coalesce(json_extract(j, '$.bot_command'), '') = '' END
FROM temp.input;

-- Comment: the draft file exists, is text, and is 1 to 6000 bytes.
CREATE TEMP TABLE body (b BLOB);
INSERT INTO temp.body SELECT readfile(draft_path) FROM temp.pr WHERE (SELECT a FROM temp.act) = 'comment';
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT draft_missing_empty_or_too_long CHECK (ok = 1));
INSERT INTO temp.g6
SELECT CASE WHEN (SELECT a FROM temp.act) <> 'comment' THEN 1
            ELSE coalesce((SELECT length(b) BETWEEN 1 AND 6000 AND length(trim(CAST(b AS TEXT))) > 0 FROM temp.body), 0) END;

INSERT INTO approvals (pr_id, action, bot_command, body_file, body_sha3, exact_step, seen_head_sha, seen_updated_at, asked_at)
SELECT p.id, a.a,
       CASE a.a WHEN 'bot-command' THEN json_extract(i.j, '$.bot_command') ELSE '' END,
       CASE a.a WHEN 'comment' THEN p.draft_path ELSE '' END,
       CASE a.a WHEN 'comment' THEN (SELECT hex(sha3(b, 256)) FROM temp.body) ELSE '' END,
       CASE a.a
         WHEN 'approve' THEN 'gh pr review ' || p.number || ' --repo ' || p.repo || ' --approve'
         WHEN 'comment' THEN 'gh pr comment ' || p.number || ' --repo ' || p.repo || ' --body-file ' || p.draft_path
         WHEN 'bot-command' THEN 'gh pr comment ' || p.number || ' --repo ' || p.repo || ' --body ''@dependabot ' || json_extract(i.j, '$.bot_command') || ''''
       END,
       p.head_sha, p.updated_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.pr AS p, temp.act AS a, temp.input AS i
RETURNING id AS approval_id, action, exact_step, body_file, seen_head_sha;
