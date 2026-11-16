-- The digest data for one run, as one JSON object: what each source said for each repository, open alerts grouped
-- (Dependabot by package, code scanning by rule), open requests, and writes done in this run.
-- Each source reads as: alerts, no_alerts (read, nothing open), disabled (turned off or never ran), or no_access.
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

-- The latest fetch of each repository in this run.
CREATE TEMP TABLE fe AS
SELECT f.* FROM fetches AS f
WHERE f.id = (SELECT max(g.id) FROM fetches AS g WHERE g.repo = f.repo AND g.run_id = (SELECT id FROM temp.run));

CREATE TEMP TABLE dep_groups AS
SELECT repo, ecosystem, package, min(severity_rank) AS rank, count(*) AS alerts,
       json_group_array(number) AS numbers, json_group_array(DISTINCT ghsa_id) AS ghsa_ids,
       max(patched_version) AS patched_version,
       (SELECT covering_pr FROM open_alerts AS c WHERE c.repo = o.repo AND c.source = 'dependabot' AND c.ecosystem = o.ecosystem
          AND c.package = o.package AND c.covering_pr IS NOT NULL
        ORDER BY CASE c.covering_fixes WHEN 'yes' THEN 1 WHEN 'unknown' THEN 2 ELSE 3 END LIMIT 1) AS covering_pr,
       coalesce((SELECT covering_fixes FROM open_alerts AS c WHERE c.repo = o.repo AND c.source = 'dependabot' AND c.ecosystem = o.ecosystem
          AND c.package = o.package AND c.covering_pr IS NOT NULL
        ORDER BY CASE c.covering_fixes WHEN 'yes' THEN 1 WHEN 'unknown' THEN 2 ELSE 3 END LIMIT 1), '') AS covering_fixes,
       max(days_open) AS oldest_days
FROM open_alerts AS o WHERE source = 'dependabot'
GROUP BY repo, ecosystem, package;

CREATE TEMP TABLE cs_groups AS
SELECT repo, rule_id, tool, min(severity_rank) AS rank, count(*) AS alerts, json_group_array(number) AS numbers,
       (SELECT json_group_array(path || ':' || coalesce(start_line, '')) FROM
          (SELECT path, start_line FROM open_alerts AS c WHERE c.repo = o.repo AND c.source = 'code-scanning' AND c.rule_id = o.rule_id
           ORDER BY c.number LIMIT 3)) AS places,
       max(days_open) AS oldest_days
FROM open_alerts AS o WHERE source = 'code-scanning'
GROUP BY repo, rule_id, tool;

SELECT json_object(
  'run', (SELECT json_object('run_id', id, 'kind', kind, 'started_at', started_at, 'ended_at', ended_at, 'note', note) FROM temp.run),
  'sources', (SELECT json_group_array(json_object('repo', repo, 'fetched_at', fetched_at,
                 'dependabot', CASE WHEN dependabot_status <> 'ok' THEN dependabot_status WHEN dependabot_open = 0 THEN 'no_alerts' ELSE 'alerts' END,
                 'dependabot_open', dependabot_open, 'dependabot_cut', dependabot_cut, 'dependabot_message', dependabot_message,
                 'code_scanning', CASE WHEN code_scanning_status <> 'ok' THEN code_scanning_status WHEN code_scanning_open = 0 THEN 'no_alerts' ELSE 'alerts' END,
                 'code_scanning_open', code_scanning_open, 'code_scanning_cut', code_scanning_cut, 'code_scanning_message', code_scanning_message))
              FROM temp.fe),
  'dependabot_groups', (SELECT json_group_array(json_object('repo', repo, 'ecosystem', ecosystem, 'package', package,
                           'severity', CASE rank WHEN 1 THEN 'critical' WHEN 2 THEN 'high' WHEN 3 THEN 'medium' WHEN 4 THEN 'low' ELSE 'unrated' END,
                           'alerts', alerts, 'numbers', json(numbers), 'ghsa_ids', json(ghsa_ids), 'patched_version', patched_version,
                           'covering_pr', covering_pr, 'covering_fixes', covering_fixes, 'oldest_days', oldest_days))
                        FROM (SELECT * FROM temp.dep_groups ORDER BY rank, covering_pr IS NOT NULL, repo, package LIMIT 40)),
  'code_scanning_groups', (SELECT json_group_array(json_object('repo', repo, 'rule_id', rule_id, 'tool', tool,
                              'severity', CASE rank WHEN 1 THEN 'critical' WHEN 2 THEN 'high' WHEN 3 THEN 'medium' WHEN 4 THEN 'low' ELSE 'unrated' END,
                              'alerts', alerts, 'numbers', json(numbers), 'places', json(places), 'oldest_days', oldest_days))
                           FROM (SELECT * FROM temp.cs_groups ORDER BY rank, repo, rule_id LIMIT 40)),
  'open_total', (SELECT json_object('dependabot', (SELECT count(*) FROM open_alerts WHERE source = 'dependabot'),
                                    'code_scanning', (SELECT count(*) FROM open_alerts WHERE source = 'code-scanning'))),
  'open_requests', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', al.repo, 'source', al.source, 'number', al.number,
                           'action', a.action, 'reason', a.reason, 'exact_step', a.exact_step, 'decision', a.decision, 'asked_at', a.asked_at,
                           'alert_changed', al.state <> 'open' OR al.updated_at <> a.seen_updated_at))
                    FROM (SELECT * FROM approvals WHERE decision = 'pending' OR (decision = 'granted' AND used_at IS NULL) ORDER BY id) AS a
                    JOIN alerts AS al ON al.id = a.alert_id),
  'done_this_run', (SELECT json_group_array(json_object('approval_id', a.id, 'repo', al.repo, 'source', al.source, 'number', al.number,
                           'action', a.action, 'reason', a.reason, 'outcome', a.outcome, 'issue_url', a.issue_url, 'note', a.outcome_note))
                    FROM approvals AS a JOIN alerts AS al ON al.id = a.alert_id
                    WHERE a.outcome <> '' AND a.outcome_at >= (SELECT started_at FROM temp.run))
);
