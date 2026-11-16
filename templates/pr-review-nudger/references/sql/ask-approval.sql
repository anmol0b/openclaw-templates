-- Ask the owner for one write to GitHub. Input: pr_id, action (request-review or comment), reviewer (request-review only).
-- This step builds the exact command. Never write a gh write command yourself: show the owner the exact_step it returns, word for word.
-- request-review: only for a PR waiting on review, and only a login from the fetched candidates (collaborators with push access,
--   CODEOWNERS users, maintainers who reviewed), never the PR author or someone already requested.
--   The command is `gh pr edit <n> --repo <repo> --add-reviewer <login>`.
-- comment: write the text to the body_file it names first (drafts/<owner>__<repo>-<number>.md). The text never goes on a command line.
--   One nudge comment per PR per nudge_days (from the latest run).
-- Refuses unless the PR is still open, stuck (not a draft and not ok), and was fetched in the last 15 minutes.
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

CREATE TEMP TABLE p AS
SELECT p.*, coalesce(w.category, 'gone') AS category,
       'drafts/' || replace(p.repo, '/', '__') || '-' || p.number || '.md' AS draft_path
FROM prs AS p LEFT JOIN pr_status AS w ON w.id = p.id
WHERE p.id = (SELECT json_extract(j, '$.pr_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT pr_unknown_or_gone CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(state = 'OPEN') FROM temp.p;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g2 SELECT min(last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')) FROM temp.p;
CREATE TEMP TABLE act (a TEXT CONSTRAINT unknown_action CHECK (a IN ('request-review', 'comment')));
INSERT INTO temp.act SELECT json_extract(j, '$.action') FROM temp.input;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT pr_is_a_draft_or_not_stuck CHECK (ok = 1));
INSERT INTO temp.g3 SELECT category IN ('waiting-on-review', 'waiting-on-author', 'merge-conflict') FROM temp.p;

-- request-review: the reviewer comes from the fetched candidates. The command uses the candidate's login as GitHub spelled it.
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT reviewer_only_for_request_review CHECK (ok = 1));
INSERT INTO temp.g4 SELECT ((SELECT a FROM temp.act) = 'request-review') = (coalesce(json_extract(j, '$.reviewer'), '') <> '') FROM temp.input;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT pr_not_waiting_on_review CHECK (ok = 1));
INSERT INTO temp.g5 SELECT (SELECT a FROM temp.act) <> 'request-review' OR category = 'waiting-on-review' FROM temp.p;
CREATE TEMP TABLE rv AS
SELECT DISTINCT c.login FROM candidates AS c, temp.p AS p, temp.input AS i
WHERE (SELECT a FROM temp.act) = 'request-review' AND c.repo = p.repo AND typeof(json_extract(i.j, '$.reviewer')) = 'text'
  AND lower(c.login) = lower(json_extract(i.j, '$.reviewer'));
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT reviewer_not_a_fetched_candidate CHECK (ok = 1));
INSERT INTO temp.g6 SELECT (SELECT a FROM temp.act) <> 'request-review' OR (SELECT count(*) FROM temp.rv) = 1;
CREATE TEMP TABLE g7 (ok INTEGER CONSTRAINT reviewer_is_the_author CHECK (ok = 1));
INSERT INTO temp.g7 SELECT NOT EXISTS (SELECT 1 FROM temp.rv AS r, temp.p AS p WHERE lower(r.login) = lower(p.author));
CREATE TEMP TABLE g8 (ok INTEGER CONSTRAINT reviewer_already_requested CHECK (ok = 1));
INSERT INTO temp.g8 SELECT NOT EXISTS (SELECT 1 FROM temp.rv AS r, temp.p AS p, json_each(p.requested_users) AS u
                                       WHERE lower(u.value) = lower(r.login));

-- comment: the draft file exists, is UTF-8 text, and is 1 to 3000 bytes; and no nudge went out on this PR within nudge_days.
CREATE TEMP TABLE body (b BLOB);
INSERT INTO temp.body SELECT readfile(draft_path) FROM temp.p WHERE (SELECT a FROM temp.act) = 'comment';
CREATE TEMP TABLE g9 (ok INTEGER CONSTRAINT draft_missing_empty_or_too_long CHECK (ok = 1));
INSERT INTO temp.g9
SELECT CASE WHEN (SELECT a FROM temp.act) <> 'comment' THEN 1
            ELSE coalesce((SELECT length(b) BETWEEN 1 AND 3000 AND length(trim(CAST(b AS TEXT), ' ' || char(9, 10, 13))) > 0 FROM temp.body), 0) END;
CREATE TEMP TABLE g10 (ok INTEGER CONSTRAINT nudged_within_window CHECK (ok = 1));
INSERT INTO temp.g10
SELECT (SELECT a FROM temp.act) <> 'comment' OR NOT EXISTS (
  SELECT 1 FROM approvals AS a, temp.p AS p
  WHERE a.pr_id = p.id AND a.action = 'comment' AND a.used_at IS NOT NULL
    AND a.used_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now',
          '-' || coalesce((SELECT nudge_days FROM runs ORDER BY id DESC LIMIT 1), 3) || ' days'));

INSERT INTO approvals (pr_id, action, reviewer, body_file, body_sha3, exact_step, seen_head_sha, seen_updated_at, seen_owner_comments, asked_at)
SELECT p.id, a.a, coalesce((SELECT login FROM temp.rv), ''),
       CASE a.a WHEN 'comment' THEN p.draft_path ELSE '' END,
       CASE a.a WHEN 'comment' THEN (SELECT hex(sha3(b, 256)) FROM temp.body) ELSE '' END,
       CASE a.a
         WHEN 'request-review' THEN 'gh pr edit ' || p.number || ' --repo ' || p.repo || ' --add-reviewer ' || (SELECT login FROM temp.rv)
         WHEN 'comment' THEN 'gh pr comment ' || p.number || ' --repo ' || p.repo || ' --body-file ' || p.draft_path
       END,
       p.head_sha, p.updated_at, p.owner_comments, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.p AS p, temp.act AS a
RETURNING id AS approval_id, action, reviewer, exact_step, body_file, seen_head_sha, seen_updated_at;
