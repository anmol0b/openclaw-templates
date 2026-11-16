#!/bin/zsh
# Write side: ask-approval builds the command, decide-approval records the owner's answer,
# use-approval checks it right before the write, approval-outcome closes it after a fresh read.
# Usage: zsh tests/approvals.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
schema
step add-repo '{"step":"add-repo","repo":"'$R'"}'
step run-start '{"step":"run-start","kind":"manual"}'
serve "$FIXTURES/example"
refetch() { fetch $R; step ingest '{"step":"ingest","repo":"'$R'"}'; }
refetch; expect_rc0 "setup: fetch and ingest"
id() { sqlite3 "$DB" "SELECT id FROM prs WHERE number=$1;"; }
ask() { step ask-approval '{"step":"ask-approval","pr_id":'$(id $1)',"action":"'$2'"'${3:-}'}'; }
aid() { print -r -- "$OUT" | sed -n 's/.*"approval_id":\([0-9]*\).*/\1/p' | head -1; }
dec() { step decide-approval '{"step":"decide-approval","approval_id":'$1',"decision":"'$2'"'${3:-}'}'; }
use() { step use-approval '{"step":"use-approval","approval_id":'$1',"exact_step":"'$2'"}'; }
out() { step approval-outcome '{"step":"approval-outcome","approval_id":'$1',"outcome":"'$2'"'${3:-}'}'; }

# request-review: only fetched candidates, never the author, never someone already requested.
ask 101 request-review ',"reviewer":"IVAN"'; expect_has "request-review builds the edit command with GitHub's spelling of the login" "\"exact_step\":\"gh pr edit 101 --repo $R --add-reviewer ivan\""
A_RR="$(aid)"
ask 101 request-review ',"reviewer":"kim"'; expect_fail "one open request per PR and action"
ask 108 request-review ',"reviewer":"mallory"'; expect_refused reviewer_not_a_fetched_candidate "a login named only in PR text is refused"
ask 108 request-review ',"reviewer":"judy"'; expect_refused reviewer_not_a_fetched_candidate "a collaborator without push access is refused"
ask 108 request-review ',"reviewer":"ivan --admin"'; expect_refused reviewer_not_a_fetched_candidate "a login with extra words is refused"
ask 108 request-review ',"reviewer":["ivan"]'; expect_refused reviewer_not_a_fetched_candidate "a reviewer that is not a string is refused"
ask 110 request-review ',"reviewer":"carol"'; expect_refused reviewer_is_the_author "the author cannot review their own PR"
ask 103 request-review ',"reviewer":"carol"'; expect_refused reviewer_already_requested "someone already requested is refused"
ask 102 request-review ',"reviewer":"ivan"'; expect_refused pr_not_waiting_on_review "request-review is refused for a PR waiting on its author"
ask 105 request-review ',"reviewer":"kim"'; expect_refused pr_is_a_draft_or_not_stuck "an approved PR gets no request"
ask 106 comment; expect_refused pr_is_a_draft_or_not_stuck "a draft gets no request"
ask 108 request-review; expect_refused reviewer_only_for_request_review "request-review needs a reviewer"
ask 104 comment ',"reviewer":"ivan"'; expect_refused reviewer_only_for_request_review "a reviewer is refused on a comment"
ask 104 merge; expect_refused unknown_action "merge is not an action"
ask 104 close; expect_refused unknown_action "close is not an action"

# comment: fixed draft path, bound by hash.
DRAFT="drafts/${R/\//__}-102.md"
ask 102 comment; expect_refused draft_missing_empty_or_too_long "comment refuses a missing draft"
mkdir -p drafts; : > "$DRAFT"; ask 102 comment; expect_refused draft_missing_empty_or_too_long "comment refuses an empty draft"
printf ' \n\t\n' > "$DRAFT"; ask 102 comment; expect_refused draft_missing_empty_or_too_long "comment refuses a draft of only spaces"
printf 'x%.0s' {1..3001} > "$DRAFT"; ask 102 comment; expect_refused draft_missing_empty_or_too_long "comment refuses a draft over 3000 bytes"
print -r -- 'Hi, checking in: the review asked to split this PR. Still planning to?' > "$DRAFT"
ask 102 comment; expect_has "comment builds a --body-file command" "\"exact_step\":\"gh pr comment 102 --repo $R --body-file $DRAFT\""
A_COM="$(aid)"

