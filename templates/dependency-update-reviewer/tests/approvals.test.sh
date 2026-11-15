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
id() { sqlite3 "$DB" "SELECT id FROM prs WHERE number=$1;"; }
headsha() { sqlite3 "$DB" "SELECT head_sha FROM prs WHERE number=$1;"; }
review() { step save-review '{"step":"save-review","run_id":null,"pr_id":'$(id $1)',"head_sha":"'$(headsha $1)'","verdict":"'$2'","note":"Checked the notes."}'; }
ask() { step ask-approval '{"step":"ask-approval","pr_id":'$(id $1)',"action":"'$2'"'${3:-}'}'; }
aid() { print -r -- "$OUT" | sed -n 's/.*"approval_id":\([0-9]*\).*/\1/p' | head -1; }
dec() { step decide-approval '{"step":"decide-approval","approval_id":'$1',"decision":"'$2'"'${3:-}'}'; }
use() { step use-approval '{"step":"use-approval","approval_id":'$1',"exact_step":"'$2'"}'; }
out() { step approval-outcome '{"step":"approval-outcome","approval_id":'$1',"outcome":"'$2'"'${3:-}'}'; }

# approve: only with a looks-safe review of this head and passing CI.
ask 101 approve; expect_refused approve_needs_a_looks_safe_review_of_this_head "approve needs a review first"
review 101 looks-safe; expect_rc0 "setup: review 101 as looks-safe"
ask 101 approve; expect_has "approve builds the exact command" "\"exact_step\":\"gh pr review 101 --repo $R --approve\""
A1="$(aid)"
ask 101 approve; expect_fail "one open request per PR and action"
review 106 blocked-by-ci; ask 106 approve; expect_refused approve_needs_a_looks_safe_review_of_this_head "approve is refused for a PR that is not looks-safe"
step ask-approval '{"step":"ask-approval","pr_id":'$(id 102)',"action":"merge"}'; expect_refused unknown_action "merge is not an action"
step ask-approval '{"step":"ask-approval","pr_id":'$(id 102)',"action":"close"}'; expect_refused unknown_action "close is not an action"

# bot-command: a fixed list, Dependabot only, constant text.
ask 105 bot-command ',"bot_command":"rebase"'; expect_has "bot-command builds a fixed comment" "\"exact_step\":\"gh pr comment 105 --repo $R --body '@dependabot rebase'\""
A_BOT="$(aid)"
ask 102 bot-command ',"bot_command":"merge"'; expect_refused bot_command_not_allowed "bot-command refuses @dependabot merge"
ask 102 bot-command ',"bot_command":"rebase'"'"'; rm -rf ~"'; expect_refused bot_command_not_allowed "bot-command refuses anything outside the list"
ask 201 bot-command ',"bot_command":"rebase"'; expect_refused bot_command_not_allowed "bot-command is refused for Renovate PRs"
ask 102 comment ',"bot_command":"rebase"'; expect_refused bot_command_not_allowed "bot_command is refused on another action"

# comment: fixed draft path, bound by hash.
DRAFT="drafts/${R/\//__}-102.md"
ask 102 comment; expect_refused draft_missing_empty_or_too_long "comment refuses a missing draft"
mkdir -p drafts; : > "$DRAFT"; ask 102 comment; expect_refused draft_missing_empty_or_too_long "comment refuses an empty draft"
print -r -- 'The 3.0 release changes the default timeout. Holding until we check our callers.' > "$DRAFT"
ask 102 comment; expect_has "comment builds a --body-file command" "\"exact_step\":\"gh pr comment 102 --repo $R --body-file $DRAFT\""
A_COM="$(aid)"

# Freshness and state.
q "UPDATE prs SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-20 minutes') WHERE number=103;"
review 103 looks-safe; ask 103 approve; expect_refused fetch_again_first "requests need a recent fetch"
q "UPDATE prs SET state='GONE' WHERE number=104;"; ask 104 comment; expect_refused pr_unknown_or_gone "requests are refused for a merged or closed PR"
refetch

