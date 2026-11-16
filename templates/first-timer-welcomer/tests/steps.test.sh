#!/bin/zsh
# Read side: add-repo, run-start, ingest, newcomers, label-candidates, run-end, digest.
# The fixture keeps the exact shape of the `gh api graphql` response fetch.mjs asks for (gh 2.102),
# with made-up names. Usage: zsh tests/steps.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
schema
OUT="$(sqlite3 -bail "$DB" ".read references/schema.sql" 2>&1)"; RC=$?
expect_refused database_not_empty "schema refuses a database that already has tables"
step setup-check '{}'; expect_has "setup-check passes" '"result":"ok"'

# add-repo: the name and the allowed labels are checked.
step add-repo '{"step":"add-repo","repo":"'$R'"}'
expect_has "add-repo registers the repository with the default labels" '"allowed_labels":"[\"good first issue\",\"help wanted\"]"'
for bad in "../etc" "a/b/c" "a b/c" "-x/y" "a/-y" "a/.git" "noslash" "a/b;rm"; do
  step add-repo '{"step":"add-repo","repo":"'$bad'"}'; expect_fail "add-repo refuses $bad"
done
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":["good first issue","x'"'"'; rm -rf ~"]}'
expect_refused label_name_unsafe "add-repo refuses a label with a quote"
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":["-x"]}'; expect_refused label_name_unsafe "add-repo refuses a label starting with a dash"
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":[]}'; expect_refused allowed_labels_not_1_to_5 "add-repo refuses no labels"
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":["a","b","c","d","e","f"]}'; expect_refused allowed_labels_not_1_to_5 "add-repo refuses six labels"
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":[7]}'; expect_refused label_name_unsafe "add-repo refuses a label that is not text"
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":["good first issue","help wanted","docs: easy"]}'
expect_has "add-repo again updates the allowed labels" 'docs: easy'
step add-repo '{"step":"add-repo","repo":"'$R'"}'; expect_rc0 "add-repo back to the defaults"

step ingest '{"step":"ingest","repo":"other/repo"}'; expect_refused repo_not_registered "ingest refuses an unregistered repository"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused fetch_missing_or_for_another_repo "ingest refuses when fetch has not run"

step run-start '{"step":"run-start","kind":"scheduled","recent_days":14}'; expect_has "run-start returns the run" '"run_id":1'
step run-start '{"step":"run-start","kind":"scheduled","recent_days":0}'; expect_fail "run-start refuses recent_days 0"
step run-start '{"step":"run-start","kind":"hourly","recent_days":14}'; expect_fail "run-start refuses an unknown kind"

serve "$FIXTURES/example"
fetch $R; expect_has "fetch prints the summary" '"prs":7,"prs_total":7,"issues":7,"issues_total":7'
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
expect_has "ingest counts PRs, issues and labels" '"prs":7,"prs_total":7,"issues":7,"issues_total":7,"labels":5,"labels_total":5'
expect_has "a complete read marks nothing cut" '"prs_cut":0,"issues_cut":0,"labels_cut":0'
q "SELECT count(*) FROM items WHERE body_chars > 0 AND kind = 'issue';"; expect_eq "issue bodies are stored only as a count" "7"
q "SELECT body_chars FROM items WHERE number = 25;"; expect_eq "the count is of the trimmed body" "9"

nc() { sqlite3 "$DB" "SELECT coalesce((SELECT CASE WHEN waiting THEN 'waiting' ELSE 'newcomer' END FROM newcomers WHERE number = $1), 'excluded');"; }
OUT="$(nc 11)|$(nc 12)|$(nc 21)"; RC=0; expect_eq "NONE and FIRST_TIME_CONTRIBUTOR authors are newcomers, waiting" "waiting|waiting|waiting"
OUT="$(nc 13)"; RC=0; expect_eq "a FIRST_TIMER the owner already answered is a newcomer, not waiting" "newcomer"
OUT="$(nc 14)"; RC=0; expect_eq "a CONTRIBUTOR is not a newcomer" "excluded"
OUT="$(nc 15)"; RC=0; expect_eq "a bot is not a newcomer" "excluded"
OUT="$(nc 17)"; RC=0; expect_eq "the owner is not a newcomer" "excluded"
OUT="$(nc 27)"; RC=0; expect_eq "a deleted account is not a newcomer" "excluded"
q "SELECT owner_last_comment_at <> '' FROM items WHERE number = 13;"; expect_eq "the owner's own comment is seen without reading it" "1"
q "SELECT owner_last_comment_at FROM items WHERE number = 11;"; expect_eq "someone else's comment is not the owner's" ""

step newcomers '{"step":"newcomers","run_id":1}'; expect_rc0 "newcomers runs"
[[ "$OUT" == *'"number":12'* && "$OUT" == *'"number":11'* && "$OUT" == *'"number":21'* && "$OUT" == *'"number":13'* ]] && ok "newcomers lists recent newcomer items" || bad "newcomers lists recent newcomer items"
[[ "$OUT" != *'"number":16'* ]] && ok "a newcomer PR older than recent_days is left out" || bad "a newcomer PR older than recent_days is left out"
LAST="$(print -r -- "$OUT" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(a.map(x=>x.waiting).join(""))')"
[[ "$LAST" == "1110" ]] && ok "waiting items come first" || { OUT="waiting=$LAST"; bad "waiting items come first"; }
step newcomers '{"step":"newcomers","run_id":1,"limit":0}'; expect_refused limit_not_1_to_50 "newcomers refuses limit 0"
step newcomers '{"step":"newcomers","run_id":9}'; expect_refused unknown_run "newcomers refuses an unknown run"

