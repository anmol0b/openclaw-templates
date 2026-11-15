-- The digest data for one run, as one JSON object: fetches (with partial reads), the stale list, open requests, and branches deleted in this run.
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

SELECT json_object(
  'run', (SELECT json_object('run_id', id, 'kind', kind, 'stale_days', stale_days, 'started_at', started_at,
                             'ended_at', ended_at, 'note', note) FROM temp.run),
  'fetches', (SELECT json_group_array(json_object('repo', repo, 'login', login, 'branches', branches, 'branches_total', branches_total,
                     'prs', prs, 'issues', issues, 'issues_enabled', issues_enabled,
                     'branches_cut', branches_cut, 'prs_cut', prs_cut, 'issues_cut', issues_cut))
              FROM fetches WHERE run_id = (SELECT id FROM temp.run)),
  'stale', (SELECT json_group_array(json_object('item_id', id, 'repo', repo, 'kind', kind, 'ref', ref, 'title', title, 'url', url,
                   'category', category, 'days_idle', days_idle, 'ci_state', ci_state, 'mergeable', mergeable,
                   'is_draft', is_draft, 'merged_pr', merged_pr))
            FROM (SELECT * FROM owners_work WHERE days_idle >= (SELECT stale_days FROM temp.run)
                  ORDER BY rank, days_idle DESC, id LIMIT 50)),
  'stale_total', (SELECT count(*) FROM owners_work WHERE days_idle >= (SELECT stale_days FROM temp.run)),
  'open_requests', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', i.repo, 'kind', i.kind, 'ref', i.ref,
                           'action', a.action, 'exact_step', a.exact_step, 'decision', a.decision, 'asked_at', a.asked_at,
                           'item_changed', i.state <> 'open' OR i.head_oid <> a.seen_head_oid OR i.last_activity <> a.seen_last_activity))
                    FROM (SELECT * FROM approvals WHERE decision = 'pending' OR (decision = 'granted' AND used_at IS NULL) ORDER BY id) AS a
                    JOIN items AS i ON i.id = a.item_id),
  'deleted_branches', (SELECT json_group_array(json_object('repo', i.repo, 'branch', i.ref, 'sha', a.seen_head_oid,
                              'restore', 'git push <remote> ' || a.seen_head_oid || ':refs/heads/' || i.ref))
                       FROM approvals AS a JOIN items AS i ON i.id = a.item_id
                       WHERE a.action = 'delete-branch' AND a.outcome = 'done'
                         AND a.outcome_at >= (SELECT started_at FROM temp.run))
);
