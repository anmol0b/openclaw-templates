-- Ask the owner for one write to GitHub. Input: item_id, action (welcome or add-label), label (add-label only).
-- welcome: a comment on a PR or issue by a newcomer who was not welcomed in this repository yet, on an item the owner
--   has not commented on. Write the text to the body_file it names first (drafts/<owner>__<repo>-<number>.md).
--   The text never goes on a command line. One welcome per person per repository.
-- add-label: one of the repository's allowed labels (settings.md, through add-repo) that also exists in the repository,
--   on an issue from label-candidates.
-- This step builds the exact command. Never write a gh write command yourself: show the owner the exact_step it returns, word for word.
-- Refuses unless the item is still open and was fetched in the last 15 minutes.
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
SELECT i.*, 'drafts/' || replace(i.repo, '/', '__') || '-' || i.number || '.md' AS draft_path,
       r.allowed_labels, r.labels AS repo_labels
FROM items AS i JOIN repos AS r ON r.repo = i.repo
WHERE i.id = (SELECT json_extract(j, '$.item_id') FROM temp.input);
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT item_unknown_or_gone CHECK (ok = 1));
INSERT INTO temp.g1 SELECT count(*) = 1 AND min(state = 'open') FROM temp.it;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT fetch_again_first CHECK (ok = 1));
INSERT INTO temp.g2 SELECT min(last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')) FROM temp.it;

CREATE TEMP TABLE act (a TEXT CONSTRAINT unknown_action CHECK (a IN ('welcome', 'add-label')));
INSERT INTO temp.act SELECT json_extract(j, '$.action') FROM temp.input;
CREATE TEMP TABLE lab (l TEXT NOT NULL);
INSERT INTO temp.lab SELECT coalesce(json_extract(j, '$.label'), '') FROM temp.input;
CREATE TEMP TABLE g3 (ok INTEGER CONSTRAINT label_only_for_add_label CHECK (ok = 1));
INSERT INTO temp.g3 SELECT (a.a = 'add-label') = (l.l <> '') FROM temp.act AS a, temp.lab AS l;

-- welcome. A granted request that was never used (its item changed) does not block a new one; use-approval
-- makes sure only one welcome per person is ever used.
CREATE TEMP TABLE g4 (ok INTEGER CONSTRAINT author_not_a_newcomer CHECK (ok = 1));
INSERT INTO temp.g4 SELECT (SELECT a FROM temp.act) <> 'welcome' OR EXISTS (SELECT 1 FROM newcomers AS n WHERE n.id = t.id) FROM temp.it AS t;
CREATE TEMP TABLE g5 (ok INTEGER CONSTRAINT already_welcomed_in_this_repo CHECK (ok = 1));
INSERT INTO temp.g5 SELECT (SELECT a FROM temp.act) <> 'welcome'
  OR NOT EXISTS (SELECT 1 FROM welcomed AS w WHERE w.repo = t.repo AND lower(w.login) = lower(t.author)) FROM temp.it AS t;
CREATE TEMP TABLE g6 (ok INTEGER CONSTRAINT welcome_already_requested_for_this_person CHECK (ok = 1));
INSERT INTO temp.g6 SELECT (SELECT a FROM temp.act) <> 'welcome'
  OR NOT EXISTS (SELECT 1 FROM approvals AS a JOIN items AS i ON i.id = a.item_id
                 WHERE a.action = 'welcome' AND i.repo = t.repo AND lower(a.author) = lower(t.author)
                   AND (a.decision = 'pending' OR (a.used_at IS NOT NULL AND a.outcome IN ('', 'done')))) FROM temp.it AS t;
CREATE TEMP TABLE g7 (ok INTEGER CONSTRAINT owner_already_commented_here CHECK (ok = 1));
INSERT INTO temp.g7 SELECT (SELECT a FROM temp.act) <> 'welcome' OR owner_last_comment_at = '' FROM temp.it;
-- The draft file exists, is UTF-8 text, and is 1 to 3000 bytes.
CREATE TEMP TABLE body (b BLOB);
INSERT INTO temp.body SELECT readfile(draft_path) FROM temp.it WHERE (SELECT a FROM temp.act) = 'welcome';
CREATE TEMP TABLE g8 (ok INTEGER CONSTRAINT draft_missing_empty_or_too_long CHECK (ok = 1));
INSERT INTO temp.g8
SELECT CASE WHEN (SELECT a FROM temp.act) <> 'welcome' THEN 1
            ELSE coalesce((SELECT length(b) BETWEEN 1 AND 3000 AND length(trim(CAST(b AS TEXT), char(32, 9, 10, 13))) > 0 FROM temp.body), 0) END;

-- add-label
CREATE TEMP TABLE g9 (ok INTEGER CONSTRAINT action_not_for_this_kind CHECK (ok = 1));
INSERT INTO temp.g9 SELECT (SELECT a FROM temp.act) <> 'add-label' OR kind = 'issue' FROM temp.it;
CREATE TEMP TABLE g10 (ok INTEGER CONSTRAINT label_not_allowed CHECK (ok = 1));
INSERT INTO temp.g10 SELECT (SELECT a FROM temp.act) <> 'add-label'
  OR EXISTS (SELECT 1 FROM json_each(t.allowed_labels) AS e WHERE e.value = (SELECT l FROM temp.lab)) FROM temp.it AS t;
CREATE TEMP TABLE g11 (ok INTEGER CONSTRAINT label_not_in_repo CHECK (ok = 1));
INSERT INTO temp.g11 SELECT (SELECT a FROM temp.act) <> 'add-label'
  OR EXISTS (SELECT 1 FROM json_each(t.repo_labels) AS e WHERE e.value = (SELECT l FROM temp.lab)) FROM temp.it AS t;
CREATE TEMP TABLE g12 (ok INTEGER CONSTRAINT issue_already_has_label CHECK (ok = 1));
INSERT INTO temp.g12 SELECT (SELECT a FROM temp.act) <> 'add-label'
  OR NOT EXISTS (SELECT 1 FROM json_each(t.labels) AS e WHERE e.value = (SELECT l FROM temp.lab)) FROM temp.it AS t;
CREATE TEMP TABLE g13 (ok INTEGER CONSTRAINT issue_not_a_label_candidate CHECK (ok = 1));
INSERT INTO temp.g13 SELECT (SELECT a FROM temp.act) <> 'add-label' OR EXISTS (SELECT 1 FROM label_candidates AS c WHERE c.id = t.id) FROM temp.it AS t;

INSERT INTO approvals (item_id, action, label, author, body_file, body_sha3, exact_step, seen_updated_at, seen_owner_comment_at, asked_at)
SELECT t.id, a.a, l.l,
       CASE a.a WHEN 'welcome' THEN t.author ELSE '' END,
       CASE a.a WHEN 'welcome' THEN t.draft_path ELSE '' END,
       CASE a.a WHEN 'welcome' THEN (SELECT hex(sha3(b, 256)) FROM temp.body) ELSE '' END,
       CASE a.a
         WHEN 'welcome' THEN 'gh ' || t.kind || ' comment ' || t.number || ' --repo ' || t.repo || ' --body-file ' || t.draft_path
         WHEN 'add-label' THEN 'gh issue edit ' || t.number || ' --repo ' || t.repo || ' --add-label ''' || l.l || ''''
       END,
       t.updated_at, t.owner_last_comment_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.it AS t, temp.act AS a, temp.lab AS l
RETURNING id AS approval_id, action, label, author, exact_step, body_file, seen_updated_at;
