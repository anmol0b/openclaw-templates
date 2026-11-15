#!/bin/zsh
# Read side: add-repo, the real fetch.mjs (stand-in gh), ingest, to-review, save-review, run-end, digest.
# Usage: zsh tests/steps.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
schema
RC=0; OUT="$(sqlite3 -bail "$DB" ".read references/schema.sql" 2>&1)"; RC=$?
expect_refused database_not_empty "schema refuses a database that already has tables"
step setup-check '{}'; expect_has "setup-check passes" '"result":"ok"'

step add-repo '{"step":"add-repo","repo":"'$R'"}'; expect_has "add-repo registers the repository" "\"repo\":\"$R\""
for bad in "../etc" "a/b/c" "-x/y" "a/.git" "a/b;rm"; do
  step add-repo '{"step":"add-repo","repo":"'$bad'"}'; expect_fail "add-repo refuses $bad"
done
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused fetch_missing_or_for_another_repo "ingest refuses before a fetch"
step ingest '{"step":"ingest","repo":"other/repo"}'; expect_refused repo_not_registered "ingest refuses an unregistered repository"
step run-start '{"step":"run-start","kind":"scheduled"}'; expect_has "run-start" '"run_id":1'

serve "$FIXTURES/example"
fetch $R; expect_has "fetch reads both bots" '"dependabot":6,"renovate":7'
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
expect_has "ingest reads 6 Dependabot PRs" '"bot":"dependabot","read_count":6,"new_prs":6,"limit_reached":0,"waiting":6'
expect_has "ingest reads 7 Renovate PRs" '"bot":"renovate","read_count":7,"new_prs":7,"limit_reached":0,"waiting":7'

# The lane floor comes from facts only.
lane() { q "SELECT l.lane FROM pr_lane l JOIN prs p ON p.id = l.pr_id WHERE p.number = $1;"; }
lane 101; expect_eq "minor bump with green CI looks safe" "looks-safe"
lane 102; expect_eq "major bump needs a look" "needs-a-look"
lane 103; expect_eq "grouped patch bumps look safe" "looks-safe"
lane 104; expect_eq "docker digest updates look safe" "looks-safe"
lane 105; expect_eq "a 0.x minor bump needs a look" "needs-a-look"
lane 106; expect_eq "failing CI blocks" "blocked-by-ci"
lane 201; expect_eq "renovate patch looks safe, its configuration text is ignored" "looks-safe"
lane 202; expect_eq "CI still running needs a look" "needs-a-look"
lane 203; expect_eq "lock file maintenance needs a look" "needs-a-look"
lane 206; expect_eq "a runtime floor note needs a look" "needs-a-look"
lane 207; expect_eq "no CI at all needs a look" "needs-a-look"
q "SELECT reasons FROM pr_lane l JOIN prs p ON p.id = l.pr_id WHERE p.number = 202;"; expect_eq "reasons name why" '["ci-pending"]'
q "SELECT failing_checks FROM prs WHERE number = 106;"; expect_eq "failing checks are named" '["example/status","test"]'
q "SELECT json_extract(updates,'\$[0].bump') || ' ' || json_extract(updates,'\$[0].ecosystem') FROM prs WHERE number = 105;"; expect_eq "parsed updates are stored" "minor go"

# A second read of the same data adds nothing.
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "same read adds no PRs" '"new_prs":0'

# Bad input stops the step and changes nothing.
D="inbox/${R/\//__}"
cp "$D/prs.json" "$SCRATCH/prs.good"
edit_prs() { node -e 'const fs=require("fs");const f=process.argv[1];let a=JSON.parse(fs.readFileSync(f,"utf8"));'"$1"';fs.writeFileSync(f,JSON.stringify(a));' "$D/prs.json"; }
edit_prs 'a[0].number="101"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused pr_number_not_integer "ingest refuses a number that is a string"
cp "$SCRATCH/prs.good" "$D/prs.json"; edit_prs 'a[0].headRefOid="abc"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused head_sha_not_40_hex "ingest refuses a bad head SHA"
cp "$SCRATCH/prs.good" "$D/prs.json"; edit_prs 'a[0].bot="someone"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused pr_not_from_a_known_bot "ingest refuses a PR from another author"
cp "$SCRATCH/prs.good" "$D/prs.json"; edit_prs 'a[0].ci="green"'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused ci_state_unknown "ingest refuses an unknown CI state"
cp "$SCRATCH/prs.good" "$D/prs.json"
q "SELECT count(*) FROM reads;"; expect_eq "refused ingests record no read" "4"

# A PR that a full read no longer lists is GONE; a read at its limit marks nothing.
edit_served dependabot 'a.filter(x=>x.number!==106)'
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
q "SELECT state FROM prs WHERE number=106;"; expect_eq "a merged or closed PR is GONE" "GONE"
serve "$FIXTURES/example"
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
q "SELECT state FROM prs WHERE number=106;"; expect_eq "a reopened PR is OPEN again" "OPEN"
edit_served renovate 'a.filter(x=>x.number!==207)'
fetch $R
node -e 'const fs=require("fs");const f=process.argv[1];const s=JSON.parse(fs.readFileSync(f,"utf8"));s.limit=6;fs.writeFileSync(f,JSON.stringify(s));' "$D/fetch.json"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
[[ "$OUT" == *'"bot":"renovate","read_count":6,"new_prs":0,"limit_reached":1'* ]] && ok "a read that returns its limit is flagged" || bad "a read that returns its limit is flagged"
q "SELECT state FROM prs WHERE number=207;"; expect_eq "a read at its limit marks nothing GONE" "OPEN"
serve "$FIXTURES/example"; fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'