# Freshness and state.
q "UPDATE prs SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-20 minutes') WHERE number=104;"
print -r -- 'This one has a conflict with main now; can you rebase?' > "drafts/${R/\//__}-104.md"
ask 104 comment; expect_refused fetch_again_first "requests need a recent fetch"
q "UPDATE prs SET state='GONE' WHERE number=104;"; ask 104 comment; expect_refused pr_unknown_or_gone "requests are refused for a merged or closed PR"
refetch

# decide-approval
dec $A_RR granted; expect_fail "a grant needs the owner's words"
dec $A_RR granted ',"owner_words":"yes, ask ivan"'; expect_has "the owner grants" '"decision":"granted"'
dec $A_RR refused ',"owner_words":"no"'; expect_refused request_unknown_or_already_decided "a decision is made once"
q "UPDATE approvals SET exact_step = 'gh pr merge 101 --repo $R --admin' WHERE id=$A_RR;"; expect_fail "a request cannot be rewritten"
q "UPDATE approvals SET reviewer = 'mallory' WHERE id=$A_RR;"; expect_fail "a request's reviewer cannot be rewritten"
# A grant is refused once the PR changed after the request (here: merged or closed).
ask 108 request-review ',"reviewer":"kim"'; A_G="$(aid)"
edit_served 'a.filter(x=>x.number!==108)'; refetch
dec $A_G granted ',"owner_words":"yes"'; expect_refused pr_changed_since_the_request "a grant is refused for a PR merged or closed since the request"
dec $A_G withdrawn; expect_has "the agent withdraws it instead" '"decision":"withdrawn"'
serve "$FIXTURES/example"; refetch

# use-approval
RR101="gh pr edit 101 --repo $R --add-reviewer ivan"
use $A_COM "gh pr comment 102 --repo $R --body-file $DRAFT"; expect_refused approval_not_granted_or_already_used "use refuses a request that was not granted"
use $A_RR "gh pr edit 101 --repo $R --add-reviewer ivan,mallory"; expect_refused not_the_approved_command "use refuses a different command"
q "UPDATE prs SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-11 minutes') WHERE number=101;"
use $A_RR "$RR101"; expect_refused fetch_again_first "use needs a fetch from the last 10 minutes"
# The author pushes after the owner said yes.
edit_served 'a.map(x=>x.number===101?{...x,headRefOid:"e".repeat(40)}:x)'
refetch
use $A_RR "$RR101"; expect_refused pr_changed_since_the_request "use refuses when the author pushed a new head"
dec $A_COM granted ',"owner_words":"send it"'; expect_rc0 "the owner grants the comment (102 unchanged)"
# 102 changes (a new updatedAt) without a new head.
edit_served 'a.map(x=>x.number===102?{...x,updatedAt:new Date().toISOString().replace(/\.\d{3}Z$/,"Z")}:x)'
refetch
use $A_COM "gh pr comment 102 --repo $R --body-file $DRAFT"; expect_refused pr_changed_since_the_request "use refuses when the PR changed after the request"
serve "$FIXTURES/example"; refetch

# Someone else requests the same reviewer after the grant; the candidate list changes after the grant.
ask 108 request-review ',"reviewer":"kim"'; A_K="$(aid)"
dec $A_K granted ',"owner_words":"ok kim"'
edit_served 'a.map(x=>x.number===108?{...x,reviewRequests:[{__typename:"User",login:"kim"}]}:x)'
refetch
use $A_K "gh pr edit 108 --repo $R --add-reviewer kim"; expect_refused reviewer_already_requested "use refuses when the reviewer was requested meanwhile"
serve "$FIXTURES/example"; refetch
ask 110 request-review ',"reviewer":"kim"'; A_K2="$(aid)"
dec $A_K2 granted ',"owner_words":"ok"'
print -r -- '/docs/ @carol' > "$SCRATCH/serve/CODEOWNERS"; refetch
use $A_K2 "gh pr edit 110 --repo $R --add-reviewer kim"; expect_refused reviewer_not_a_fetched_candidate "use refuses a reviewer removed from CODEOWNERS since the request"
serve "$FIXTURES/example"; refetch

