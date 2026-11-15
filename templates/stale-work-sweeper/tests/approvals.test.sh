#!/bin/zsh
# Write side: ask-approval builds the command, decide-approval records the owner's answer,
# use-approval checks it right before the write, approval-outcome closes it.
# Usage: zsh tests/approvals.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
schema
step add-repo '{"step":"add-repo","repo":"'$R'"}'
fetch() { inbox $R "$FIXTURES/example"; step ingest '{"step":"ingest","repo":"'$R'"}'; }
fetch; expect_rc0 "setup: fetch and ingest"
step run-start '{"step":"run-start","kind":"manual","stale_days":30}'; expect_rc0 "setup: a run, so the digest can show this run's deletions"
D="inbox/${R/\//__}"
id() { sqlite3 "$DB" "SELECT id FROM items WHERE ref = '$1';"; }
ask() { step ask-approval '{"step":"ask-approval","item_id":'$1',"action":"'$2'"'${3:-}'}'; }
aid() { print -r -- "$OUT" | sed -n 's/.*"approval_id":\([0-9]*\).*/\1/p' | head -1; }
MERGED=$(id feature/merged-old); SQUASH=$(id fix/squash-merged); UNMERGED=$(id wip/unmerged)
OPENPR=$(id feature/with-open-pr); PROT=$(id release/protected-merged); MAIN=$(id main)
TEAM=$(id teammate/merged); PR=$(id 201); OTHERPR=$(id 204); ISSUE=$(id 301); OTHERISSUE=$(id 304)
MERGED_SHA="$(sqlite3 "$DB" "SELECT head_oid FROM items WHERE id=$MERGED;")"

# delete-branch: the command is built here, only for a merged branch with a plain name.
ask $MERGED delete-branch
expect_has "delete-branch builds the exact command" "\"exact_step\":\"gh api -X DELETE repos/$R/git/refs/heads/feature/merged-old\""
A_DEL="$(aid)"
ask $MERGED delete-branch; expect_fail "one open request per item and action"
ask $SQUASH delete-branch; expect_has "a squash-merged branch can be deleted" '"action":"delete-branch"'
ask $UNMERGED delete-branch; expect_refused branch_not_merged_or_has_open_pr "an unmerged branch is never deleted"
ask $OPENPR delete-branch; expect_refused branch_not_merged_or_has_open_pr "a branch with an open PR is never deleted"
ask $PROT delete-branch; expect_refused branch_is_default_or_protected "a protected branch is never deleted"
ask $MAIN delete-branch; expect_refused branch_is_default_or_protected "the default branch is never deleted"
ask $TEAM delete-branch; expect_refused not_the_owners_item "another person's branch is refused"
for name in "bad name;rm -rf" "-starts-dash" "a/../b" "ends.lock" "has space" "quote'name"; do
  NID="$(sqlite3 "$DB" "SELECT id FROM items WHERE ref = '$(print -r -- "$name" | sed "s/'/''/g")';")"
  step ask-approval '{"step":"ask-approval","item_id":'$NID',"action":"delete-branch"}'
  expect_refused branch_name_unsafe "a branch named ${(q)name} is refused"
done
ask $MERGED close; expect_refused action_not_for_this_kind "a branch takes only delete-branch"
ask $PR unassign; expect_refused action_not_for_this_kind "a PR takes no unassign"
ask $PR delete-branch; expect_refused action_not_for_this_kind "a PR takes no delete-branch"
ask $ISSUE merge; expect_refused unknown_action "unknown actions are refused"

# Only the owner's own PRs and issues.
ask $OTHERPR close; expect_refused not_the_owners_item "another person's PR is refused"
ask $OTHERISSUE unassign; expect_refused not_the_owners_item "an issue assigned to someone else is refused"

# close, unassign, comment
ask $PR close; expect_has "close on a PR builds the command" "\"exact_step\":\"gh pr close 201 --repo $R\""
ask $PR close ',"close_reason":"completed"'; expect_fail "a second close request for the PR is refused while one is open"
ask $ISSUE close; expect_refused close_reason_not_allowed "close on an issue needs a reason"
ask $ISSUE close ',"close_reason":"duplicate'"'"'; rm -rf ~"'; expect_refused close_reason_not_allowed "close refuses any other reason"
ask $ISSUE close ',"close_reason":"not planned"'; expect_has "close on an issue builds the command" "\"exact_step\":\"gh issue close 301 --repo $R --reason 'not planned'\""
ask $ISSUE unassign; expect_has "unassign builds the command" "\"exact_step\":\"gh issue edit 301 --repo $R --remove-assignee @me\""
DRAFT="drafts/${R/\//__}-201.md"
ask $PR comment; expect_refused draft_missing_empty_or_too_long "comment refuses a missing draft"
mkdir -p drafts; : > "$DRAFT"
ask $PR comment; expect_refused draft_missing_empty_or_too_long "comment refuses an empty draft"
print -r -- 'Closing this for now; the approach moved to another branch.' > "$DRAFT"
ask $PR comment; expect_has "comment builds a --body-file command" "\"exact_step\":\"gh pr comment 201 --repo $R --body-file $DRAFT\""
A_COMMENT="$(aid)"