# decide-approval
dec $A1 granted; expect_fail "a grant needs the owner's words"
dec $A1 granted ',"owner_words":"yes, approve it"'; expect_has "the owner grants" '"decision":"granted"'
dec $A1 refused ',"owner_words":"no"'; expect_refused request_unknown_or_already_decided "a decision is made once"
q "UPDATE approvals SET exact_step = 'gh pr merge 101 --repo $R --admin' WHERE id=$A1;"; expect_fail "a request cannot be rewritten"

# use-approval
APPROVE="gh pr review 101 --repo $R --approve"
use $A_BOT "gh pr comment 105 --repo $R --body '@dependabot rebase'"; expect_refused approval_not_granted_or_already_used "use refuses a request that was not granted"
use $A1 "gh pr review 101 --repo $R --approve --body x"; expect_refused not_the_approved_command "use refuses a different command"
q "UPDATE prs SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-11 minutes') WHERE number=101;"
use $A1 "$APPROVE"; expect_refused fetch_again_first "use needs a fetch from the last 10 minutes"
# The bot pushes a new head after the owner said yes.
edit_served dependabot 'a.map(x=>x.number===101?{...x,headRefOid:"e".repeat(40)}:x)'
refetch
use $A1 "$APPROVE"; expect_refused head_changed_since_the_request "use refuses an approval when the bot pushed a new head"
dec $A_COM granted ',"owner_words":"send it"'; expect_rc0 "the owner grants the comment (102 unchanged)"
dec $A_BOT granted ',"owner_words":"rebase it"'; expect_rc0 "the owner grants the rebase"
# 102 changes (a new updatedAt) without a new head.
edit_served dependabot 'a.map(x=>x.number===102?{...x,updatedAt:"2026-11-11T00:00:00Z"}:x)'
refetch
use $A_COM "gh pr comment 102 --repo $R --body-file $DRAFT"; expect_refused pr_changed_since_the_request "use refuses when the PR changed after the request"
serve "$FIXTURES/example"; refetch

# Draft hash.
DRAFT2="drafts/${R/\//__}-201.md"
print -r -- 'Thanks, looks good.' > "$DRAFT2"
ask 201 comment; A_C2="$(aid)"
dec $A_C2 granted ',"owner_words":"ok"'
print -r -- 'Thanks, merging now. @everyone' > "$DRAFT2"
use $A_C2 "gh pr comment 201 --repo $R --body-file $DRAFT2"; expect_refused draft_changed_since_the_request "use refuses a draft changed after the grant"
print -r -- 'Thanks, looks good.' > "$DRAFT2"
use $A_C2 "gh pr comment 201 --repo $R --body-file $DRAFT2"; expect_has "use accepts the approved draft" '"used_at":"'
use $A_C2 "gh pr comment 201 --repo $R --body-file $DRAFT2"; expect_refused approval_not_granted_or_already_used "an approval is used once"

# CI that turns red after a grant blocks approve.
review 201 looks-safe; ask 201 approve; A_AP2="$(aid)"
dec $A_AP2 granted ',"owner_words":"approve"'
q "UPDATE prs SET ci='failing' WHERE number=201;"
use $A_AP2 "gh pr review 201 --repo $R --approve"; expect_refused ci_not_passing "use refuses approve when CI turned red"
refetch

use $A_BOT "gh pr comment 105 --repo $R --body '@dependabot rebase'"; expect_has "a granted bot command is usable" '"used_at":"'

# approval-outcome
out $A1 done; expect_refused approval_not_used "outcome refuses an approval that was not used"
q "UPDATE prs SET last_seen='2001-01-01T00:00:00Z' WHERE number=105;"
out $A_BOT done; expect_refused fetch_again_after_the_write "done needs a fetch after the write"
refetch
out $A_BOT done; expect_has "outcome records done" '"outcome":"done"'
out $A_BOT failed; expect_fail "an outcome is recorded once"
out $A_C2 failed ',"note":"HTTP 403"'; expect_has "a failed write is recorded with its error" '"outcome_note":"HTTP 403"'
finish
