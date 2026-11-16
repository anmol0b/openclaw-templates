-- Register one repository from settings.md, or update its allowed labels. Input: repo (owner/name),
-- allowed_labels (1 to 5 label names from settings.md; default good first issue and help wanted). Safe to repeat.
-- A label name is 1 to 50 letters, digits, spaces and . _ : / -, not starting with a space or dash.
-- Run from the workspace root:
--   sqlite3 -bail -json <db_path> ".read references/sql/add-repo.sql"
-- Input: write db-input.json with the write tool first, with "step": "add-repo".
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE schema_guard (v INTEGER CONSTRAINT wrong_schema_version CHECK (v = 1));
INSERT INTO temp.schema_guard SELECT user_version FROM pragma_user_version;
CREATE TEMP TABLE input (j TEXT NOT NULL CONSTRAINT db_input_not_json CHECK (json_valid(j)));
INSERT INTO temp.input VALUES (CAST(readfile('db-input.json') AS TEXT));
CREATE TEMP TABLE step_guard (s TEXT CONSTRAINT db_input_for_another_step CHECK (s = 'add-repo'));
INSERT INTO temp.step_guard SELECT json_extract(j, '$.step') FROM temp.input;

CREATE TEMP TABLE labels AS
SELECT coalesce(json_extract(j, '$.allowed_labels'), '["good first issue","help wanted"]') AS l FROM temp.input;
CREATE TEMP TABLE g1 (ok INTEGER CONSTRAINT allowed_labels_not_1_to_5 CHECK (ok = 1));
INSERT INTO temp.g1 SELECT json_valid(l) AND json_type(l) = 'array' AND json_array_length(l) BETWEEN 1 AND 5 FROM temp.labels;
CREATE TEMP TABLE g2 (ok INTEGER CONSTRAINT label_name_unsafe CHECK (ok = 1));
INSERT INTO temp.g2
SELECT NOT EXISTS (SELECT 1 FROM temp.labels AS x, json_each(x.l) AS e
                   WHERE e.type <> 'text' OR length(e.value) NOT BETWEEN 1 AND 50
                      OR e.value GLOB '*[^A-Za-z0-9 ._:/-]*' OR e.value GLOB '[ -]*' OR e.value GLOB '* ');

-- The repos table checks the name (letters, digits, dot, dash, underscore, one slash).
INSERT INTO repos (repo, added_at, allowed_labels)
SELECT json_extract(j, '$.repo'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), json((SELECT l FROM temp.labels)) FROM temp.input WHERE true
ON CONFLICT (repo) DO UPDATE SET allowed_labels = excluded.allowed_labels;

SELECT repo, added_at, json(allowed_labels) AS allowed_labels, login FROM repos
WHERE repo = (SELECT json_extract(j, '$.repo') FROM temp.input);
