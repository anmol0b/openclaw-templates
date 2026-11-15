-- The digest data for one run, as one JSON object: reads (with gaps), drafts made, and open requests. Input: run_id. Read only.
-- Run from the workspace root:
--   sqlite3 -bail <db_path> ".read references/sql/digest.sql"
-- Input: write db-input.json with the write tool first, with "step": "digest".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'digest'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;
-- No -json flag for this step: it prints one JSON object as it is.

CREATE TEMP TABLE run_guard (n INTEGER CONSTRAINT unknown_run CHECK (n = 1));
INSERT INTO temp.run_guard SELECT count(*) FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input);

SELECT json_object(
  'run', (SELECT json_object('run_id', id, 'kind', kind, 'started_at', started_at, 'ended_at', ended_at, 'note', note)
          FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input)),
  'reads', (SELECT json_group_array(json_object('repo', repo, 'base_tag', base_tag, 'since', since, 'pr_count', pr_count,
                   'limit_reached', limit_reached, 'fetched_at', fetched_at))
            FROM reads WHERE run_id = (SELECT json_extract(j, '$.run_id') FROM temp.input)),
  'drafts', (SELECT json_group_array(json_object('draft_id', id, 'repo', repo, 'base_tag', base_tag, 'next_tag', next_tag,
                    'bump', bump, 'pr_count', pr_count, 'notes_file', notes_file, 'changelog_file', changelog_file))
             FROM drafts WHERE run_id = (SELECT json_extract(j, '$.run_id') FROM temp.input)),
  'open_requests', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', d.repo, 'next_tag', d.next_tag,
                           'exact_step', a.exact_step, 'decision', a.decision, 'asked_at', a.asked_at,
                           'repo_changed', r.base_tag <> a.seen_base_tag OR r.newest_merged_at <> a.seen_newest_merged_at OR r.pr_count <> a.seen_pr_count))
                    FROM (SELECT * FROM approvals WHERE decision = 'pending' OR (decision = 'granted' AND used_at IS NULL) ORDER BY id) AS a
                    JOIN drafts AS d ON d.id = a.draft_id JOIN repos AS r ON r.repo = d.repo)
);
