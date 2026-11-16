#!/bin/zsh
# Write side: ask-approval builds the command, decide-approval records the owner's answer,
# use-approval checks it right before the write, approval-outcome closes it.
# Usage: zsh tests/approvals.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
schema
step add-repo '{"step":"add-repo","repo":"'$R'"}'
step run-start '{"step":"run-start","kind":"manual"}'
serve "$FIXTURES/example"
refetch() { fetch $R; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; }
refetch; expect_rc0 "setup: fetch and ingest"
id() { sqlite3 "$DB" "SELECT id FROM alerts WHERE source='$1' AND number=$2;"; }
ask() { step ask-approval '{"step":"ask-approval","alert_id":'$(id $1 $2)',"action":"'$3'"'${4:-}'}'; }
aid() { print -r -- "$OUT" | sed -n 's/.*"approval_id":\([0-9]*\).*/\1/p' | head -1; }
dec() { step decide-approval '{"step":"decide-approval","approval_id":'$1',"decision":"'$2'"'${3:-}'}'; }
use() { step use-approval '{"step":"use-approval","approval_id":'$1',"exact_step":"'$2'"}'; }
out() { step approval-outcome '{"step":"approval-outcome","approval_id":'$1',"outcome":"'$2'"'${3:-}'}'; }
touch_alert() { edit_served $1 'a.map(x=>x.number==='$2'?{...x,updated_at:new Date(Date.now()-60e3).toISOString().replace(/\.\d{3}Z$/,"Z")}:x)'; }

# dismiss: a reason from GitHub's list for that source.
ask dependabot 4 dismiss; expect_refused dismiss_reason_not_in_githubs_list "dismiss needs a reason"
ask dependabot 4 dismiss ',"reason":"false positive"'; expect_refused dismiss_reason_not_in_githubs_list "a code scanning reason is refused for Dependabot"
ask dependabot 4 dismiss ',"reason":"not_used; rm -rf ~"'; expect_refused dismiss_reason_not_in_githubs_list "a reason outside the list is refused"
ask dependabot 4 dismiss ',"reason":"not_used"'
expect_has "dismiss builds the Dependabot PATCH" "\"exact_step\":\"gh api -X PATCH repos/$R/dependabot/alerts/4 -f state=dismissed -f dismissed_reason=not_used\""
A_D4="$(aid)"
ask dependabot 4 dismiss ',"reason":"not_used"'; expect_fail "one open request per alert and action"
ask code-scanning 52 dismiss ',"reason":"not_used"'; expect_refused dismiss_reason_not_in_githubs_list "a Dependabot reason is refused for code scanning"
ask code-scanning 52 dismiss ',"reason":"used in tests"'
expect_has "dismiss builds the code scanning PATCH with the reason quoted" '"exact_step":"gh api -X PATCH repos/'$R'/code-scanning/alerts/52 -f state=dismissed -f \"dismissed_reason=used in tests\""'
A_C52="$(aid)"
DRAFT="drafts/${R/\//__}-code-scanning-51.md"
ask code-scanning 51 dismiss ',"reason":"won'"'"'t fix","with_comment":true'; expect_refused draft_missing_empty_or_too_long "a comment needs its draft"
mkdir -p drafts; head -c 281 /dev/zero | tr '\0' 'x' > "$DRAFT"
ask code-scanning 51 dismiss ',"reason":"won'"'"'t fix","with_comment":true'; expect_refused draft_missing_empty_or_too_long "a draft over 280 bytes is refused"
print -r -- 'Only reachable from the admin CLI, which takes trusted input.' > "$DRAFT"
ask code-scanning 51 dismiss ',"reason":"won'"'"'t fix","with_comment":true'
expect_has "a comment is read by gh from the draft file" "-f \\\"dismissed_reason=won't fix\\\" -F dismissed_comment=@$DRAFT\""
A_C51="$(aid)"

