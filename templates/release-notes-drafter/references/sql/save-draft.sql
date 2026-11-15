-- Save a draft: one section for every pull request in the window, and the next tag.
-- Input: run_id, repo, base_tag and newest_merged_at (exactly as pending-prs showed them), include_bots,
-- zero_major_breaking_is_minor (true or false, from settings.md), entries ([{"number": n, "section": s}], every
-- pull request pending-prs returned, each once), and only when the owner chose the version: next_tag and owner_words.
-- The next tag is computed here from the base tag: any breaking entry bumps the major version (the minor one
-- while the major is 0 and zero_major_breaking_is_minor is true), any feature bumps the minor, anything else the patch.
-- With no base release the next tag is v0.1.0. A base tag that is not plain semver (v1.2.3 or 1.2.3) needs next_tag.
-- Returns draft_id, next_tag, bump and the two files to write: notes_file (the release body) and changelog_file.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/save-draft.sql"
-- Input: write db-input.json with the write tool first, with "step": "save-draft".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'save-draft'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE rp AS SELECT * FROM repos WHERE repo = (SELECT json_extract(j, '$.repo') FROM temp.input) AND fetched_at <> '';
CREATE TEMP TABLE repo_guard (n INTEGER CONSTRAINT repo_not_registered_or_never_fetched CHECK (n = 1));
INSERT INTO temp.repo_guard SELECT count(*) FROM temp.rp;
CREATE TEMP TABLE same_guard (ok INTEGER CONSTRAINT repo_changed_since_pending_prs CHECK (ok = 1));
INSERT INTO temp.same_guard
SELECT rp.base_tag = coalesce(json_extract(i.j, '$.base_tag'), '') AND rp.newest_merged_at = coalesce(json_extract(i.j, '$.newest_merged_at'), '')
FROM temp.rp AS rp, temp.input AS i;

CREATE TEMP TABLE e (
  number INTEGER NOT NULL,
  section TEXT NOT NULL CONSTRAINT unknown_section CHECK (section IN ('breaking', 'features', 'fixes', 'docs', 'internal', 'other'))
);
INSERT INTO temp.e SELECT json_extract(x.value, '$.number'), coalesce(json_extract(x.value, '$.section'), '')
FROM temp.input AS i, json_each(i.j, '$.entries') AS x;
CREATE TEMP TABLE eligible AS
SELECT p.* FROM prs AS p, temp.rp AS rp, temp.input AS i
WHERE p.repo = rp.repo AND (coalesce(json_extract(i.j, '$.include_bots'), 0) OR p.author_is_bot = 0);
-- The entries are exactly the window: none missing, none extra, none twice.
CREATE TEMP TABLE cover_guard (ok INTEGER CONSTRAINT entries_do_not_match_the_window CHECK (ok = 1));
INSERT INTO temp.cover_guard
SELECT (SELECT count(*) FROM temp.e) > 0
   AND (SELECT count(*) FROM temp.e) = (SELECT count(DISTINCT number) FROM temp.e)
   AND NOT EXISTS (SELECT 1 FROM temp.e WHERE number NOT IN (SELECT number FROM temp.eligible))
   AND NOT EXISTS (SELECT 1 FROM temp.eligible WHERE number NOT IN (SELECT number FROM temp.e));

-- Plain semver: optional v, three parts of 1 to 9 digits, no leading zeros.
CREATE TEMP TABLE ver (name TEXT PRIMARY KEY, tag TEXT, prefix TEXT, core TEXT);
INSERT INTO temp.ver SELECT 'base', base_tag, '', '' FROM temp.rp;
INSERT INTO temp.ver SELECT 'next', json_extract(j, '$.next_tag'), '', '' FROM temp.input WHERE json_extract(j, '$.next_tag') IS NOT NULL;
UPDATE temp.ver SET prefix = CASE WHEN tag GLOB 'v*' THEN 'v' ELSE '' END;
UPDATE temp.ver SET core = substr(tag, length(prefix) + 1);
CREATE TEMP TABLE sv AS
SELECT name, tag, prefix,
       CAST(substr(core, 1, instr(core, '.') - 1) AS INTEGER) AS maj,
       CAST(substr(substr(core, instr(core, '.') + 1), 1, instr(substr(core, instr(core, '.') + 1), '.') - 1) AS INTEGER) AS mnr,
       CAST(substr(substr(core, instr(core, '.') + 1), instr(substr(core, instr(core, '.') + 1), '.') + 1) AS INTEGER) AS pat,
       (core GLOB '[0-9]*.[0-9]*.[0-9]*' AND core NOT GLOB '*[^0-9.]*'
        AND length(core) - length(replace(core, '.', '')) = 2
        AND core NOT GLOB '*..*' AND core NOT GLOB '*.' AND length(core) <= 29
        AND core NOT GLOB '0[0-9]*' AND core NOT GLOB '*.0[0-9]*'
        AND instr(core, '.') BETWEEN 2 AND 10) AS valid
