#!/bin/zsh
# Read side: add-repo, run-start, ingest, stale-list, run-end, digest.
# The fixtures keep the exact shape of `gh api graphql` (branches), `gh pr list` and `gh issue list`
# output (gh 2.102), with made-up names. Usage: zsh tests/steps.test.sh <package dir>
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
step ingest '{"step":"ingest","repo":"other/repo"}'; expect_refused repo_not_registered "ingest refuses an unregistered repository"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused fetch_missing_or_for_another_repo "ingest refuses when fetch has not run"

step run-start '{"step":"run-start","kind":"scheduled","stale_days":30}'; expect_has "run-start returns the run" '"run_id":1'
step run-start '{"step":"run-start","kind":"scheduled","stale_days":0}'; expect_fail "run-start refuses stale_days 0"

inbox $R "$FIXTURES/example"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
expect_has "ingest counts branches, PRs and issues" '"branches":15,"branches_total":15,"prs":4,"issues":4'
expect_has "a short read marks nothing cut" '"branches_cut":0,"prs_cut":0,"issues_cut":0'
item() { sqlite3 "$DB" "SELECT $2 FROM items WHERE ref = '$1';"; }
cat_of() { sqlite3 "$DB" "SELECT coalesce((SELECT category FROM owners_work WHERE ref = '$1'), 'excluded');"; }
OUT="$(cat_of feature/merged-old)"; RC=0; expect_eq "a merged branch is safe to clean up" "merged-branch"
OUT="$(cat_of fix/squash-merged)"; RC=0; expect_eq "a squash-merged branch (merged PR with the same head) is safe" "merged-branch"
OUT="$(cat_of fix/squash-moved)"; RC=0; expect_eq "a branch that moved after its PR merged is unmerged" "unmerged-branch"
OUT="$(cat_of wip/unmerged)"; RC=0; expect_eq "an unmerged branch is never safe" "unmerged-branch"
OUT="$(cat_of feature/with-open-pr)"; RC=0; expect_eq "a branch with an open PR is left to the PR" "excluded"
OUT="$(cat_of release/protected-merged)"; RC=0; expect_eq "a protected branch is never safe" "unmerged-branch"
OUT="$(cat_of main)"; RC=0; expect_eq "the default branch is never listed" "excluded"
OUT="$(cat_of teammate/merged)"; RC=0; expect_eq "another person's branch is not the owner's work" "excluded"
OUT="$(cat_of 204)"; RC=0; expect_eq "a PR by someone else is not the owner's work" "excluded"
OUT="$(cat_of 304)"; RC=0; expect_eq "an issue assigned to someone else is not the owner's work" "excluded"
OUT="$(cat_of 302)"; RC=0; expect_eq "an issue assigned to the owner and others is the owner's" "idle-issue"
OUT="$(item 201 ci_state)|$(item 202 ci_state)|$(item 203 ci_state)"; RC=0
expect_eq "CI state: failing, passing (check run and status), pending" "failing|passing|pending"
OUT="$(item 201 is_draft)|$(item 201 mergeable)"; RC=0; expect_eq "draft and conflict state are kept" "1|CONFLICTING"

# stale-list: only items idle for stale_days, safest first.
step stale-list '{"step":"stale-list","run_id":1}'; expect_rc0 "stale-list runs"
ORDER="$(print -r -- "$OUT" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(a.map(x=>x.rank).join(""))')"
[[ "$ORDER" == $(print -r -- "$ORDER" | fold -w1 | sort | tr -d '\n') ]] && ok "stale-list is ordered by rank" || { OUT="ranks=$ORDER"; bad "stale-list is ordered by rank"; }
[[ "$OUT" != *'"ref":"feature/fresh-merged"'* ]] && ok "a merged branch active today is not stale yet" || bad "a merged branch active today is not stale yet"
[[ "$OUT" != *'"ref":"203"'* && "$OUT" != *'"ref":"303"'* ]] && ok "recent PRs and issues are not stale" || bad "recent PRs and issues are not stale"
[[ "$OUT" == *'"ref":"201"'* && "$OUT" == *'"ref":"301"'* ]] && ok "idle PRs and issues are listed" || bad "idle PRs and issues are listed"
step stale-list '{"step":"stale-list","run_id":1,"limit":51}'; expect_refused limit_not_1_to_50 "stale-list refuses a limit over 50"
step stale-list '{"step":"stale-list","run_id":9}'; expect_refused unknown_run "stale-list refuses an unknown run"

