#!/bin/zsh
# Write side: ask-approval builds the command, decide-approval records the owner's answer,
# use-approval checks it right before the write, approval-outcome closes it.
# Usage: zsh tests/approvals.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
D="inbox/${R/\//__}"
S="${R/\//__}"
schema
step add-repo '{"step":"add-repo","repo":"'$R'"}'
fetch() { inbox $R "$FIXTURES/example"; step ingest '{"step":"ingest","repo":"'$R'"}'; }
fetch; expect_rc0 "setup: fetch and ingest"
row() { sqlite3 "$DB" "SELECT id FROM runs WHERE gh_run_id = $1 ORDER BY attempt DESC LIMIT 1;"; }
fid() { sqlite3 "$DB" "SELECT f.id FROM failures f JOIN runs u ON u.id = f.run_row WHERE u.gh_run_id = $1 LIMIT 1;"; }
R1002=$(row 1002); R1003=$(row 1003); R2001=$(row 2001); R3001=$(row 3001); R1004=$(row 1004)
F1002=$(fid 1002); F1003=$(fid 1003); F3001=$(fid 3001)
ask() { step ask-approval '{"step":"ask-approval","run_row":'$1',"action":"'$2'"'${3:-}'}'; }
id_of() { print -r -- "$OUT" | sed -n 's/.*"approval_id":\([0-9]*\).*/\1/p' | head -1; }
mkdir -p drafts

# rerun
ask $R3001 rerun; expect_has "rerun builds the exact command" "\"exact_step\":\"gh run rerun 3001 --failed --repo $R\""
A_RERUN=$(id_of)
ask $R3001 rerun; expect_fail "one open request per run attempt and action"
ask $R1004 rerun; expect_refused run_unknown_or_not_failed "a passing run cannot be rerun"
ask $R3001 rerun ',"failure_id":'$F3001; expect_refused failure_not_in_this_run "a failure id is refused on a rerun"
ask $R3001 cancel; expect_refused unknown_action "unknown actions are refused"

# issue: the title is built here; text goes in a fixed draft file.
ask $R1002 issue ',"failure_id":'$F1002; expect_refused draft_missing_empty_or_too_long "an issue needs its draft"
print -r -- "TestParseConfig fails on main since bbbbbbb (Bump parser to 3.0)." > "drafts/$S-run-1002.md"
ask $R1002 issue ',"failure_id":'$F3001; expect_refused failure_not_in_this_run "the failure must belong to the run"
ask $R1002 issue; expect_refused failure_not_in_this_run "an issue needs its failure"
ask $R1002 issue ',"failure_id":'$F1002
expect_has "issue builds the exact command" "\"exact_step\":\"gh issue create --repo $R --title 'CI: CI / test (ubuntu-latest) failing on main' --body-file drafts/$S-run-1002.md\""
A_ISSUE=$(id_of)
print -r -- "Same failure again." > "drafts/$S-run-1003.md"
ask $R1003 issue ',"failure_id":'$F1003; expect_refused issue_already_requested_for_signature "one issue per failure signature"
step decide-approval '{"step":"decide-approval","approval_id":'$A_ISSUE',"decision":"withdrawn"}'
ask $R1003 issue ',"failure_id":'$F1003; expect_rc0 "a withdrawn request frees the signature"
A_ISSUE2=$(id_of)

# Hostile names from the repository are refused before they reach the title.
# Each value is an SQL expression, so control characters are stored as they are.
for name expr in quote "'x''; touch /tmp/pwned; echo '''" newline "'x' || char(10) || 'y'" tab "'x' || char(9) || 'y'" \
                 escape "'x' || char(27) || '[31my'" delete "'x' || char(127) || 'y'"; do
  sqlite3 "$DB" "UPDATE runs SET workflow = $expr WHERE id = $R1002; DELETE FROM approvals WHERE run_row = $R1002;"
  ask $R1002 issue ',"failure_id":'$F1002; expect_refused title_unsafe "an issue title with a $name in the workflow name is refused"
done
sqlite3 "$DB" "UPDATE runs SET workflow = 'CI' WHERE id = $R1002; UPDATE failures SET job_name = 'test' || char(39) || 's' WHERE id = $F1002;"
ask $R1002 issue ',"failure_id":'$F1002; expect_refused title_unsafe "an issue title with a quote in the job name is refused"
sqlite3 "$DB" "UPDATE failures SET job_name = 'test (ubuntu-latest)' WHERE id = $F1002;"

# pr-comment: only an open PR whose head is this commit.
print -r -- "The lint job fails on this PR: main.go:12 has an unused variable." > "drafts/$S-pr-42.md"
ask $R1002 pr-comment ',"pr_number":42'; expect_refused pr_not_open_for_this_commit "a PR on another commit is refused"
ask $R2001 pr-comment ',"pr_number":7'; expect_refused pr_not_open_for_this_commit "an unknown PR is refused"
ask $R2001 pr-comment; expect_refused pr_not_open_for_this_commit "pr-comment needs a PR number"
ask $R3001 issue ',"failure_id":'$F3001',"pr_number":42'; expect_refused pr_not_open_for_this_commit "a PR number is refused on another action"
ask $R2001 pr-comment ',"pr_number":42'
expect_has "pr-comment builds the exact command" "\"exact_step\":\"gh pr comment 42 --repo $R --body-file drafts/$S-pr-42.md\""
A_PR=$(id_of)

