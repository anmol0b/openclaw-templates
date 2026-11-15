-- The digest data for one run, as one JSON object: reads (with gaps), every open PR sorted into its lane with the latest review,
-- packages bumped by more than one open PR, and open requests. Input: run_id. Read only.
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

CREATE TEMP TABLE g (n INTEGER CONSTRAINT unknown_run CHECK (n = 1));
INSERT INTO temp.g SELECT count(*) FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input);

-- Lane: the latest review of the current head when there is one, otherwise the fact-based floor.
CREATE TEMP TABLE cur AS
SELECT p.*, l.lane AS lane_floor, l.reasons,
       r.verdict, r.note, r.suggested_action,
       coalesce(r.verdict, l.lane) AS lane
FROM prs AS p JOIN pr_lane AS l ON l.pr_id = p.id
LEFT JOIN reviews AS r ON r.id = (SELECT max(id) FROM reviews WHERE pr_id = p.id AND head_sha = p.head_sha)
WHERE p.state = 'OPEN';

SELECT json_object(
  'run', (SELECT json_object('run_id', id, 'kind', kind, 'started_at', started_at, 'ended_at', ended_at, 'note', note)
          FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input)),
  'reads', (SELECT json_group_array(json_object('repo', repo, 'bot', bot, 'read_count', read_count,
                   'new_prs', new_prs, 'limit_reached', limit_reached, 'fetched_at', fetched_at))
            FROM reads WHERE run_id = (SELECT json_extract(j, '$.run_id') FROM temp.input)),
  'lanes', json_object(
     'looks-safe', (SELECT json_group_array(json(o)) FROM (SELECT json_object('repo', repo, 'number', number, 'bot', bot, 'title', title, 'url', url,
                     'updates', json(updates), 'signals', json(signals), 'ci', ci, 'reviewed', verdict IS NOT NULL, 'note', note,
                     'suggested_action', suggested_action) AS o FROM temp.cur WHERE lane = 'looks-safe' ORDER BY repo, number)),
     'needs-a-look', (SELECT json_group_array(json(o)) FROM (SELECT json_object('repo', repo, 'number', number, 'bot', bot, 'title', title, 'url', url,
                     'updates', json(updates), 'reasons', json(reasons), 'ci', ci, 'reviewed', verdict IS NOT NULL, 'note', note,
                     'suggested_action', suggested_action) AS o FROM temp.cur WHERE lane = 'needs-a-look' ORDER BY repo, number)),
     'blocked-by-ci', (SELECT json_group_array(json(o)) FROM (SELECT json_object('repo', repo, 'number', number, 'bot', bot, 'title', title, 'url', url,
                     'failing_checks', json(failing_checks), 'reviewed', verdict IS NOT NULL, 'note', note,
                     'suggested_action', suggested_action) AS o FROM temp.cur WHERE lane = 'blocked-by-ci' ORDER BY repo, number))),
  'same_package', (SELECT json_group_array(json(o)) FROM (
       SELECT json_object('repo', c.repo, 'package', json_extract(u.value, '$.package'),
                          'prs', json_group_array(c.number)) AS o
       FROM temp.cur AS c, json_each(c.updates) AS u
       GROUP BY c.repo, json_extract(u.value, '$.package')
       HAVING count(DISTINCT c.number) > 1
       ORDER BY c.repo, json_extract(u.value, '$.package'))),
  'not_reviewed', (SELECT count(*) FROM temp.cur WHERE verdict IS NULL),
  'open_requests', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', p.repo, 'number', p.number,
                           'action', a.action, 'exact_step', a.exact_step, 'decision', a.decision, 'asked_at', a.asked_at,
                           'pr_changed', p.head_sha <> a.seen_head_sha OR p.updated_at <> a.seen_updated_at OR p.state <> 'OPEN'))
                    FROM (SELECT * FROM approvals WHERE decision = 'pending' OR (decision = 'granted' AND used_at IS NULL) ORDER BY id) AS a
                    JOIN prs AS p ON p.id = a.pr_id)
);
