#!/bin/zsh
# Write side: ask-approval builds the command, decide-approval records the owner's answer,
# use-approval checks it right before the write, approval-outcome closes it.
# Usage: zsh tests/approvals.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
schema
step add-repo '{"step":"add-repo","repo":"'$R'"}'
serve "$FIXTURES/example"
refetch() { fetch $R; step ingest '{"step":"ingest","repo":"'$R'"}'; }
refetch; expect_rc0 "setup: fetch and ingest"
id() { sqlite3 "$DB" "SELECT id FROM items WHERE number=$1;"; }
ask() { step ask-approval '{"step":"ask-approval","item_id":'$(id $1)',"action":"'$2'"'${3:-}'}'; }
aid() { print -r -- "$OUT" | sed -n 's/.*"approval_id":\([0-9]*\).*/\1/p' | head -1; }
dec() { step decide-approval '{"step":"decide-approval","approval_id":'$1',"decision":"'$2'"'${3:-}'}'; }
use() { step use-approval '{"step":"use-approval","approval_id":'$1',"exact_step":"'$2'"}'; }
out() { step approval-outcome '{"step":"approval-outcome","approval_id":'$1',"outcome":"'$2'"'${3:-}'}'; }
draft() { mkdir -p drafts; print -r -- "$2" > "drafts/${R/\//__}-$1.md"; }
NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# owner_comments <number>: GitHub now shows a new comment by the owner on that item.
owner_comments() { edit_served 'for (const n of [...r.pullRequests.nodes, ...r.issues.nodes]) if (n.number==='$1') { n.comments.nodes.push({viewerDidAuthor:true,createdAt:"'$(NOW)'"}); n.comments.totalCount++; n.updatedAt="'$(NOW)'"; }'; }

# welcome: newcomers only, once per person, a draft bound by hash.
ask 11 welcome; expect_refused draft_missing_empty_or_too_long "welcome refuses a missing draft"
draft 11 ""; ask 11 welcome; expect_refused draft_missing_empty_or_too_long "welcome refuses an empty draft"
draft 11 "$(printf 'x%.0s' {1..3001})"; ask 11 welcome; expect_refused draft_missing_empty_or_too_long "welcome refuses a draft over 3000 bytes"
draft 11 'Thanks for your first PR here! A maintainer will review it this week.'
ask 11 welcome; expect_has "welcome builds a --body-file command" "\"exact_step\":\"gh pr comment 11 --repo $R --body-file drafts/example-org__example-repo-11.md\""
W11="$(aid)"
ask 11 welcome; expect_fail "one open request per item and action"
draft 21 'Thanks for the report!'
ask 21 welcome; expect_refused welcome_already_requested_for_this_person "the same person on another item is not asked twice"
draft 14 'Hi'; ask 14 welcome; expect_refused author_not_a_newcomer "welcome refuses a CONTRIBUTOR"
draft 15 'Hi'; ask 15 welcome; expect_refused author_not_a_newcomer "welcome refuses a bot"
draft 17 'Hi'; ask 17 welcome; expect_refused author_not_a_newcomer "welcome refuses the owner's own PR"
draft 27 'Hi'; ask 27 welcome; expect_refused author_not_a_newcomer "welcome refuses a deleted account"
draft 13 'Hi'; ask 13 welcome; expect_refused owner_already_commented_here "welcome refuses an item the owner already answered"
draft 12 'Welcome!'; ask 12 welcome ',"label":"help wanted"'; expect_refused label_only_for_add_label "welcome takes no label"
ask 12 close; expect_refused unknown_action "close is not an action"
ask 12 merge; expect_refused unknown_action "merge is not an action"