# Bad input stops ingest and changes nothing.
D="inbox/${R/\//__}"
cp "$D/prs.json" "$SCRATCH/prs.good"
print -r -- '[{"number":"12","title":"x","updatedAt":"2026-11-15T00:00:00Z","author":{"login":"example-owner"},"statusCheckRollup":[]}]' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused number_not_integer "ingest refuses a PR number that is not an integer"
print -r -- '[{"number":12,"title":"x","updatedAt":"yesterday","author":{"login":"example-owner"},"statusCheckRollup":[]}]' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused time_not_iso_utc "ingest refuses a time that is not ISO UTC"
print -r -- '[{"number":12,"title":"x","updatedAt":"2026-11-15T00:00:00Z","headRefOid":"zz","author":{"login":"example-owner"},"statusCheckRollup":[]}]' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused head_not_a_sha "ingest refuses a head that is not a SHA"
print -r -- '{"not":"a list"}' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused inbox_file_not_a_list "ingest refuses a file that is not a list"
cp "$SCRATCH/prs.good" "$D/prs.json"
q "SELECT count(*) FROM fetches;"; expect_eq "refused ingests record no fetch" "1"

# Gone: a complete read without an item marks it gone; a cut read marks nothing gone.
node -e 'const fs=require("fs"),f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.data.repository.refs.nodes=j.data.repository.refs.nodes.filter(n=>n.name!=="wip/unmerged");j.data.repository.refs.totalCount=j.data.repository.refs.nodes.length;fs.writeFileSync(f,JSON.stringify(j))' "$D/branches.json"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a complete read reports the gone item" '"gone_now":1'
q "SELECT state FROM items WHERE ref='wip/unmerged';"; expect_eq "the missing branch is marked gone" "gone"
inbox $R "$FIXTURES/example"
node -e 'const fs=require("fs"),f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.data.repository.refs.nodes=j.data.repository.refs.nodes.filter(n=>n.name!=="feature/merged-old");fs.writeFileSync(f,JSON.stringify(j))' "$D/branches.json"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a read with fewer branches than the total is cut" '"branches_cut":1'
q "SELECT state FROM items WHERE ref='feature/merged-old';"; expect_eq "a cut read marks nothing gone" "open"
q "SELECT state FROM items WHERE ref='wip/unmerged';"; expect_eq "an item seen again is open again" "open"
inbox $R "$FIXTURES/example"
sed -i.bak 's/"limits":{"branches":100/"limits":{"branches":15/' "$D/fetch.json"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_has "a read that hits its limit is cut" '"branches_cut":1'
inbox $R "$FIXTURES/example"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_rc0 "ingest again"

step run-end '{"step":"run-end","run_id":1}'; expect_has "run-end ends the run" '"ended_at":"'
step run-end '{"step":"run-end","run_id":1}'; expect_refused run_unknown_or_ended "run-end refuses a run that already ended"
step_raw digest '{"step":"digest","run_id":1}'; expect_rc0 "digest runs"
print -r -- "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' && ok "digest prints one plain JSON object" || bad "digest prints one plain JSON object"
for key in '"fetches":[' '"stale":[' '"stale_total":' '"open_requests":[' '"deleted_branches":[' '"branches_cut":1' '"category":"merged-branch"'; do
  [[ "$OUT" == *"$key"* ]] && ok "digest has $key" || bad "digest has $key"
done
step_raw digest '{"step":"digest","run_id":42}'; expect_refused unknown_run "digest refuses an unknown run"
finish