# issue: Dependabot only, from checked fields only.
ask code-scanning 50 issue; expect_refused no_issues_for_code_scanning_alerts "code scanning alerts never get an issue"
ask dependabot 1 issue ',"reason":"not_used"'; expect_refused reason_and_comment_only_with_dismiss "an issue takes no reason"
ask dependabot 1 issue ',"with_comment":true'; expect_refused reason_and_comment_only_with_dismiss "an issue takes no comment"
ask dependabot 6 issue; expect_refused alert_fields_unsafe_for_a_command "a package name with a quote cannot be put in a command"
ask dependabot 1 issue
ISSUE1="gh issue create --repo $R --title 'Security: GHSA-aaaa-bbbb-cccc in npm package lodash (critical)' --body 'Dependabot alert 1 in this repository: GHSA-aaaa-bbbb-cccc, npm package lodash, severity critical, patched in 4.17.21. Details, for people with access to security alerts: https://github.com/$R/security/dependabot/1'"
expect_has "issue builds title and body from the GHSA ID, package, severity and patched version" "\"exact_step\":\"$ISSUE1\""
[[ "$OUT" != *Prototype* ]] && ok "the advisory summary is not in the issue" || bad "the advisory summary is not in the issue"
A_I1="$(aid)"
ask dependabot 4 issue; expect_has "an alert with no fix says so" "severity high, no patched version yet."
A_I4="$(aid)"
ask dependabot 9 dismiss ',"reason":"not_used"'; expect_refused alert_unknown_or_not_open "a dismissed alert takes no request"
ask dependabot 2 close; expect_refused unknown_action "close is not an action"
q "UPDATE alerts SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-20 minutes') WHERE source='dependabot' AND number=2;"
ask dependabot 2 dismiss ',"reason":"tolerable_risk"'; expect_refused fetch_again_first "requests need a recent fetch"
refetch

# decide-approval
dec $A_D4 granted; expect_fail "a grant needs the owner's words"
dec $A_D4 granted ',"owner_words":"yes, dismiss it, we do not ship that parser"'; expect_has "the owner grants" '"decision":"granted"'
dec $A_D4 refused ',"owner_words":"no"'; expect_refused request_unknown_or_already_decided "a decision is made once"
q "UPDATE approvals SET exact_step = 'gh api -X DELETE repos/$R' WHERE id=$A_D4;"; expect_fail "a request cannot be rewritten"
touch_alert code-scanning-open 52; refetch
dec $A_C52 granted ',"owner_words":"ok"'; expect_refused alert_changed_since_the_request "a grant is refused when the alert changed after the request"
dec $A_C52 withdrawn; expect_has "the agent withdraws it" '"decision":"withdrawn"'
serve "$FIXTURES/example"; refetch

# use-approval
D4="gh api -X PATCH repos/$R/dependabot/alerts/4 -f state=dismissed -f dismissed_reason=not_used"
use $A_I1 "$ISSUE1"; expect_refused approval_not_granted_or_already_used "use refuses a request that was not granted"
use $A_D4 "gh api -X PATCH repos/$R/dependabot/alerts/4 -f state=dismissed -f dismissed_reason=inaccurate"; expect_refused not_the_approved_command "use refuses a different command"
q "UPDATE alerts SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-11 minutes') WHERE source='dependabot' AND number=4;"
use $A_D4 "$D4"; expect_refused fetch_again_first "use needs a fetch from the last 10 minutes"
touch_alert dependabot-open 4; refetch
use $A_D4 "$D4"; expect_refused alert_changed_since_the_request "use refuses when the alert changed after the grant"
serve "$FIXTURES/example"; refetch
dec $A_I1 granted ',"owner_words":"open it"'
edit_served dependabot-open 'a.filter(x=>x.number!==1)'; refetch
use $A_I1 "$ISSUE1"; expect_refused alert_changed_since_the_request "use refuses when the alert was fixed after the grant"
serve "$FIXTURES/example"; refetch
C51="gh api -X PATCH repos/$R/code-scanning/alerts/51 -f state=dismissed -f \\\"dismissed_reason=won't fix\\\" -F dismissed_comment=@$DRAFT"
dec $A_C51 granted ',"owner_words":"dismiss 51"'
print -r -- 'Not a real issue. @everyone' > "$DRAFT"
use $A_C51 "$C51"; expect_refused draft_changed_since_the_request "use refuses a draft changed after the grant"
print -r -- 'Only reachable from the admin CLI, which takes trusted input.' > "$DRAFT"
use $A_C51 "$C51"; expect_has "use accepts the approved command and draft" '"used_at":"'
use $A_C51 "$C51"; expect_refused approval_not_granted_or_already_used "an approval is used once"