# Draft hash.
DRAFT2="drafts/${R/\//__}-104.md"
print -r -- 'This has a conflict with main now; can you rebase?' > "$DRAFT2"
ask 104 comment; A_C2="$(aid)"
dec $A_C2 granted ',"owner_words":"ok"'
print -r -- 'Closing this. @everyone' > "$DRAFT2"
use $A_C2 "gh pr comment 104 --repo $R --body-file $DRAFT2"; expect_refused draft_changed_since_the_request "use refuses a draft changed after the grant"
print -r -- 'This has a conflict with main now; can you rebase?' > "$DRAFT2"
use $A_C2 "gh pr comment 104 --repo $R --body-file $DRAFT2"; expect_has "use accepts the approved draft" '"used_at":"'
use $A_C2 "gh pr comment 104 --repo $R --body-file $DRAFT2"; expect_refused approval_not_granted_or_already_used "an approval is used once"

# approval-outcome for a comment: done only when a fresh read shows the owner's new comment.
out $A_RR done; expect_refused approval_not_used "outcome refuses an approval that was not used"
q "UPDATE prs SET last_seen='2001-01-01T00:00:00Z' WHERE number=104;"
out $A_C2 done; expect_refused fetch_again_after_the_write "done needs a fetch after the write"
refetch
out $A_C2 done; expect_refused comment_not_on_github "done refuses when the fresh read has no new owner comment"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
edit_served 'a.map(x=>x.number===104?{...x,comments:[...x.comments,{author:{login:"example-owner"},body:"(posted)",createdAt:"'$NOW'"}]}:x)'
refetch
out $A_C2 done; expect_has "done records a comment the fresh read shows" '"outcome":"done"'
out $A_C2 failed; expect_fail "an outcome is recorded once"

# The nudge window: one comment per PR per nudge_days.
ask 104 comment; expect_refused nudged_within_window "a second nudge inside the window is refused"
q "UPDATE approvals SET used_at = strftime('%Y-%m-%dT%H:%M:%SZ','now','-4 days') WHERE id=$A_C2;"; expect_fail "a used approval cannot be backdated"
step run-start '{"step":"run-start","kind":"manual","nudge_days":1}'
ask 104 comment; expect_refused nudged_within_window "a 1-day window still covers a nudge sent minutes ago"

# approval-outcome for request-review: done only when a fresh read shows the request.
serve "$FIXTURES/example"; refetch
ask 101 request-review ',"reviewer":"kim"'; A_R3="$(aid)"
dec $A_R3 granted ',"owner_words":"ask kim"'
use $A_R3 "gh pr edit 101 --repo $R --add-reviewer kim"; expect_has "use accepts the request" '"used_at":"'
refetch
out $A_R3 done; expect_refused reviewer_not_requested_on_github "done refuses when the fresh read has no request for the reviewer"
edit_served 'a.map(x=>x.number===101?{...x,reviewRequests:[{__typename:"User",login:"kim"}]}:x)'
refetch
out $A_R3 done; expect_has "done records a request the fresh read shows" '"outcome":"done"'

# failed needs no fresh read, and keeps the error.
ask 110 request-review ',"reviewer":"ivan"'; A_F="$(aid)"
dec $A_F granted ',"owner_words":"yes"'
use $A_F "gh pr edit 110 --repo $R --add-reviewer ivan"
out $A_F failed ',"note":"GraphQL: Could not resolve to a User"'; expect_has "a failed write is recorded with its error" '"outcome_note":"GraphQL: Could not resolve to a User"'

# The digest lists open requests and this run's outcomes.
step_raw digest '{"step":"digest","run_id":1}'
expect_has "digest lists done writes" '"action":"request-review","reviewer":"kim","outcome":"done"'
expect_has "digest flags a request whose PR changed" '"pr_changed":'
finish