FROM temp.ver;

CREATE TEMP TABLE next_guard (ok INTEGER CONSTRAINT next_tag_not_semver_or_not_after_base CHECK (ok = 1));
INSERT INTO temp.next_guard
SELECT NOT EXISTS (SELECT 1 FROM temp.sv WHERE name = 'next')
    OR (SELECT valid AND length(trim(coalesce(json_extract(i.j, '$.owner_words'), ''))) > 0 FROM temp.sv, temp.input AS i WHERE name = 'next')
       AND (NOT EXISTS (SELECT 1 FROM temp.sv WHERE name = 'base' AND tag <> '' AND valid)
            OR (SELECT n.prefix = b.prefix AND (n.maj, n.mnr, n.pat) > (b.maj, b.mnr, b.pat)
                FROM temp.sv AS n, temp.sv AS b WHERE n.name = 'next' AND b.name = 'base'));
CREATE TEMP TABLE base_guard (ok INTEGER CONSTRAINT base_tag_not_semver_give_next_tag CHECK (ok = 1));
INSERT INTO temp.base_guard
SELECT EXISTS (SELECT 1 FROM temp.sv WHERE name = 'next')
    OR (SELECT tag = '' OR valid FROM temp.sv WHERE name = 'base');

CREATE TEMP TABLE plan (next_tag TEXT NOT NULL, bump TEXT NOT NULL);
INSERT INTO temp.plan
SELECT CASE
         WHEN n.tag IS NOT NULL THEN n.tag
         WHEN b.tag = '' THEN 'v0.1.0'
         WHEN k.bump = 'major' THEN b.prefix || (b.maj + 1) || '.0.0'
         WHEN k.bump = 'minor' THEN b.prefix || b.maj || '.' || (b.mnr + 1) || '.0'
         ELSE b.prefix || b.maj || '.' || b.mnr || '.' || (b.pat + 1)
       END,
       CASE WHEN n.tag IS NOT NULL THEN 'owner' WHEN b.tag = '' THEN 'first' ELSE k.bump END
FROM temp.sv AS b
LEFT JOIN temp.sv AS n ON n.name = 'next'
JOIN (SELECT CASE
               WHEN EXISTS (SELECT 1 FROM temp.e WHERE section = 'breaking')
                 THEN CASE WHEN (SELECT maj FROM temp.sv WHERE name = 'base') = 0
                                AND coalesce((SELECT json_extract(j, '$.zero_major_breaking_is_minor') FROM temp.input), 1)
                           THEN 'minor' ELSE 'major' END
               WHEN EXISTS (SELECT 1 FROM temp.e WHERE section = 'features') THEN 'minor'
               ELSE 'patch'
             END AS bump) AS k
WHERE b.name = 'base';

-- The tag must not exist yet on GitHub, as a release or a draft release.
CREATE TEMP TABLE tag_guard (ok INTEGER CONSTRAINT tag_already_exists CHECK (ok = 1));
INSERT INTO temp.tag_guard
SELECT NOT EXISTS (SELECT 1 FROM releases AS x, temp.plan AS p, temp.rp AS rp WHERE x.repo = rp.repo AND x.tag = p.next_tag);

BEGIN;
INSERT INTO drafts (run_id, repo, base_tag, newest_merged_at, pr_count, window_count, next_tag, bump, owner_words, notes_file, changelog_file, created_at)
SELECT json_extract(i.j, '$.run_id'), rp.repo, rp.base_tag, rp.newest_merged_at, (SELECT count(*) FROM temp.e), rp.pr_count,
       p.next_tag, p.bump, coalesce(json_extract(i.j, '$.owner_words'), ''),
       'drafts/' || replace(rp.repo, '/', '__') || '-' || p.next_tag || '.md',
       'drafts/' || replace(rp.repo, '/', '__') || '-' || p.next_tag || '-CHANGELOG.md',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM temp.rp AS rp, temp.plan AS p, temp.input AS i;
INSERT INTO draft_entries (draft_id, number, section, title, author, author_is_bot, url)
SELECT (SELECT max(id) FROM drafts), x.number, e.section, x.title, x.author, x.author_is_bot, x.url
FROM temp.e AS e JOIN temp.eligible AS x ON x.number = e.number;
COMMIT;

SELECT id AS draft_id, repo, base_tag, next_tag, bump, pr_count, notes_file, changelog_file
FROM drafts WHERE id = (SELECT max(id) FROM drafts);
