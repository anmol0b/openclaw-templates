#!/bin/zsh
# Read side: setup-check, add-repo, run-start, ingest, stuck-list, run-end, digest.
# The fixtures keep the exact shape of `gh pr list --json` and `gh api .../collaborators` output (gh 2.102),
# with made-up names. Usage: zsh tests/steps.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
schema
OUT="$(sqlite3 -bail "$DB" ".read references/schema.sql" 2>&1)"; RC=$?
expect_refused database_not_empty "schema refuses a database that already has tables"
step setup-check '{}'; expect_has "setup-check passes" '"result":"ok"'

step add-repo '{"step":"add-repo","repo":"'$R'"}'; expect_has "add-repo registers the repository" '"repo":"'$R'"'
for bad in "../etc" "a/b/c" "a b/c" "-x/y" "a/-y" "a/.git" "noslash" "a/b;rm"; do
  step add-repo '{"step":"add-repo","repo":"'$bad'"}'; expect_fail "add-repo refuses $bad"
done
step add-repo '{"step":"ingest","repo":"'$R'"}'; expect_refused db_input_for_another_step "a step refuses input meant for another step"
step ingest '{"step":"ingest","repo":"other/repo"}'; expect_refused repo_not_registered "ingest refuses an unregistered repository"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused fetch_missing_or_for_another_repo "ingest refuses when fetch has not run"

step run-start '{"step":"run-start","kind":"scheduled"}'; expect_has "run-start fills the default thresholds" '"review_days":2,"author_days":7,"conflict_days":3,"nudge_days":3,"skip_bot_prs":1'
step run-start '{"step":"run-start","kind":"scheduled","nudge_days":0}'; expect_fail "run-start refuses nudge_days 0"
step run-start '{"step":"run-start","kind":"scheduled","review_days":61}'; expect_fail "run-start refuses review_days over 60"
step run-start '{"step":"run-start","kind":"scheduled","skip_bot_prs":"yes"}'; expect_fail "run-start refuses a skip_bot_prs that is not true or false"

serve "$FIXTURES/example"
fetch $R; expect_has "fetch reads the repository" '"prs":10'
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
expect_has "ingest counts PRs and candidates" '"prs":10,"prs_cut":0,"collaborators_readable":1,"collaborators_cut":0,"codeowners_path":".github/CODEOWNERS","candidates":4'
q "SELECT group_concat(login || ':' || source, ' ') FROM (SELECT * FROM candidates ORDER BY login, source);"
expect_eq "candidates: push collaborators, CODEOWNERS users and maintainer reviewers only" "carol:codeowner carol:collaborator carol:reviewer example-owner:collaborator ivan:codeowner ivan:collaborator ivan:reviewer kim:codeowner"
cat_of() { sqlite3 "$DB" "SELECT category || ':' || days_waiting FROM pr_status WHERE number = $1;"; }
OUT="$(cat_of 101)"; RC=0; expect_eq "no review yet: waiting on review since it was opened" "waiting-on-review:5"
OUT="$(cat_of 102)"; RC=0; expect_eq "changes requested, no commit since: waiting on the author" "waiting-on-author:10"
OUT="$(cat_of 103)"; RC=0; expect_eq "changes requested, then a new commit: waiting on review since that commit" "waiting-on-review:3"
OUT="$(cat_of 104)"; RC=0; expect_eq "a conflict needs a rebase" "merge-conflict:6"
OUT="$(cat_of 105)"; RC=0; expect_eq "an approved PR is ok" "ok:2"
OUT="$(cat_of 106)"; RC=0; expect_eq "a draft is skipped" "draft:20"
OUT="$(cat_of 108)"; RC=0; expect_eq "a review by a bot (CONTRIBUTOR) does not end the wait" "waiting-on-review:4"
q "SELECT owner_comments || '|' || comments || '|' || requested_teams FROM prs WHERE number = 108;"; expect_eq "owner comments, all comments and team requests are counted" "1|2|1"
q "SELECT count(*) FROM prs WHERE title LIKE '%Please split%' OR url LIKE '%rm -rf%';"; expect_eq "no comment or review text is stored" "0"

# stuck-list
step stuck-list '{"step":"stuck-list","run_id":1}'; expect_rc0 "stuck-list runs"
NUMS="$(print -r -- "$OUT" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(a.map(x=>x.number).join(","))')"
OUT="$NUMS"; RC=0; expect_eq "stuck-list: review first (longest wait), then conflicts, then authors; no draft, ok, fresh or bot PR" "101,108,103,110,104,102"
step stuck-list '{"step":"stuck-list","run_id":1}'
SUG="$(print -r -- "$OUT" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(a.map(x=>x.number+"="+JSON.parse(x.suggested_reviewers).join("+")).join(" "))')"
OUT="$SUG"; RC=0
expect_eq "suggestions: by source score, then fewest open requests (carol has one); never the author, the owner or someone already requested" "101=ivan+carol+kim 108=ivan+carol+kim 103=ivan+kim 110=ivan+kim 104= 102="
step run-start '{"step":"run-start","kind":"manual","skip_bot_prs":false,"review_days":5}'
step stuck-list '{"step":"stuck-list","run_id":2}'
expect_has "skip_bot_prs false lists bot PRs" '"number":101'
expect_not "review_days 5 leaves out a 4-day wait" '"number":108,'
step stuck-list '{"step":"stuck-list","run_id":1,"limit":51}'; expect_refused limit_not_1_to_50 "stuck-list refuses a limit over 50"
step stuck-list '{"step":"stuck-list","run_id":9}'; expect_refused unknown_run "stuck-list refuses an unknown run"