# add-label: allowed by settings, present in the repository, on a candidate issue.
ask 22 add-label; expect_refused label_only_for_add_label "add-label needs a label"
ask 12 add-label ',"label":"help wanted"'; expect_refused action_not_for_this_kind "add-label is for issues only"
ask 22 add-label ',"label":"wontfix"'; expect_refused label_not_allowed "add-label refuses a label not in settings"
ask 22 add-label ',"label":"x'"'"'; rm -rf ~"'; expect_refused label_not_allowed "add-label refuses any other text"
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":["good first issue","help wanted","needs triage"]}'
ask 22 add-label ',"label":"needs triage"'; expect_refused label_not_in_repo "add-label refuses a label the repository does not have"
step add-repo '{"step":"add-repo","repo":"'$R'"}'
ask 26 add-label ',"label":"good first issue"'; expect_refused issue_already_has_label "add-label refuses a label the issue has"
ask 26 add-label ',"label":"help wanted"'; expect_refused issue_not_a_label_candidate "add-label refuses an issue that has an allowed label"
ask 23 add-label ',"label":"help wanted"'; expect_refused issue_not_a_label_candidate "add-label refuses an assigned issue"
ask 24 add-label ',"label":"help wanted"'; expect_refused issue_not_a_label_candidate "add-label refuses an issue with a linked PR"
ask 25 add-label ',"label":"help wanted"'; expect_refused issue_not_a_label_candidate "add-label refuses an issue with no real description"
ask 22 add-label ',"label":"good first issue"'
expect_has "add-label builds a quoted --add-label command" "\"exact_step\":\"gh issue edit 22 --repo $R --add-label 'good first issue'\""
L22="$(aid)"

# Freshness.
q "UPDATE items SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-20 minutes') WHERE number=12;"
ask 12 welcome; expect_refused fetch_again_first "requests need a recent fetch"
q "UPDATE items SET state='gone' WHERE number=27;"; ask 27 add-label ',"label":"help wanted"'; expect_refused item_unknown_or_gone "requests are refused for a closed item"
refetch
ask 12 welcome; W12="$(aid)"; expect_rc0 "welcome for a second person"

# decide-approval
dec $W11 granted; expect_fail "a grant needs the owner's words"
dec $W11 granted ',"owner_words":"yes, send it"'; expect_has "the owner grants" '"decision":"granted"'
dec $W11 refused ',"owner_words":"no"'; expect_refused request_unknown_or_already_decided "a decision is made once"
q "UPDATE approvals SET exact_step = 'gh pr close 11 --repo $R' WHERE id=$W11;"; expect_fail "a request cannot be rewritten"
edit_served 'r.pullRequests.nodes.find(n=>n.number===12).updatedAt="'$(NOW)'"'
refetch
dec $W12 granted ',"owner_words":"ok"'; expect_refused item_changed_since_the_request "a grant is refused when the item changed after the request"
dec $W12 withdrawn; expect_has "the agent withdraws a changed request" '"decision":"withdrawn"'
ask 12 welcome; W12="$(aid)"; dec $W12 granted ',"owner_words":"ok, welcome them"'; expect_rc0 "asked again and granted"

# use-approval
C11="gh pr comment 11 --repo $R --body-file drafts/example-org__example-repo-11.md"
use $L22 "gh issue edit 22 --repo $R --add-label 'good first issue'"; expect_refused approval_not_granted_or_already_used "use refuses a request that was not granted"
use $W11 "gh pr comment 11 --repo $R --body 'hi'"; expect_refused not_the_approved_command "use refuses a different command"
q "UPDATE items SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-11 minutes') WHERE number=11;"
use $W11 "$C11"; expect_refused fetch_again_first "use needs a fetch from the last 10 minutes"
refetch
draft 11 'Thanks for your first PR here! @everyone'
use $W11 "$C11"; expect_refused draft_changed_since_the_request "use refuses a draft changed after the grant"
draft 11 'Thanks for your first PR here! A maintainer will review it this week.'
# The person was welcomed some other way after the grant.
q "INSERT INTO welcomed (repo, login, item_id, approval_id, welcomed_at) VALUES ('$R', 'example-newbie-b', $(id 12), 0, 'x');"
use $W12 "gh pr comment 12 --repo $R --body-file drafts/example-org__example-repo-12.md"; expect_refused already_welcomed_in_this_repo "use refuses a welcome for someone welcomed since"
q "DELETE FROM welcomed;"
use $W11 "$C11"; expect_has "use accepts the approved welcome" '"used_at":"'
use $W11 "$C11"; expect_refused approval_not_granted_or_already_used "an approval is used once"

