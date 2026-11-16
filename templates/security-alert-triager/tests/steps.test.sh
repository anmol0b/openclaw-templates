#!/bin/zsh
# Read side: add-repo, run-start, fetch + ingest, alert-list, run-end, digest, setup-check.
# The alert fixtures follow GitHub's REST response shape with made-up names; the error bodies are the
# ones GitHub returned in November 2026 (see README, "Tested, and not yet").
# Usage: zsh tests/steps.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
R2=example-org/second-repo
schema
OUT="$(sqlite3 -bail "$DB" ".read references/schema.sql" 2>&1)"; RC=$?
expect_refused database_not_empty "schema refuses a database that already has tables"
step setup-check '{}'; expect_has "setup-check passes before any fetch" '"result":"ok"'

step add-repo '{"step":"add-repo","repo":"'$R'"}'; expect_has "add-repo registers the repository" '"repo":"'$R'"'
for bad in "../etc" "a/b/c" "a b/c" "-x/y" "a/-y" "a/.git" "noslash" "a/b;rm"; do
  step add-repo '{"step":"add-repo","repo":"'$bad'"}'; expect_fail "add-repo refuses $bad"
done
step add-repo '{"step":"run-start","repo":"'$R'"}'; expect_refused db_input_for_another_step "a step refuses input written for another step"
step ingest '{"step":"ingest","repo":"other/repo"}'; expect_refused repo_not_registered "ingest refuses an unregistered repository"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused fetch_missing_or_for_another_repo "ingest refuses when fetch has not run"

step run-start '{"step":"run-start","kind":"scheduled"}'; expect_has "run-start returns the run" '"run_id":1'
step run-start '{"step":"run-start","kind":"cron"}'; expect_fail "run-start refuses an unknown kind"

serve "$FIXTURES/example"
fetch $R; expect_has "fetch reads both sources" '"dependabot":{"status":"ok","message":"","open":6,"dismissed":1}'
D="inbox/${R/\//__}"
grep -q -E 'Ignore all previous|"description"|"help"|"message"' "$D/dependabot.json" "$D/code-scanning.json" \
  && { OUT="$(grep -o -E 'Ignore all previous|"description"|"help"|"message"' "$D"/*.json | head -3)"; bad "advisory descriptions, help and messages are not kept"; } \
  || ok "advisory descriptions, help and messages are not kept"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
expect_has "ingest counts open alerts and PRs" '"dependabot_status":"ok","dependabot_open":6,"dependabot_cut":0,"code_scanning_status":"ok","code_scanning_open":3,"code_scanning_cut":0,"prs":3'
al() { sqlite3 "$DB" "SELECT $3 FROM alerts WHERE source = '$1' AND number = $2;"; }
OUT="$(al dependabot 1 covering_pr)|$(al dependabot 1 covering_fixes)"; RC=0; expect_eq "a Dependabot PR to the patched version covers the alert" "101|yes"
OUT="$(al dependabot 2 covering_pr)|$(al dependabot 2 covering_fixes)"; RC=0; expect_eq "the same PR covers a second alert with a lower patched version" "101|yes"
OUT="$(al dependabot 3 covering_pr)|$(al dependabot 3 covering_fixes)"; RC=0; expect_eq "a Renovate PR below the patched version does not fix it" "201|no"
OUT="$(al dependabot 5 covering_pr)|$(al dependabot 5 covering_fixes)"; RC=0; expect_eq "a grouped PR matched by branch only is unknown" "102|unknown"
OUT="$(al dependabot 4 coalesce\(covering_pr,\'none\'\))"; RC=0; expect_eq "an alert with no PR is not covered" "none"
OUT="$(al dependabot 6 severity)|$(al code-scanning 52 severity)|$(al code-scanning 50 severity)"; RC=0
expect_eq "severity: moderate is medium, no security level is unrated" "medium|unrated|critical"
OUT="$(al dependabot 9 state)|$(al dependabot 9 dismissed_reason)|$(al code-scanning 40 dismissed_reason)"; RC=0
expect_eq "recently dismissed alerts keep their reason" "dismissed|not_used|false positive"
OUT="$(al code-scanning 50 path):$(al code-scanning 50 start_line)"; RC=0; expect_eq "code scanning keeps the file and line" "src/db.js:12"