step label-candidates '{"step":"label-candidates"}'; expect_rc0 "label-candidates runs"
CANDS="$(print -r -- "$OUT" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(a.map(x=>x.number).join(","))')"
[[ "$CANDS" == "22,27,21" ]] && ok "label candidates: unassigned, no linked PR, a description, no allowed label yet" || { OUT="candidates=$CANDS"; bad "label candidates: unassigned, no linked PR, a description, no allowed label yet"; }
[[ "$OUT" != *'Steps to reproduce'* ]] && ok "no issue body reaches a step's output" || bad "no issue body reaches a step's output"
step label-candidates '{"step":"label-candidates","limit":51}'; expect_refused limit_not_1_to_50 "label-candidates refuses a limit over 50"

# Bad input stops ingest and changes nothing.
D="inbox/${R/\//__}"
cp "$D/prs.json" "$SCRATCH/prs.good"
# row <json fields>: one PR row with those fields replaced.
row() { node -e 'const b={number:12,title:"x",createdAt:"2026-11-15T00:00:00Z",updatedAt:"2026-11-15T00:00:00Z",authorAssociation:"NONE",author:{login:"ex",type:"User"},labels:[],assignees:0,linkedPrs:0,bodyChars:0,comments:0,ownerLastCommentAt:""};require("fs").writeFileSync(process.argv[2],JSON.stringify([Object.assign(b,JSON.parse("{"+process.argv[1]+"}"))]))' "$1" "$D/prs.json"; }
row '"number":"12"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused number_not_integer "ingest refuses a number that is not an integer"
row '"updatedAt":"yesterday"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused time_not_iso_utc "ingest refuses a time that is not ISO UTC"
row '"author":{"login":"a b; id","type":"User"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused author_login_unsafe "ingest refuses an unsafe login"
row '"authorAssociation":"FRIEND"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused association_unknown "ingest refuses an unknown association"
row '"labels":[{"name":"x"}]'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused labels_not_a_list_of_names "ingest refuses labels that are not names"
row '"comments":"3"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused count_not_integer "ingest refuses a count that is not an integer"
row '"ownerLastCommentAt":"soon"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused time_not_iso_utc "ingest refuses an owner comment time that is not ISO UTC"
print -r -- '{"not":"a list"}' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused inbox_file_not_a_list "ingest refuses a file that is not a list"
cp "$SCRATCH/prs.good" "$D/prs.json"
q "SELECT count(*) FROM fetches;"; expect_eq "refused ingests record no fetch" "1"

# Gone: a complete read without an item marks it gone; a cut read marks nothing gone and lists nothing old.
edit_served 'r.issues.nodes=r.issues.nodes.filter(n=>n.number!==23);r.issues.totalCount=r.issues.nodes.length'
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a complete read reports the gone item" '"gone_now":1'
q "SELECT state FROM items WHERE number=23;"; expect_eq "the missing issue is marked gone" "gone"
serve "$FIXTURES/example"
edit_served 'r.issues.nodes=r.issues.nodes.filter(n=>n.number!==22)'
q "UPDATE items SET last_seen = '2001-01-01T00:00:00Z';"  # earlier reads happened in the same second
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a read with fewer issues than the total is cut" '"issues_cut":1'
q "SELECT state FROM items WHERE number=22;"; expect_eq "a cut read marks nothing gone" "open"
q "SELECT count(*) FROM label_candidates WHERE number=22;"; expect_eq "an item the latest read did not reach is not listed" "0"
q "SELECT state FROM items WHERE number=23;"; expect_eq "an item seen again is open again" "open"
serve "$FIXTURES/example"
edit_served 'r.labels.totalCount=150'
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a label read under the total is cut" '"labels_cut":1'
edit_served 'r.hasIssuesEnabled=false'
fetch $R; expect_has "issues turned off: zero issues" '"issues":0,"issues_total":0'
serve "$FIXTURES/example"
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_rc0 "ingest again"

step run-end '{"step":"run-end","run_id":1,"note":"example-org/other: gh read failed"}'; expect_has "run-end ends the run" '"ended_at":"'
step run-end '{"step":"run-end","run_id":1}'; expect_refused run_unknown_or_ended "run-end refuses a run that already ended"
step_raw digest '{"step":"digest","run_id":1}'; expect_rc0 "digest runs"
print -r -- "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' && ok "digest prints one plain JSON object" || bad "digest prints one plain JSON object"
for key in '"fetches":[' '"waiting":[' '"waiting_total":3' '"newcomers_total":4' '"label_candidates":[' '"label_candidates_total":3' '"open_requests":[' '"done_since_start":[' '"labels_cut":1' '"note":"example-org/other: gh read failed"'; do
  [[ "$OUT" == *"$key"* ]] && ok "digest has $key" || bad "digest has $key"
done
step_raw digest '{"step":"digest","run_id":42}'; expect_refused unknown_run "digest refuses an unknown run"
step newcomers '{"step":"digest","run_id":1}'; expect_refused db_input_for_another_step "a step refuses input written for another step"
finish
