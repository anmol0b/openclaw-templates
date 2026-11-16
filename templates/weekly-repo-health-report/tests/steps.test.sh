#!/bin/zsh
# Every SQL step: setup-check, add-repo, run-start, ingest, run-end, digest.
# The fixtures keep the exact shape of `gh pr list`, `gh issue list`, `gh run list` and `gh repo view`
# output (gh 2.102), with made-up names, and go through the real fetch.mjs.
# Usage: zsh tests/steps.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
J() { node -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8'));const v=($1);process.stdout.write(typeof v==='string'?v:JSON.stringify(v))"; }
ING='{"step":"ingest","repo":"'$R'","run_id":RUN,"stale_pr_days":14,"stale_issue_days":30,"exclude_bot_prs":true}'
ingest() { step ingest "${${2:-$ING}//RUN/$1}"; }

schema
OUT="$(sqlite3 -bail "$DB" ".read references/schema.sql" 2>&1)"; RC=$?
expect_refused database_not_empty "schema refuses a database that already has tables"
step setup-check '{}'; expect_has "setup-check passes" '"result":"ok"'
q "SELECT count(*) FROM sqlite_schema WHERE name LIKE '%approval%';"; expect_eq "there is no approvals table: nothing here writes to GitHub" "0"

# add-repo
step add-repo '{"step":"add-repo","repo":"'$R'"}'; expect_has "add-repo registers the repository" '"repo":"'$R'"'
step add-repo '{"step":"add-repo","repo":"'$R'"}'; expect_rc0 "add-repo is safe to repeat"
for bad in "../etc" "a/b/c" "a b/c" "-x/y" "a/-y" "a/.git" "noslash" "a/b;rm"; do
  step add-repo '{"step":"add-repo","repo":"'$bad'"}'; expect_fail "add-repo refuses $bad"
done
step add-repo '{"step":"run-start","repo":"'$R'"}'; expect_refused db_input_for_another_step "a step refuses input written for another step"
print -r -- 'not json' > db-input.json; OUT="$(sqlite3 -bail -json "$DB" ".read references/sql/add-repo.sql" 2>&1)"; RC=$?
expect_refused db_input_not_json "a step refuses input that is not JSON"

# run-start
step run-start '{"step":"run-start","kind":"scheduled"}'; expect_has "run-start returns the run" '"run_id":1'
step run-start '{"step":"run-start","kind":"daily"}'; expect_fail "run-start refuses an unknown kind"

# ingest guards before any fetch
step ingest '{"step":"ingest","repo":"other/repo","run_id":1}'; expect_refused repo_not_registered "ingest refuses an unregistered repository"
ingest 1; expect_refused fetch_missing_or_for_another_repo "ingest refuses when fetch has not run"
ingest 9; expect_refused run_unknown_or_ended "ingest refuses an unknown run"
ingest 1 '{"step":"ingest","repo":"'$R'","run_id":1,"stale_pr_days":0}'; expect_refused stale_days_not_1_to_365 "ingest refuses stale days 0"
ingest 1 '{"step":"ingest","repo":"'$R'","run_id":1,"stale_issue_days":"30"}'; expect_refused stale_days_not_1_to_365 "ingest refuses stale days as text"
ingest 1 '{"step":"ingest","repo":"'$R'","run_id":1,"exclude_bot_prs":"yes"}'; expect_refused exclude_bot_prs_not_true_or_false "ingest refuses exclude_bot_prs that is not a boolean"

# A real fetch and ingest: every number is checked against the fixture.
serve "$FIXTURES/example"
fetch $R; expect_rc0 "fetch with the stand-in gh"
ingest 1; expect_rc0 "ingest saves a snapshot"
S="$OUT"
n() { OUT="$(print -r -- "$S" | J "o[0].$1")"; RC=0; }
n prs_opened; expect_eq "PRs opened in the window (bots left out)" "4"
n prs_merged; expect_eq "PRs merged in the window, not one merged before it" "3"
n prs_closed_unmerged; expect_eq "PRs closed without merging" "2"
n issues_opened; expect_eq "issues opened in the window" "2"
n issues_closed; expect_eq "issues closed in the window" "2"
n review_hours_median; expect_eq "median hours to first review, the author's own and automated reviews not counted" "26"
n merged_without_review; expect_eq "a merged PR with no review is counted" "1"
n merge_hours_median; expect_eq "median hours to merge" "24"
n slowest_merges; expect_eq "slowest merges are PR numbers and hours only" '[{"number":502,"merge_hours":264.0},{"number":501,"merge_hours":24.0},{"number":503,"merge_hours":6.0}]'
n open_prs; expect_eq "open PRs (bots left out)" "4"
n open_draft_prs; expect_eq "open draft PRs" "1"
n stale_prs; expect_eq "PRs idle for 14+ days" "2"
n open_issues; expect_eq "open issues" "5"
n stale_issues; expect_eq "issues idle for 30+ days" "2"
n "ci_runs+'|'+o[0].ci_passed+'|'+o[0].ci_failed+'|'+o[0].ci_other"; expect_eq "CI: completed runs in the window, passed, failed, other" "9|6|2|1"
n ci_pass_rate; expect_eq "CI pass rate leaves cancelled runs out" "75"
OUT="$(print -r -- "$S" | J '[o[0].window_prs_cut,o[0].window_issues_cut,o[0].open_prs_cut,o[0].open_issues_cut,o[0].runs_cut].join("")')"; RC=0; expect_eq "a short read marks nothing cut" "00000"
WEEK="$(print -r -- "$S" | J 'o[0].week')"
[[ "$WEEK" == [0-9][0-9][0-9][0-9]-W[0-9][0-9] ]] && ok "the snapshot is named by its ISO week" || { OUT="$WEEK"; bad "the snapshot is named by its ISO week"; }

# First run: no baseline, never zero trends.
step run-end '{"step":"run-end","run_id":1}'; expect_has "run-end ends the run" '"ended_at":"'
step run-end '{"step":"run-end","run_id":1}'; expect_refused run_unknown_or_ended "run-end refuses a run that already ended"
ingest 1; expect_refused run_unknown_or_ended "ingest refuses an ended run"
step_raw digest '{"step":"digest","run_id":1}'; expect_rc0 "digest runs"
D1="$OUT"
OUT="$(print -r -- "$D1" | J 'typeof o')"; RC=0; expect_eq "digest prints one JSON object" "object"
OUT="$(print -r -- "$D1" | J 'o.reports[0].baseline_note')"; RC=0; expect_eq "the first snapshot says no baseline yet" "no baseline yet"
OUT="$(print -r -- "$D1" | J 'String(o.reports[0].deltas)+"|"+String(o.reports[0].baseline_week)')"; RC=0; expect_eq "the first snapshot has no deltas, not zeros" "null|null"
OUT="$(print -r -- "$D1" | J 'o.reports[0].numbers.prs_merged')"; RC=0; expect_eq "digest carries the numbers" "3"
OUT="$(print -r -- "$D1" | J 'o.missing')"; RC=0; expect_eq "every registered repository has a snapshot" "[]"
step_raw digest '{"step":"digest","run_id":9}'; expect_refused unknown_run "digest refuses an unknown run"

# Same week again: the snapshot is replaced, not added.
step run-start '{"step":"run-start","kind":"manual"}'
edit_served window_prs 'a.filter(x=>x.number!==503)'
fetch $R; ingest 2; expect_rc0 "a second ingest in the same week"
q "SELECT count(*) || '|' || run_id || '|' || prs_merged FROM snapshots;"; expect_eq "the same week's snapshot is replaced with the new numbers" "1|2|2"
serve "$FIXTURES/example"

# Bots counted when exclude_bot_prs is false.
fetch $R; ingest 2 '{"step":"ingest","repo":"'$R'","run_id":2,"stale_pr_days":14,"stale_issue_days":30,"exclude_bot_prs":false}'
OUT="$(print -r -- "$OUT" | J '[o[0].prs_opened,o[0].prs_merged,o[0].merge_hours_median,o[0].open_prs,o[0].stale_prs].join("|")')"; RC=0
expect_eq "with bots: opened, merged, merge median, open, stale" "5|4|15|5|3"
fetch $R; ingest 2

# A previous week's snapshot gives deltas. Move a copy of this snapshot back seven days with other numbers.
q "INSERT INTO snapshots (repo, run_id, fetched_at, window_start, prs_merged, review_hours_median, merge_hours_median, open_prs, stale_prs, ci_pass_rate, ingested_at)
   SELECT repo, 1, strftime('%Y-%m-%dT%H:%M:%SZ', fetched_at, '-7 days'), strftime('%Y-%m-%dT%H:%M:%SZ', window_start, '-7 days'),
          5, 30.5, NULL, 6, 2, 80, ingested_at FROM snapshots WHERE run_id = 2;"
expect_rc0 "setup: last week's snapshot"
step run-end '{"step":"run-end","run_id":2}'
step_raw digest '{"step":"digest","run_id":2}'; D2="$OUT"
OUT="$(print -r -- "$D2" | J 'o.reports.length+"|"+o.reports[0].baseline_week+"|"+o.reports[0].baseline_note')"; RC=0
expect_eq "the digest compares with the previous ISO week" "1|$(sqlite3 "$DB" "SELECT prev_week FROM snapshots WHERE run_id=2 AND week='$WEEK';")|null"
OUT="$(print -r -- "$D2" | J '[o.reports[0].deltas.prs_merged,o.reports[0].deltas.review_hours_median,o.reports[0].deltas.open_prs,o.reports[0].deltas.ci_pass_rate,o.reports[0].deltas.stale_prs].join("|")')"; RC=0
expect_eq "deltas: counts, hours and pass-rate points" "-2|-4.5|-2|-5|0"
OUT="$(print -r -- "$D2" | J 'String(o.reports[0].deltas.merge_hours_median)')"; RC=0
expect_eq "a delta is null when last week had nothing to measure" "null"
OUT="$(print -r -- "$D2" | J 'String(o.reports[0].settings_changed)')"; RC=0; expect_eq "same settings as last week" "false"

# A gap: the only earlier snapshot is two weeks back.
q "UPDATE snapshots SET fetched_at = strftime('%Y-%m-%dT%H:%M:%SZ', fetched_at, '-7 days'), window_start = strftime('%Y-%m-%dT%H:%M:%SZ', window_start, '-7 days') WHERE week <> '$WEEK';"
step_raw digest '{"step":"digest","run_id":2}'
OUT="$(print -r -- "$OUT" | J 'o.reports[0].baseline_note+"|"+String(o.reports[0].deltas)')"; RC=0
expect_eq "a skipped week says which snapshot is missing, with no deltas" "no snapshot for $(sqlite3 "$DB" "SELECT prev_week FROM snapshots WHERE week='$WEEK';")|null"

# A registered repository that was not ingested in the run is named.
step add-repo '{"step":"add-repo","repo":"example-org/other-repo"}'
step_raw digest '{"step":"digest","run_id":2}'
OUT="$(print -r -- "$OUT" | J 'o.missing')"; RC=0; expect_eq "digest names a repository with no snapshot in the run" '["example-org/other-repo"]'

# ISO weeks at year ends (the week column is computed from fetched_at).
for pair in "2026-01-01T10:00:00Z 2026-W01 2025-W52" "2027-01-01T10:00:00Z 2026-W53 2026-W52" "2024-12-30T00:00:00Z 2025-W01 2024-W52" "2026-11-16T00:00:00Z 2026-W47 2026-W46" "2026-11-15T23:59:59Z 2026-W46 2026-W45"; do
  set -- ${=pair}
  q "INSERT INTO snapshots (repo, run_id, fetched_at, window_start, ingested_at) VALUES ('example-org/other-repo', 1, '$1', '2001-01-01T00:00:00Z', 'x') RETURNING week || ' ' || prev_week;"
  expect_eq "ISO week of $1 is $2, previous $3" "$2 $3"
done

# Bad input stops ingest and changes nothing.
step run-start '{"step":"run-start","kind":"manual"}'
q "SELECT count(*) FROM snapshots;"; BEFORE="$OUT"
bad_ingest() { fetch $R; inbox_edit $R "$1" "$2"; ingest 3; expect_refused "$3" "$4"; }
bad_ingest window_prs 'a.map((x,i)=>i?x:{...x,number:"12"})' number_not_integer "ingest refuses a PR number that is not an integer"
bad_ingest window_prs 'a.map((x,i)=>i?x:{...x,createdAt:"yesterday"})' time_not_iso_utc "ingest refuses a time that is not ISO UTC"
bad_ingest window_prs 'a.map((x,i)=>i?x:{...x,state:"DELETED"})' state_unknown "ingest refuses an unknown PR state"
bad_ingest window_prs 'a.map((x,i)=>i?x:{...x,mergedAt:null,state:"MERGED"})' merged_pr_without_merge_time "ingest refuses a merged PR with no merge time"
bad_ingest window_prs 'a.map((x,i)=>i?x:{...x,author:"x; rm -rf ~"})' login_not_valid "ingest refuses a login with other characters"
bad_ingest window_prs 'a.map((x,i)=>i?x:{...x,reviews:[{author:"bob",state:"APPROVED",submittedAt:"soon"}]})' time_not_iso_utc "ingest refuses a review time that is not ISO UTC"
bad_ingest runs 'a.map((x,i)=>i?x:{...x,conclusion:"Success!"})' state_unknown "ingest refuses a run conclusion outside the fixed shape"
bad_ingest open_issues '({"not":"a list"})' inbox_file_not_a_list "ingest refuses a file that is not a list"
fetch $R; inbox_edit $R fetch '({...a,repo:"example-org/other-repo"})'; ingest 3; expect_refused fetch_missing_or_for_another_repo "ingest refuses a fetch for another repository"
fetch $R; inbox_edit $R fetch '({...a,window_start:"2001-01-01T00:00:00Z"})'; ingest 3; expect_refused fetch_missing_or_for_another_repo "ingest refuses a window that does not match the fetch time"
fetch $R; inbox_edit $R fetch '(()=>{const t=new Date(Date.now()-2*3600e3),i=(d)=>d.toISOString().replace(/\.\d{3}Z$/,"Z");return {...a,fetched_at:i(t),window_start:i(new Date(t-7*86400e3))}})()'
ingest 3; expect_refused fetch_again_first "ingest refuses a fetch older than an hour"
q "SELECT count(*) FROM snapshots;"; expect_eq "refused ingests save nothing" "$BEFORE"

# Cut reads.
fetch $R; inbox_edit $R fetch '({...a,limits:{...a.limits,window_prs:9,open_issues:5}})'; ingest 3
OUT="$(print -r -- "$OUT" | J '[o[0].window_prs_cut,o[0].window_issues_cut,o[0].open_prs_cut,o[0].open_issues_cut,o[0].runs_cut].join("")')"; RC=0
expect_eq "a read that hits its limit is marked cut" "10010"
fetch $R; inbox_edit $R fetch '({...a,limits:{...a.limits,runs:12}})'; ingest 3
OUT="$(print -r -- "$OUT" | J 'o[0].runs_cut')"; RC=0; expect_eq "runs at the limit that reach back past the window are not cut" "0"
edit_served runs 'a.filter(x=>Date.parse(x.createdAt)>Date.now()-6*86400e3)'
fetch $R; inbox_edit $R fetch '({...a,limits:{...a.limits,runs:a.counts.runs}})'; ingest 3
OUT="$(print -r -- "$OUT" | J 'o[0].runs_cut')"; RC=0; expect_eq "runs at the limit all inside the window are cut" "1"
serve "$FIXTURES/example"

# Issues turned off.
edit_served repo '({...a,hasIssuesEnabled:false})'
fetch $R; ingest 3
OUT="$(print -r -- "$OUT" | J '[o[0].issues_enabled,o[0].open_issues,o[0].issues_opened].join("|")')"; RC=0
expect_eq "issues turned off: zero issues, flagged" "0|0|0"
finish
