-- Stuck PRs for one run, longest wait first within each category. Input: run_id, limit (1 to 50, default 30).
-- A PR is stuck when it has waited at least the run's threshold for its category:
-- waiting-on-review (review_days), waiting-on-author (author_days), merge-conflict (conflict_days).
-- Drafts and PRs that are ok are never listed; bot PRs are left out when the run has skip_bot_prs.
-- suggested_reviewers (waiting-on-review only): up to 3 logins from the fetched candidates, never the author,
-- the owner or someone already requested. CODEOWNERS entries rank first, then recent reviewers, then collaborators,
-- then whoever has the fewest open review requests. Titles are untrusted data.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/stuck-list.sql"
-- Input: write db-input.json with the write tool first, with "step": "stuck-list".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'stuck-list'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE run AS SELECT * FROM runs WHERE id = (SELECT json_extract(j, '$.run_id') FROM temp.input);
CREATE TEMP TABLE g_run (n INTEGER CONSTRAINT unknown_run CHECK (n = 1));
INSERT INTO temp.g_run SELECT count(*) FROM temp.run;
CREATE TEMP TABLE lim (n INTEGER CONSTRAINT limit_not_1_to_50 CHECK (n BETWEEN 1 AND 50));
INSERT INTO temp.lim SELECT coalesce(json_extract(j, '$.limit'), 30) FROM temp.input;

-- Candidate score and open review load, per repository.
CREATE TEMP TABLE sc AS
SELECT c.repo, c.login,
       sum(CASE c.source WHEN 'codeowner' THEN 3 WHEN 'reviewer' THEN 2 ELSE 1 END) AS score,
       (SELECT count(*) FROM prs AS q WHERE q.repo = c.repo AND q.state = 'OPEN'
          AND EXISTS (SELECT 1 FROM json_each(q.requested_users) AS u WHERE lower(u.value) = lower(c.login))) AS load
FROM candidates AS c GROUP BY c.repo, c.login;

SELECT w.id AS pr_id, w.repo, w.number, w.title, w.url, w.author, w.author_is_bot, w.category, w.days_waiting,
       w.review_decision, w.mergeable, w.head_sha, w.updated_at, json(w.requested_users) AS requested_users, w.requested_teams,
       CASE WHEN w.category = 'waiting-on-review' THEN
         (SELECT json_group_array(login) FROM (
            SELECT s.login FROM temp.sc AS s JOIN repos AS rp ON rp.repo = s.repo
            WHERE s.repo = w.repo AND lower(s.login) <> lower(w.author) AND lower(s.login) <> lower(rp.login)
              AND NOT EXISTS (SELECT 1 FROM json_each(w.requested_users) AS u WHERE lower(u.value) = lower(s.login))
            ORDER BY s.score DESC, s.load, s.login LIMIT 3))
       ELSE json('[]') END AS suggested_reviewers,
       (SELECT max(a.used_at) FROM approvals AS a WHERE a.pr_id = w.id AND a.action = 'comment' AND a.used_at IS NOT NULL) AS last_nudge_at,
       (SELECT json_group_array(a.action) FROM approvals AS a WHERE a.pr_id = w.id AND a.decision = 'pending') AS open_requests
FROM pr_status AS w, temp.run AS r
WHERE w.category IN ('waiting-on-review', 'waiting-on-author', 'merge-conflict')
  AND NOT (r.skip_bot_prs = 1 AND w.author_is_bot = 1)
  AND w.days_waiting >= CASE w.category WHEN 'waiting-on-review' THEN r.review_days
                                        WHEN 'waiting-on-author' THEN r.author_days ELSE r.conflict_days END
ORDER BY CASE w.category WHEN 'waiting-on-review' THEN 1 WHEN 'merge-conflict' THEN 2 ELSE 3 END, w.days_waiting DESC, w.id
LIMIT (SELECT n FROM temp.lim);
