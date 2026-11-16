-- The digest data for one run, as one JSON object: fetches (with partial reads), stuck PRs by category, open requests,
-- and the writes done in this run. Input: run_id. Read only. Write the digest from this result and templates/digest.md; never from memory.
-- Run from the workspace root:
--   sqlite3 -bail <db_path> ".read references/sql/digest.sql"
-- No -json flag here: the step prints one JSON object as it is.
-- Input: write db-input.json with the write tool first, with "step": "digest".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'digest'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE run AS SELECT * FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input);
CREATE TEMP TABLE g_run (n INTEGER CONSTRAINT unknown_run CHECK (n = 1));
INSERT INTO temp.g_run SELECT count(*) FROM temp.run;

CREATE TEMP TABLE stuck AS
SELECT w.* FROM pr_status AS w, temp.run AS r
WHERE w.category IN ('waiting-on-review', 'waiting-on-author', 'merge-conflict')
  AND NOT (r.skip_bot_prs = 1 AND w.author_is_bot = 1)
  AND w.days_waiting >= CASE w.category WHEN 'waiting-on-review' THEN r.review_days
                                        WHEN 'waiting-on-author' THEN r.author_days ELSE r.conflict_days END;

SELECT json_object(
  'run', (SELECT json_object('run_id', id, 'kind', kind, 'review_days', review_days, 'author_days', author_days,
                             'conflict_days', conflict_days, 'nudge_days', nudge_days, 'skip_bot_prs', skip_bot_prs,
                             'started_at', started_at, 'ended_at', ended_at, 'note', note) FROM temp.run),
  'fetches', (SELECT json_group_array(json_object('repo', repo, 'login', login, 'prs', prs, 'prs_cut', prs_cut,
                     'collaborators_readable', collaborators_readable, 'collaborators_cut', collaborators_cut,
                     'codeowners_path', codeowners_path, 'candidates', candidates))
              FROM fetches WHERE run_id = (SELECT id FROM temp.run)),
  'stuck', (SELECT json_group_array(json_object('pr_id', id, 'repo', repo, 'number', number, 'title', title, 'url', url,
                   'author', author, 'category', category, 'days_waiting', days_waiting,
                   'requested_users', json(requested_users), 'requested_teams', requested_teams))
            FROM (SELECT * FROM temp.stuck
                  ORDER BY CASE category WHEN 'waiting-on-review' THEN 1 WHEN 'merge-conflict' THEN 2 ELSE 3 END, days_waiting DESC, id
                  LIMIT 50)),
  'stuck_total', (SELECT count(*) FROM temp.stuck),
  'by_category', (SELECT json_object(
                    'waiting-on-review', (SELECT count(*) FROM temp.stuck WHERE category = 'waiting-on-review'),
                    'waiting-on-author', (SELECT count(*) FROM temp.stuck WHERE category = 'waiting-on-author'),
                    'merge-conflict', (SELECT count(*) FROM temp.stuck WHERE category = 'merge-conflict'))),
  'open_requests', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', p.repo, 'number', p.number,
                           'action', a.action, 'reviewer', a.reviewer, 'exact_step', a.exact_step, 'body_file', a.body_file,
                           'decision', a.decision, 'asked_at', a.asked_at,
                           'pr_changed', p.state <> 'OPEN' OR p.head_sha <> a.seen_head_sha OR p.updated_at <> a.seen_updated_at))
                    FROM (SELECT * FROM approvals WHERE decision = 'pending' OR (decision = 'granted' AND used_at IS NULL) ORDER BY id) AS a
                    JOIN prs AS p ON p.id = a.pr_id),
  'done', (SELECT json_group_array(json_object('repo', p.repo, 'number', p.number, 'action', a.action, 'reviewer', a.reviewer,
                  'outcome', a.outcome, 'outcome_note', a.outcome_note))
           FROM approvals AS a JOIN prs AS p ON p.id = a.pr_id
           WHERE a.outcome <> '' AND a.outcome_at >= (SELECT started_at FROM temp.run))
);