# to-review: open PRs with an unreviewed head, oldest change first.
step to-review '{"step":"to-review","limit":51}'; expect_refused limit_not_1_to_50 "to-review refuses a limit over 50"
step to-review '{"step":"to-review","limit":1}'
[[ "$OUT" == *'"lane_floor":"looks-safe"'* ]] && ok "to-review shows the lane floor" || bad "to-review shows the lane floor"
step to-review '{"step":"to-review","limit":50}'
[[ "$OUT" == *'"evidence":'* && "$OUT" != *'"body"'* ]] && ok "to-review returns evidence lines and never the PR body" || bad "to-review returns evidence lines and never the PR body"
FIRST="$(print -r -- "$OUT" | sed -n 's/.*"pr_id":\([0-9]*\).*/\1/p' | head -1)"
HEAD="$(print -r -- "$OUT" | sed -n 's/.*"head_sha":"\([0-9a-f]*\)".*/\1/p' | head -1)"
q "SELECT number FROM prs WHERE id=$FIRST;"; expect_eq "to-review starts with the oldest change" "101"

# save-review: stricter is fine, looser is refused, approve only for looks-safe.
SR='{"step":"save-review","run_id":1,"pr_id":'
P102="$(sqlite3 "$DB" "SELECT id FROM prs WHERE number=102;")"; H102="$(sqlite3 "$DB" "SELECT head_sha FROM prs WHERE number=102;")"
step save-review "$SR$P102"',"head_sha":"'$H102'","verdict":"looks-safe","note":"Notes look harmless."}'; expect_refused verdict_looser_than_the_facts "a verdict looser than the facts is refused"
step save-review "$SR$P102"',"head_sha":"'$H102'","verdict":"needs-a-look","note":"Timeout default changed.","suggested_action":"approve"}'; expect_refused approve_suggested_for_a_pr_that_needs_a_look "approve is refused as a suggestion for a PR that needs a look"
step save-review "$SR$FIRST"',"head_sha":"'$H102'","verdict":"looks-safe","note":"x"}'; expect_refused head_changed_since_to_review "save-review refuses a head it was not shown"
step save-review "$SR$FIRST"',"head_sha":"'$HEAD'","verdict":"maybe","note":"x"}'; expect_fail "save-review refuses an unknown verdict"
step save-review "$SR$FIRST"',"head_sha":"'$HEAD'","verdict":"needs-a-look","note":"Stricter is allowed."}'; expect_has "a stricter verdict is allowed" '"verdict":"needs-a-look"'
step save-review "$SR$P102"',"head_sha":"'$H102'","verdict":"needs-a-look","note":"Timeout default changed in 3.0."}'; expect_rc0 "save-review records a review"
q "SELECT count(*) FROM prs WHERE id IN ($FIRST,$P102) AND head_sha <> reviewed_head;"; expect_eq "reviewed PRs leave the queue" "0"

# A new head from the bot queues the PR again.
edit_served dependabot 'a.map(x=>x.number===102?{...x,headRefOid:"f".repeat(40)}:x)'
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
q "SELECT head_sha <> reviewed_head FROM prs WHERE id=$P102;"; expect_eq "a pushed PR is queued again" "1"

step run-end '{"step":"run-end","run_id":1,"note":"fetch failed for other/repo: HTTP 404"}'; expect_has "run-end" '"ended_at":"'
step run-end '{"step":"run-end","run_id":1}'; expect_refused run_unknown_or_ended "run-end refuses an ended run"
step_raw digest '{"step":"digest","run_id":1}'; expect_rc0 "digest runs"
print -r -- "$OUT" > "$SCRATCH/digest.json"
dj() { OUT="$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log('"$1"')' "$SCRATCH/digest.json" 2>&1)"; RC=$?; }
dj '1'; expect_eq "digest prints one plain JSON object" "1"
dj 'd.lanes["blocked-by-ci"].map(x=>x.number).join(",")'; expect_eq "digest blocked lane" "106"
dj 'd.lanes["looks-safe"].map(x=>x.number).join(",")'; expect_eq "digest looks-safe lane" "103,104,201"
dj 'd.lanes["needs-a-look"].map(x=>x.number).join(",")'; expect_eq "digest needs-a-look lane, a stricter review moves 101 here" "101,102,105,202,203,204,205,206,207"
dj 'JSON.stringify(d.same_package)'; expect_eq "packages bumped by more than one PR" '[{"repo":"example-org/example-repo","package":"example-glob","prs":[204,205]}]'
dj 'd.run.note'; expect_eq "the run note carries fetch errors" "fetch failed for other/repo: HTTP 404"
dj 'd.reads.some(r=>r.limit_reached===1)'; expect_eq "digest reads show the gap" "true"
step_raw digest '{"step":"digest","run_id":9}'; expect_refused unknown_run "digest refuses an unknown run"
finish