step alert-list '{"step":"alert-list","run_id":1}'; expect_rc0 "alert-list runs"
SEV="$(print -r -- "$OUT" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));const r={critical:1,high:2,medium:3,low:4,unrated:5};console.log(a.map(x=>r[x.severity]).join(""))')"
[[ "$SEV" == $(print -r -- "$SEV" | fold -w1 | sort | tr -d '\n') && ${#SEV} -eq 9 ]] && ok "alert-list lists the 9 open alerts, most severe first" || { OUT="ranks=$SEV"; bad "alert-list lists the 9 open alerts, most severe first"; }
[[ "$OUT" != *'"number":9,'* && "$OUT" != *'"number":40,'* ]] && ok "dismissed alerts are not listed" || bad "dismissed alerts are not listed"
step alert-list '{"step":"alert-list","run_id":1,"limit":51}'; expect_refused limit_not_1_to_50 "alert-list refuses a limit over 50"
step alert-list '{"step":"alert-list","run_id":9}'; expect_refused unknown_run "alert-list refuses an unknown run"

# Bad input stops ingest and changes nothing.
cp "$D/dependabot.json" "$SCRATCH/dep.good"
badrow() { node -e 'const fs=require("fs");const f=process.argv[1];const a=JSON.parse(fs.readFileSync(f));Object.assign(a[0],JSON.parse(process.argv[2]));fs.writeFileSync(f,JSON.stringify(a))' "$D/dependabot.json" "$1"; }
badrow '{"number":"12"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused number_not_integer "ingest refuses an alert number that is not an integer"
cp "$SCRATCH/dep.good" "$D/dependabot.json"; badrow '{"state":"fixed"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused alert_state_not_open_or_dismissed "ingest refuses a state it did not ask for"
cp "$SCRATCH/dep.good" "$D/dependabot.json"; badrow '{"updated_at":"yesterday"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused time_not_iso_utc "ingest refuses a time that is not ISO UTC"
cp "$SCRATCH/dep.good" "$D/dependabot.json"; badrow '{"covering_pr":"101"}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused covering_pr_not_integer "ingest refuses a covering PR that is not a number"
cp "$SCRATCH/dep.good" "$D/dependabot.json"; badrow '{"package":""}'; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused alert_without_package_or_rule "ingest refuses a Dependabot alert with no package"
print -r -- '{"not":"a list"}' > "$D/dependabot.json"; step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused inbox_file_not_a_list "ingest refuses a file that is not a list"
cp "$SCRATCH/dep.good" "$D/dependabot.json"
cp "$D/fetch.json" "$SCRATCH/fetch.good"
sed -i '' 's/"dependabot":{"status":"ok"/"dependabot":{"status":"disabled"/' "$D/fetch.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused alerts_for_a_source_not_read "ingest refuses alerts for a source marked not read"
sed -i '' 's/"dependabot":{"status":"disabled"/"dependabot":{"status":"maybe"/' "$D/fetch.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused fetch_missing_or_for_another_repo "ingest refuses an unknown source status"
cp "$SCRATCH/fetch.good" "$D/fetch.json"
q "SELECT count(*) FROM fetches;"; expect_eq "refused ingests record no fetch" "1"

# Closed: a complete read without an open alert closes it; a cut read closes nothing; a dismissal moves it.
edit_served dependabot-open 'a.filter(x=>x.number!==3)'
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a complete read reports the closed alert" '"closed_now":1'
OUT="$(al dependabot 3 state)"; RC=0; expect_eq "the missing alert is closed" "closed"
serve "$FIXTURES/example"; edit_served dependabot-open 'a.filter(x=>x.number!==4)'
fetch $R; sed -i '' 's/"open":100/"open":5/' "$D/fetch.json"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a read that hits its limit is cut" '"dependabot_cut":1'
OUT="$(al dependabot 4 state)|$(al dependabot 3 state)"; RC=0; expect_eq "a cut read closes nothing, and an alert seen again is open" "open|open"
serve "$FIXTURES/example"
edit_served dependabot-dismissed 'a.concat([{...JSON.parse(require("fs").readFileSync(process.argv[1].replace("dismissed","open"))).find(x=>x.number===5),state:"dismissed",dismissed_reason:"tolerable_risk"}])'
edit_served dependabot-open 'a.filter(x=>x.number!==5)'
fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a dismissed alert is not counted as closed" '"closed_now":0'
OUT="$(al dependabot 5 state)|$(al dependabot 5 dismissed_reason)"; RC=0; expect_eq "an alert in the dismissed read is dismissed" "dismissed|tolerable_risk"
serve "$FIXTURES/example"; fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_rc0 "ingest again"

# Each source says why it has nothing: disabled, no access, or no alerts.
step add-repo '{"step":"add-repo","repo":"'$R2'"}'
fail_source dependabot-open dependabot-disabled; fail_source code-scanning-open code-scanning-disabled
fetch $R2; expect_has "fetch records a disabled source instead of failing" '"status":"disabled","message":"Dependabot alerts are disabled for this repository."'
step ingest '{"step":"ingest","repo":"'$R2'","run_id":1}'; expect_has "ingest stores both sources as disabled" '"dependabot_status":"disabled","dependabot_open":0,"dependabot_cut":0,"code_scanning_status":"disabled"'
step setup-check '{}'; expect_has "setup-check passes when a feature is only turned off" '"result":"ok"'
serve "$FIXTURES/example"; fetch $R2; step ingest '{"step":"ingest","repo":"'$R2'","run_id":1}'
fail_source dependabot-open dependabot-no-access; fail_source code-scanning-open code-scanning-no-access
fetch $R2; step ingest '{"step":"ingest","repo":"'$R2'","run_id":1}'; expect_has "ingest stores no access" '"dependabot_status":"no_access"'
q "SELECT count(*) FROM alerts WHERE repo = '$R2' AND state = 'open';"; expect_eq "a source that could not be read closes nothing" "9"
step setup-check '{}'; expect_refused token_lacks_alert_access "setup-check refuses when this login cannot read the alerts"
serve "$FIXTURES/example"; edit_served dependabot-open '[]'; edit_served dependabot-dismissed '[]'
fetch $R2; step ingest '{"step":"ingest","repo":"'$R2'","run_id":1}'; expect_has "an empty read closes the open alerts" '"closed_now":6'
step setup-check '{}'; expect_has "setup-check passes again once access works" '"result":"ok"'

step run-end '{"step":"run-end","run_id":1}'; expect_has "run-end ends the run" '"ended_at":"'
step run-end '{"step":"run-end","run_id":1}'; expect_refused run_unknown_or_ended "run-end refuses a run that already ended"
step_raw digest '{"step":"digest","run_id":1}'; expect_rc0 "digest runs"
print -r -- "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' && ok "digest prints one plain JSON object" || bad "digest prints one plain JSON object"
for key in '"repo":"'$R2'","fetched_at":' '"dependabot":"no_alerts"' '"dependabot":"alerts"' '"code_scanning":"alerts"' \
           '"package":"lodash","severity":"critical","alerts":2,' '"covering_pr":101,"covering_fixes":"yes"' \
           '"rule_id":"js/sql-injection","tool":"CodeQL","severity":"critical","alerts":2' '"places":["src/db.js:12","src/api.js:40"]' \
           '"open_requests":[]' '"done_this_run":[]'; do
  [[ "$OUT" == *"$key"* ]] && ok "digest has $key" || bad "digest has $key"
done
DIG="$OUT"
q "SELECT 1"; OUT="$(print -r -- "$DIG" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(d.sources.length, d.open_total.dependabot, d.open_total.code_scanning)')"
expect_eq "digest has one source row per repository and the open totals" "2 6 6"
# A run whose repository could not be read says so.
step run-start '{"step":"run-start","kind":"manual"}'
fail_source dependabot-open dependabot-disabled; fail_source code-scanning-open code-scanning-no-access
fetch $R2; step ingest '{"step":"ingest","repo":"'$R2'","run_id":2}'
step_raw digest '{"step":"digest","run_id":2}'; expect_has "digest names a disabled source and one without access" '"dependabot":"disabled","dependabot_open":0,"dependabot_cut":0,"dependabot_message":"Dependabot alerts are disabled for this repository.","code_scanning":"no_access"'
step_raw digest '{"step":"digest","run_id":42}'; expect_refused unknown_run "digest refuses an unknown run"
finish