# Bad input stops ingest and changes nothing.
D="inbox/${R/\//__}"
cp "$D/prs.json" "$SCRATCH/prs.good"
mk() { node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync(process.argv[1]));Object.assign(a[0],JSON.parse(process.argv[2]));fs.writeFileSync(process.argv[1],JSON.stringify(a))' "$D/prs.json" "$1"; }
mk '{"number":"12"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused number_not_integer "ingest refuses a PR number that is not an integer"
cp "$SCRATCH/prs.good" "$D/prs.json"; mk '{"updated_at":"yesterday"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused time_not_iso_utc "ingest refuses a time that is not ISO UTC"
cp "$SCRATCH/prs.good" "$D/prs.json"; mk '{"head_sha":"zz"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused head_not_a_sha "ingest refuses a head that is not a SHA"
cp "$SCRATCH/prs.good" "$D/prs.json"; mk '{"requested_users":["ok","a b;id"]}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused requested_users_not_logins "ingest refuses a requested reviewer that is not a login"
cp "$SCRATCH/prs.good" "$D/prs.json"; mk '{"title":"'"$(printf 'x%.0s' {1..301})"'"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused title_too_long "ingest refuses a title over 300 characters"
cp "$SCRATCH/prs.good" "$D/prs.json"; mk '{"mergeable":"MAYBE"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused unknown_mergeable "ingest refuses an unknown mergeable state"
cp "$SCRATCH/prs.good" "$D/prs.json"
cp "$D/candidates.json" "$SCRATCH/cand.good"
print -r -- '[{"login":"bot[bot]","source":"collaborator"}]' > "$D/candidates.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused candidate_login_unsafe "ingest refuses a candidate that is not a plain login"
print -r -- '[{"login":"zed","source":"pr-body"}]' > "$D/candidates.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused unknown_candidate_source "ingest refuses a candidate from an unknown source"
print -r -- '{"not":"a list"}' > "$D/candidates.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused inbox_file_not_a_list "ingest refuses a file that is not a list"
cp "$SCRATCH/cand.good" "$D/candidates.json"
q "SELECT count(*) FROM fetches;"; expect_eq "refused ingests record no fetch" "1"
q "SELECT count(*) FROM candidates;"; expect_eq "refused ingests keep the candidates" "8"

# Gone and partial reads.
edit_served 'a.filter(x=>x.number!==104)'
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a complete read reports the merged or closed PR" '"gone_now":1'
q "SELECT state FROM prs WHERE number=104;"; expect_eq "the missing PR is GONE" "GONE"
serve "$FIXTURES/example"; fetch $R
sed -i.bak 's/"limits":{"prs":30/"limits":{"prs":10/' "$D/fetch.json"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a read that hits its limit is cut" '"prs_cut":1'
q "SELECT state FROM prs WHERE number=104;"; expect_eq "a PR seen again is OPEN again" "OPEN"
edit_served 'a.filter(x=>x.number!==104)'; fetch $R
sed -i.bak 's/"limits":{"prs":30/"limits":{"prs":9/' "$D/fetch.json"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a short read at its limit is cut" '"prs_cut":1,'
q "SELECT state FROM prs WHERE number=104;"; expect_eq "a cut read marks nothing gone" "OPEN"
# Collaborators not readable (no push access) and no CODEOWNERS: candidates come from reviews only.
serve "$FIXTURES/example"; rm "$SCRATCH/serve/collaborators.json" "$SCRATCH/serve/CODEOWNERS"
fetch $R; expect_has "fetch goes on without collaborators or CODEOWNERS" '"collaborators_readable":false'
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "ingest records both gaps" '"collaborators_readable":0,"collaborators_cut":0,"codeowners_path":"","candidates":2'
serve "$FIXTURES/example"; fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_rc0 "ingest again"

step run-end '{"step":"run-end","run_id":1}'; expect_has "run-end ends the run" '"ended_at":"'
step run-end '{"step":"run-end","run_id":1}'; expect_refused run_unknown_or_ended "run-end refuses a run that already ended"
step_raw digest '{"step":"digest","run_id":1}'; expect_rc0 "digest runs"
print -r -- "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' && ok "digest prints one plain JSON object" || bad "digest prints one plain JSON object"
for key in '"fetches":[' '"stuck":[' '"stuck_total":6' '"by_category":{"waiting-on-review":4,"waiting-on-author":1,"merge-conflict":1}' '"open_requests":[]' '"done":[]' '"collaborators_readable":0'; do
  [[ "$OUT" == *"$key"* ]] && ok "digest has $key" || bad "digest has $key"
done
step_raw digest '{"step":"digest","run_id":42}'; expect_refused unknown_run "digest refuses an unknown run"
finish