# Freshness
q "UPDATE runs SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now','-20 minutes') WHERE id = $R1003;"
sqlite3 "$DB" "DELETE FROM approvals WHERE run_row = $R1003 AND decision = 'pending' AND action = 'rerun';"
ask $R1003 rerun; expect_refused fetch_again_first "a request needs a recent fetch"
fetch

# decide
dec() { step decide-approval '{"step":"decide-approval","approval_id":'$1',"decision":"'$2'"'${3:-}'}'; }
dec $A_RERUN granted; expect_fail "a grant needs the owner's words"
dec $A_RERUN granted ',"owner_words":"yes, rerun it"'; expect_has "the owner grants" '"decision":"granted"'
dec $A_RERUN refused ',"owner_words":"no"'; expect_refused request_unknown_or_already_decided "a decision is made once"
q "UPDATE approvals SET exact_step = 'gh run cancel 3001 --repo $R' WHERE id = $A_RERUN;"; expect_fail "a request cannot be rewritten"

# use
use() { step use-approval '{"step":"use-approval","approval_id":'$1',"exact_step":"'$2'"}'; }
RERUN="gh run rerun 3001 --failed --repo $R"
use $A_ISSUE2 "x"; expect_refused approval_not_granted_or_already_used "use refuses a request that was not granted"
use $A_RERUN "gh run rerun 3001 --repo $R"; expect_refused not_the_approved_command "use refuses a different command"
q "UPDATE reads SET fetched_at = strftime('%Y-%m-%dT%H:%M:%SZ','now','-11 minutes');"
use $A_RERUN "$RERUN"; expect_refused fetch_again_first "use needs a fetch from the last 10 minutes"
fetch
use $A_RERUN "$RERUN"; expect_has "use marks a valid approval used" '"used_at":"'
use $A_RERUN "$RERUN"; expect_refused approval_not_granted_or_already_used "an approval is used once"

# A rerun already started elsewhere: attempt 2 appears, and a grant or use for attempt 1 is refused.
dec $A_PR granted ',"owner_words":"post it"'; expect_rc0 "the owner grants the PR comment"
node -e '
  const f = process.argv[1]; const a = JSON.parse(require("fs").readFileSync(f));
  const r = a.find((x) => x.databaseId === 2001);
  Object.assign(r, { attempt: 2, conclusion: "failure", updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z") });
  require("fs").writeFileSync(f, JSON.stringify(a));' "$D/runs.json"
fetched $R; step ingest '{"step":"ingest","repo":"'$R'"}'
use $A_PR "gh pr comment 42 --repo $R --body-file drafts/$S-pr-42.md"; expect_refused run_changed_since_the_request "use refuses when the run has a newer attempt"
ask $R2001 rerun; expect_refused rerun_not_latest_attempt "an attempt that was already rerun is not rerun again"
fetch

# Draft bound by hash; a closed PR is refused at use.
dec $A_ISSUE2 granted ',"owner_words":"open it"'; expect_rc0 "the owner grants the issue"
print -r -- "Edited after the grant." > "drafts/$S-run-1003.md"
use $A_ISSUE2 "gh issue create --repo $R --title 'CI: CI / test (ubuntu-latest) failing on main' --body-file drafts/$S-run-1003.md"
expect_refused draft_changed_since_the_request "use refuses a draft changed after the grant"
print -r -- "Same failure again." > "drafts/$S-run-1003.md"
use $A_ISSUE2 "gh issue create --repo $R --title 'CI: CI / test (ubuntu-latest) failing on main' --body-file drafts/$S-run-1003.md"
expect_has "use accepts the approved draft" '"used_at":"'

# outcome
out() { step approval-outcome '{"step":"approval-outcome","approval_id":'$1',"outcome":"'$2'"'${3:-}'}'; }
out $A_PR done; expect_refused approval_not_used "outcome refuses an approval that was not used"
q "UPDATE reads SET fetched_at = '2001-01-01T00:00:00Z';"
out $A_RERUN done; expect_refused fetch_again_after_the_write "done needs a fetch after the write"
fetch
out $A_RERUN done; expect_has "outcome records done" '"outcome":"done"'
out $A_RERUN failed; expect_fail "an outcome is recorded once"
out $A_ISSUE2 done ',"note":"https://github.com/example-org/example-repo/issues/77"'; expect_has "an issue outcome keeps its link" 'issues/77'
print -r -- "Third time." > "drafts/$S-run-1002.md"
ask $R1002 issue ',"failure_id":'$F1002; expect_refused issue_already_requested_for_signature "a done issue blocks another for the same signature"
finish
