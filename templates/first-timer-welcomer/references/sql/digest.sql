-- The digest data for one run, as one JSON object: fetches (with partial reads), newcomers waiting for a welcome,
-- label candidates, open requests, and people welcomed and labels added since the run started.
-- Input: run_id. Read only. Write the digest from this result and templates/digest.md; never from memory.
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
CREATE TEMP TABLE recent AS
SELECT * FROM newcomers WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (SELECT recent_days FROM temp.run) || ' days');

SELECT json_object(
  'run', (SELECT json_object('run_id', id, 'kind', kind, 'recent_days', recent_days, 'started_at', started_at,
                             'ended_at', ended_at, 'note', note) FROM temp.run),
  'fetches', (SELECT json_group_array(json_object('repo', repo, 'login', login, 'prs', prs, 'prs_total', prs_total,
                     'issues', issues, 'issues_total', issues_total, 'labels', labels, 'issues_enabled', issues_enabled,
                     'prs_cut', prs_cut, 'issues_cut', issues_cut, 'labels_cut', labels_cut))
              FROM fetches WHERE run_id = (SELECT id FROM temp.run)),
  'waiting', (SELECT json_group_array(json_object('item_id', id, 'repo', repo, 'kind', kind, 'number', number, 'title', title,
                     'url', url, 'author', author, 'association', association, 'days_open', days_open, 'is_draft', is_draft))
              FROM (SELECT * FROM temp.recent WHERE waiting ORDER BY created_at, id LIMIT 30)),
  'waiting_total', (SELECT count(*) FROM temp.recent WHERE waiting),
  'newcomers_total', (SELECT count(*) FROM temp.recent),
  'label_candidates', (SELECT json_group_array(json_object('item_id', id, 'repo', repo, 'number', number, 'title', title,
                              'url', url, 'labels', json(labels)))
                       FROM (SELECT * FROM label_candidates ORDER BY created_at, id LIMIT 20)),
  'label_candidates_total', (SELECT count(*) FROM label_candidates),
  'open_requests', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', i.repo, 'kind', i.kind, 'number', i.number,
                           'action', a.action, 'label', a.label, 'author', a.author, 'exact_step', a.exact_step,
                           'body_file', a.body_file, 'decision', a.decision, 'asked_at', a.asked_at,
                           'item_changed', i.state <> 'open' OR i.updated_at <> a.seen_updated_at))
                    FROM (SELECT * FROM approvals WHERE decision = 'pending' OR (decision = 'granted' AND used_at IS NULL) ORDER BY id) AS a
                    JOIN items AS i ON i.id = a.item_id),
  'done_since_start', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', i.repo, 'number', i.number,
                              'action', a.action, 'label', a.label, 'author', a.author))
                       FROM approvals AS a JOIN items AS i ON i.id = a.item_id
                       WHERE a.outcome = 'done' AND a.outcome_at >= (SELECT started_at FROM temp.run))
);