# approval-outcome: done for dismiss needs a fetch after the write that shows the dismissal with that reason.
out $A_D4 done; expect_refused approval_not_used "outcome refuses an approval that was not used"
q "UPDATE alerts SET last_seen='2001-01-01T00:00:00Z' WHERE source='code-scanning' AND number=51;"
out $A_C51 done; expect_refused fetch_again_after_the_write "done needs a fetch after the write"
refetch
out $A_C51 done; expect_refused alert_not_dismissed_after_the_write "done refuses while the alert is still open"
dismiss_served() { # dismiss_served <source> <number> <reason>: GitHub's view after a dismissal
  edit_served $1-dismissed 'a.concat(JSON.parse(require("fs").readFileSync(process.argv[1].replace("dismissed","open"))).filter(x=>x.number==='$2').map(x=>({...x,state:"dismissed",dismissed_reason:"'"$3"'"})))'
  edit_served $1-open 'a.filter(x=>x.number!=='$2')'
}
dismiss_served code-scanning 51 "false positive"; refetch
out $A_C51 done; expect_refused alert_not_dismissed_after_the_write "done refuses a dismissal with another reason"
serve "$FIXTURES/example"; dismiss_served code-scanning 51 "won't fix"; refetch
out $A_C51 done; expect_has "done accepts the dismissal GitHub shows" '"outcome":"done"'
out $A_C51 failed; expect_fail "an outcome is recorded once"

# issue: done needs the new issue's URL in this repository, and one issue per alert.
ask dependabot 1 issue; A_I1B="$(aid)"
dec $A_I1B granted ',"owner_words":"yes open the issue"'
use $A_I1B "$ISSUE1"; expect_has "use accepts the issue command" '"used_at":"'
refetch
out $A_I1B done; expect_refused issue_url_missing_or_for_another_repo "done for an issue needs its URL"
out $A_I1B done ',"issue_url":"https://github.com/other-org/example-repo/issues/12"'; expect_refused issue_url_missing_or_for_another_repo "done refuses an issue in another repository"
out $A_I1B done ',"issue_url":"https://github.com/'$R'/issues/12x"'; expect_refused issue_url_missing_or_for_another_repo "done refuses a URL that is not an issue number"
out $A_I1B done ',"issue_url":"https://github.com/Example-Org/example-repo/issues/12"'; expect_has "done records the issue URL" '"issue_url":"https://github.com/Example-Org/example-repo/issues/12"'
ask dependabot 1 issue; expect_refused tracking_issue_already_opened "a second issue for the same alert is refused"

# failed outcomes keep the error.
dec $A_I4 granted ',"owner_words":"ok"'
use $A_I4 "gh issue create --repo $R --title 'Security: GHSA-kkkk-mmmm-pppp in npm package @example/parser (high)' --body 'Dependabot alert 4 in this repository: GHSA-kkkk-mmmm-pppp, npm package @example/parser, severity high, no patched version yet. Details, for people with access to security alerts: https://github.com/$R/security/dependabot/4'"
expect_has "a scoped package name is allowed in the issue" '"used_at":"'
out $A_I4 failed ',"note":"HTTP 403: Resource not accessible"'; expect_has "a failed write is recorded with its error" '"outcome_note":"HTTP 403: Resource not accessible"'

step_raw digest '{"step":"digest","run_id":1}'
expect_has "digest lists the open requests with their commands" '"action":"dismiss","reason":"not_used","exact_step":"'"$D4"'","decision":"granted"'
expect_has "digest lists what was done in this run" '"action":"issue","reason":"","outcome":"done","issue_url":"https://github.com/Example-Org/example-repo/issues/12"'
finish