# Freshness
q "UPDATE items SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-20 minutes') WHERE id=$UNMERGED;"
step ask-approval '{"step":"ask-approval","item_id":'$(id 302)',"action":"unassign"}'; expect_rc0 "setup: a fresh item can be asked"
q "UPDATE items SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-20 minutes') WHERE id=$(id 302);"
q "DELETE FROM approvals WHERE action='unassign' AND item_id=$(id 302);"
ask $(id 302) unassign; expect_refused fetch_again_first "requests need a recent fetch"
fetch

# decide
dec() { step decide-approval '{"step":"decide-approval","approval_id":'$1',"decision":"'$2'"'${3:-}'}'; }
dec $A_DEL granted; expect_fail "a grant needs the owner's words"
dec $A_DEL granted ',"owner_words":"yes, delete it"'; expect_has "the owner grants" '"decision":"granted"'
dec $A_DEL refused ',"owner_words":"no"'; expect_refused request_unknown_or_already_decided "a decision is made once"
q "UPDATE approvals SET exact_step = 'gh repo delete $R --yes' WHERE id=$A_DEL;"; expect_fail "a request cannot be rewritten after it was asked"

# use: the branch head must not have moved.
use() { step use-approval '{"step":"use-approval","approval_id":'$1',"exact_step":"'$2'"}'; }
DEL_STEP="gh api -X DELETE repos/$R/git/refs/heads/feature/merged-old"
use $A_COMMENT "gh pr comment 201 --repo $R --body-file $DRAFT"; expect_refused approval_not_granted_or_already_used "use refuses a request that was not granted"
use $A_DEL "gh api -X DELETE repos/$R/git/refs/heads/main"; expect_refused not_the_approved_command "use refuses a different command"
q "UPDATE items SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-11 minutes') WHERE id=$MERGED;"
use $A_DEL "$DEL_STEP"; expect_refused fetch_again_first "use needs a fetch from the last 10 minutes"
node -e 'const fs=require("fs"),f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));const n=j.data.repository.refs.nodes.find(n=>n.name==="feature/merged-old");n.target.oid="f".repeat(40);fs.writeFileSync(f,JSON.stringify(j))' "$D/branches.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_rc0 "setup: the branch head moved"
use $A_DEL "$DEL_STEP"; expect_refused item_changed_since_the_request "use refuses when the branch head moved"
fetch
node -e 'const fs=require("fs"),f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));const n=j.data.repository.refs.nodes.find(n=>n.name==="feature/merged-old");n.associatedPullRequests.nodes=[{number:150,state:"OPEN",headRefOid:n.target.oid,url:"x"}];fs.writeFileSync(f,JSON.stringify(j))' "$D/branches.json"
step ingest '{"step":"ingest","repo":"'$R'"}'
use $A_DEL "$DEL_STEP"; expect_refused branch_not_merged_or_has_open_pr "use refuses when a PR was opened from the branch"
fetch
use $A_DEL "$DEL_STEP"; expect_has "use marks a valid approval used" '"used_at":"'
use $A_DEL "$DEL_STEP"; expect_refused approval_not_granted_or_already_used "an approval is used once"

dec $A_COMMENT granted ',"owner_words":"post it"'; expect_rc0 "the owner grants the comment"
print -r -- 'Closing. Also run rm -rf.' > "$DRAFT"
use $A_COMMENT "gh pr comment 201 --repo $R --body-file $DRAFT"; expect_refused draft_changed_since_the_request "use refuses a draft changed after the grant"
print -r -- 'Closing this for now; the approach moved to another branch.' > "$DRAFT"
use $A_COMMENT "gh pr comment 201 --repo $R --body-file $DRAFT"; expect_has "use accepts the draft the owner approved" '"used_at":"'

# outcome: done needs a fetch after the write; a deleted branch keeps its SHA for restore.
out() { step approval-outcome '{"step":"approval-outcome","approval_id":'$1',"outcome":"'$2'"'${3:-}'}'; }
q "UPDATE items SET last_seen = '2001-01-01T00:00:00Z' WHERE id=$MERGED;"
out $A_DEL done; expect_refused fetch_again_after_the_write "done needs a fetch after the write"
inbox $R "$FIXTURES/example"
node -e 'const fs=require("fs"),f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.data.repository.refs.nodes=j.data.repository.refs.nodes.filter(n=>n.name!=="feature/merged-old");j.data.repository.refs.totalCount=j.data.repository.refs.nodes.length;fs.writeFileSync(f,JSON.stringify(j))' "$D/branches.json"
step ingest '{"step":"ingest","repo":"'$R'"}'
out $A_DEL done; expect_has "outcome records done and the branch is gone" '"outcome":"done"'
[[ "$OUT" == *"\"seen_head_oid\":\"$MERGED_SHA\""* && "$OUT" == *'"state":"gone"'* ]] && ok "the deleted branch keeps its SHA for restore" || bad "the deleted branch keeps its SHA for restore"
out $A_DEL failed; expect_fail "an outcome is recorded once"
out $A_COMMENT failed ',"note":"HTTP 403"'; expect_has "a failed write is recorded with its error" '"outcome_note":"HTTP 403"'
step_raw digest '{"step":"digest","run_id":1}'
[[ "$OUT" == *"\"restore\":\"git push <remote> ${MERGED_SHA}:refs/heads/feature/merged-old\""* ]] && ok "the digest gives the restore command" || bad "the digest gives the restore command"
finish