# approval-outcome: done must be visible in a read after the write.
out $W12 done; expect_refused approval_not_used "outcome refuses an approval that was not used"
q "UPDATE items SET last_seen='2001-01-01T00:00:00Z' WHERE number=11;"
out $W11 done; expect_refused fetch_again_after_the_write "done needs a fetch after the write"
refetch
out $W11 done; expect_refused welcome_not_seen_after_the_write "done needs the owner's new comment on the item"
owner_comments 11; refetch
out $W11 done; expect_has "done records the welcome" '"author_welcomed":1'
out $W11 failed; expect_fail "an outcome is recorded once"
q "SELECT login FROM welcomed;"; expect_eq "the person is recorded as welcomed in this repository" "example-newbie-a"
draft 21 'Thanks for the report!'; ask 21 welcome; expect_refused already_welcomed_in_this_repo "a welcomed person is never welcomed again here"
q "SELECT count(*) FROM newcomers WHERE waiting AND author='example-newbie-a';"; expect_eq "a welcomed person is no longer waiting on any item" "0"

# The label flow, end to end.
dec $L22 granted ',"owner_words":"label it"'
CL="gh issue edit 22 --repo $R --add-label 'good first issue'"
step add-repo '{"step":"add-repo","repo":"'$R'","allowed_labels":["help wanted"]}'
use $L22 "$CL"; expect_refused label_not_allowed "use refuses a label taken out of settings since"
step add-repo '{"step":"add-repo","repo":"'$R'"}'
edit_served 'r.labels.nodes=r.labels.nodes.filter(l=>l.name!=="good first issue");r.labels.totalCount--'; refetch
use $L22 "$CL"; expect_refused label_not_in_repo "use refuses a label deleted from the repository since"
serve "$FIXTURES/example"; refetch
use $L22 "$CL"; expect_has "use accepts the approved label" '"used_at":"'
out $L22 done; expect_refused label_not_on_the_issue_after_the_write "done needs the label on the issue"
edit_served 'const n=r.issues.nodes.find(n=>n.number===22);n.labels.nodes.push({name:"good first issue"});n.updatedAt="'$(NOW)'"'; refetch
out $L22 done; expect_has "done records the label" '"outcome":"done"'
q "SELECT count(*) FROM label_candidates WHERE number=22;"; expect_eq "a labeled issue is no longer a candidate" "0"

# A grant that went stale does not block the person; only one welcome per person is ever used.
serve "$FIXTURES/example"
edit_served 'r.issues.nodes.push({...r.issues.nodes.find(n=>n.number===21),number:28,author:{__typename:"User",login:"example-newbie-b"}});r.issues.totalCount++'
refetch
C12="gh pr comment 12 --repo $R --body-file drafts/example-org__example-repo-12.md"
draft 12 'Welcome!'
use $W12 "$C12"; expect_refused item_changed_since_the_request "a grant whose item changed cannot be used"
ask 12 welcome; W12B="$(aid)"; expect_has "a stale grant does not block a new request for the person" '"action":"welcome"'
draft 28 'Thanks for the report!'
ask 28 welcome; expect_refused welcome_already_requested_for_this_person "a pending welcome still blocks the same person's other items"
dec $W12B granted ',"owner_words":"send it"'; expect_rc0 "setup: grant the new welcome"
use $W12B "$C12"; expect_has "the new welcome is used" '"used_at":"'
q "INSERT INTO approvals (item_id, action, author, body_file, body_sha3, exact_step, seen_updated_at, seen_owner_comment_at, asked_at, decision, owner_words, decided_at)
   SELECT id, 'welcome', author, 'drafts/example-org__example-repo-28.md', hex(sha3(readfile('drafts/example-org__example-repo-28.md'), 256)),
          'gh issue comment 28 --repo $R --body-file drafts/example-org__example-repo-28.md', updated_at, '', 'x', 'granted', 'yes', 'x' FROM items WHERE number=28 RETURNING id;"
W28="$OUT"
use $W28 "gh issue comment 28 --repo $R --body-file drafts/example-org__example-repo-28.md"; expect_refused welcome_already_sent_for_this_person "a second grant for the same person is refused once one welcome was sent"

# A failed write is recorded with its error and frees the person for a new request.
out $W12B failed ',"note":"HTTP 403"'; expect_has "a failed write is recorded with its error" '"outcome_note":"HTTP 403"'
q "SELECT count(*) FROM welcomed WHERE login='example-newbie-b';"; expect_eq "a failed welcome does not count as welcomed" "0"
use $W28 "gh issue comment 28 --repo $R --body-file drafts/example-org__example-repo-28.md"; expect_has "after a failed welcome another grant for the person can be used" '"used_at":"'
finish
