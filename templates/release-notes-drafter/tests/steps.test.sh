#!/bin/zsh
# Read side: add-repo, ingest, pending-prs, save-draft (sections and the computed tag), render-draft,
# run-end, digest. The fixtures keep the exact shape of `gh release list` and `gh pr list` output
# (gh 2.102), with made-up text. Usage: zsh tests/steps.test.sh <package dir>
source "${0:A:h}/lib.sh" "$1"
R=example-org/example-repo
REL="$FIXTURES/example/releases.json"
PRS="$FIXTURES/example/prs.json"
schema
RC=0; OUT="$(sqlite3 -bail "$DB" ".read references/schema.sql" 2>&1)"; RC=$?
expect_refused database_not_empty "schema refuses a database that already has tables"
step setup-check '{}'; expect_has "setup-check passes" '"result":"ok"'

step add-repo '{"step":"add-repo","repo":"'$R'"}'; expect_has "add-repo registers the repository" '"repo":"'$R'"'
for bad in "../etc" "a/b/c" "-x/y" "a/-y" "a/.git" "a b/c" "a/b;rm"; do
  step add-repo '{"step":"add-repo","repo":"'$bad'"}'; expect_fail "add-repo refuses $bad"
done
step ingest '{"step":"ingest","repo":"other/repo"}'; expect_refused repo_not_registered "ingest refuses an unregistered repository"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused fetch_missing_or_for_another_repo "ingest refuses when fetch has not run"
step pending-prs '{"step":"pending-prs","repo":"'$R'"}'; expect_refused repo_not_registered_or_never_fetched "pending-prs refuses before a fetch"

step run-start '{"step":"run-start","kind":"manual"}'; expect_has "run-start" '"run_id":1'
inbox $R "$REL" "$PRS"
step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'
expect_has "the base is GitHub's latest release, not the newer prerelease" '"base_tag":"v1.4.0"'
expect_has "ingest stores the window" '"pr_count":30'
expect_has "ingest stores the default branch" '"default_branch":"main"'
expect_has "a window under the limit is not a gap" '"limit_reached":0'
q "SELECT count(*) FROM releases WHERE repo='$R';"; expect_eq "ingest stores every release" "6"

# Bad input stops the step and changes nothing.
D="inbox/${R/\//__}"
cp "$D/prs.json" "$SCRATCH/prs.good"
print -r -- '[{"number":"7","title":"x","mergedAt":"2026-11-20T00:00:00Z"}]' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused pr_number_not_json_integer "ingest refuses a number that is not a JSON integer"
print -r -- '[{"number":7,"title":"x","mergedAt":"2001-01-01T00:00:00Z"}]' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused pr_merged_before_the_base "ingest refuses a merge older than the base"
print -r -- '[{"number":7,"title":"x","mergedAt":"soon"}]' > "$D/prs.json"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_refused pr_merged_at_not_iso "ingest refuses a time that is not ISO UTC"
cp "$SCRATCH/prs.good" "$D/prs.json"
inbox $R "$REL" "$PRS" "-rf"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_fail "ingest refuses a default branch that reads as a flag"
inbox $R "$REL" "$PRS" "main; touch x"
step ingest '{"step":"ingest","repo":"'$R'"}'; expect_fail "ingest refuses a default branch with shell characters"
q "SELECT default_branch, pr_count FROM repos;"; expect_eq "refused ingests change nothing" "main|30"
inbox $R "$REL" "$PRS"; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_rc0 "ingest again"

# pending-prs: sections from labels and conventional prefixes; bots left out unless asked.
step pending-prs '{"step":"pending-prs","repo":"'$R'","include_bots":false}'; expect_rc0 "pending-prs runs"
PEOPLE="$OUT"
N="$(print -r -- "$OUT" | grep -o '"number"' | wc -l | tr -d ' ')"
[[ "$N" == 17 ]] && ok "pending-prs leaves out the 13 bot pull requests" || { OUT="count=$N"; bad "pending-prs leaves out bots"; }
print -r -- "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(r.length && r.every((x)=>x.body==="") ? 0 : 1)' && ok "pending-prs shows no PR body by default" || bad "pending-prs shows no PR body by default"
step pending-prs '{"step":"pending-prs","repo":"'$R'","include_bots":false,"include_bodies":true}'
print -r -- "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(r.some((x)=>x.body.length>0) && r.every((x)=>x.body.length<=1500) ? 0 : 1)' && ok "include_bodies shows bodies of at most 1500 characters" || bad "include_bodies shows bodies of at most 1500 characters"
step pending-prs '{"step":"pending-prs","repo":"'$R'","include_bots":true}'
N="$(print -r -- "$OUT" | grep -o '"number"' | wc -l | tr -d ' ')"
[[ "$N" == 30 ]] && ok "include_bots returns all 30" || { OUT="count=$N"; bad "include_bots returns all 30"; }
sec() { print -r -- "$PEOPLE" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8"));const x=r.find(p=>p.title===process.argv[1]);process.stdout.write(x?x.suggested_section:"missing")' "$1"; }
for pair in "feat: add --json output to export=features" "fix: retry upload when the proxy drops=fixes" "docs: explain cache flags=docs" \
            "feat(api)!: rename the list endpoint=breaking" "refactor: split the upload module=internal" "Speed up config loading=other" "ci: run tests on arm64=internal"; do
  T="${pair%=*}"; W="${pair##*=}"; OUT="$(sec "$T")"; RC=0
  expect_eq "suggests $W for '$T'" "$W"
done
BASE="$(print -r -- "$PEOPLE" | sed -n 's/.*"base_tag":"\([^"]*\)".*/\1/p' | head -1)"
NEWEST="$(print -r -- "$PEOPLE" | sed -n 's/.*"newest_merged_at":"\([^"]*\)".*/\1/p' | head -1)"
ENTRIES="$(entries_from_pending "$PEOPLE")"

# save-draft: entries must be exactly the window; the tag is computed here.
SD='{"step":"save-draft","run_id":1,"repo":"'$R'","base_tag":"'$BASE'","newest_merged_at":"'$NEWEST'","include_bots":false'
step save-draft "$SD"',"entries":[]}'; expect_refused entries_do_not_match_the_window "save-draft refuses no entries"
SHORT="$(print -r -- "$ENTRIES" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(JSON.stringify(a.slice(1)))')"
step save-draft "$SD"',"entries":'$SHORT'}'; expect_refused entries_do_not_match_the_window "save-draft refuses a missing pull request"
DUP="$(print -r -- "$ENTRIES" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(JSON.stringify([...a,a[0]]))')"
step save-draft "$SD"',"entries":'$DUP'}'; expect_refused entries_do_not_match_the_window "save-draft refuses a pull request twice"
EXTRA="$(print -r -- "$ENTRIES" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(JSON.stringify([...a,{number:99999,section:"fixes"}]))')"
step save-draft "$SD"',"entries":'$EXTRA'}'; expect_refused entries_do_not_match_the_window "save-draft refuses a pull request outside the window"
BADSEC="$(print -r -- "$ENTRIES" | sed 's/"section":"other"/"section":"misc"/')"
step save-draft "$SD"',"entries":'$BADSEC'}'; expect_refused unknown_section "save-draft refuses an unknown section"
step save-draft '{"step":"save-draft","run_id":1,"repo":"'$R'","base_tag":"v1.3.2","newest_merged_at":"'$NEWEST'","include_bots":false,"entries":'$ENTRIES'}'
expect_refused repo_changed_since_pending_prs "save-draft refuses a base other than the one pending-prs showed"

step save-draft "$SD"',"entries":'$ENTRIES'}'
expect_has "a breaking entry bumps the major version" '"next_tag":"v2.0.0","bump":"major"'
DRAFT1="$(print -r -- "$OUT" | sed -n 's/.*"draft_id":\([0-9]*\).*/\1/p')"
expect_has "the draft names its notes file" '"notes_file":"drafts/example-org__example-repo-v2.0.0.md"'
q "SELECT count(*), count(DISTINCT draft_id) FROM draft_entries WHERE draft_id=$DRAFT1;"; expect_eq "every entry belongs to the new draft" "17|1"
NOBREAK="$(print -r -- "$ENTRIES" | sed 's/"section":"breaking"/"section":"features"/g')"
step save-draft "$SD"',"entries":'$NOBREAK'}'; expect_has "a feature bumps the minor version" '"next_tag":"v1.5.0","bump":"minor"'
PATCH="$(print -r -- "$NOBREAK" | sed 's/"section":"features"/"section":"fixes"/g')"
step save-draft "$SD"',"entries":'$PATCH'}'; expect_has "fixes only bump the patch version" '"next_tag":"v1.4.1","bump":"patch"'
step save-draft "$SD"',"entries":'$NOBREAK',"next_tag":"v3.0.0"}'; expect_refused next_tag_not_semver_or_not_after_base "an owner tag needs the owner's words"
step save-draft "$SD"',"entries":'$NOBREAK',"next_tag":"v1.4.0","owner_words":"use 1.4.0"}'; expect_refused next_tag_not_semver_or_not_after_base "an owner tag must be after the base"
step save-draft "$SD"',"entries":'$NOBREAK',"next_tag":"1.9.0","owner_words":"1.9.0 please"}'; expect_refused next_tag_not_semver_or_not_after_base "an owner tag keeps the base's v prefix"
for bad in "v1.5" "v01.5.0" "v1.5.0-rc.1" "v1.5.0;id" "v1.5.0 --target x" "va.b.c"; do
  step save-draft "$SD"',"entries":'$NOBREAK',"next_tag":"'$bad'","owner_words":"yes"}'; expect_refused next_tag_not_semver_or_not_after_base "an owner tag '$bad' is refused"
done
step save-draft "$SD"',"entries":'$NOBREAK',"next_tag":"v1.6.0","owner_words":"make it 1.6.0"}'; expect_has "the owner may choose a later tag" '"next_tag":"v1.6.0","bump":"owner"'

# The 0.x rule, a non-semver base, no release yet, and a tag that exists already.
mk_rel() { node -e '
  const fs=require("fs"); const [src, dst, tag, flag] = process.argv.slice(1);
  const a = JSON.parse(fs.readFileSync(src, "utf8"));
  if (flag === "none") { fs.writeFileSync(dst, "[]"); process.exit(0); }
  if (flag === "draft") { a.unshift({ ...a[1], tagName: tag, isDraft: true, isLatest: false, name: "draft" }); }
  else { a[1].tagName = tag; }
  fs.writeFileSync(dst, JSON.stringify(a));' "$REL" "$SCRATCH/rel.json" "$1" "${2:-}"; }
redo() { inbox $R "$SCRATCH/rel.json" "$PRS"; step ingest '{"step":"ingest","repo":"'$R'"}'
  step pending-prs '{"step":"pending-prs","repo":"'$R'","include_bots":false}'
  B2="$(print -r -- "$OUT" | sed -n 's/.*"base_tag":"\([^"]*\)".*/\1/p' | head -1)"; E2="$(entries_from_pending "$OUT")"
  SD2='{"step":"save-draft","repo":"'$R'","base_tag":"'$B2'","newest_merged_at":"'$NEWEST'","include_bots":false'; }
mk_rel v0.9.3; redo
step save-draft "$SD2"',"entries":'$E2'}'; expect_has "a breaking change on 0.x bumps the minor by default" '"next_tag":"v0.10.0","bump":"minor"'
step save-draft "$SD2"',"entries":'$E2',"zero_major_breaking_is_minor":false}'; expect_has "with the 0.x rule off it bumps the major" '"next_tag":"v1.0.0","bump":"major"'
mk_rel 0.9.3; redo
step save-draft "$SD2"',"entries":'$E2'}'; expect_has "a base without v keeps no v" '"next_tag":"0.10.0"'
mk_rel release-2026-11; redo
step save-draft "$SD2"',"entries":'$E2'}'; expect_refused base_tag_not_semver_give_next_tag "a base that is not semver needs the owner's tag"
step save-draft "$SD2"',"entries":'$E2',"next_tag":"v2.0.0","owner_words":"start at 2.0.0"}'; expect_has "with the owner's tag it drafts" '"next_tag":"v2.0.0","bump":"owner"'
mk_rel v1.4.0 none; redo
step save-draft "$SD2"',"entries":'$E2'}'; expect_has "with no release yet the first tag is v0.1.0" '"next_tag":"v0.1.0","bump":"first"'
mk_rel v2.0.0 draft; redo
step save-draft "$SD2"',"entries":'$E2'}'; expect_refused tag_already_exists "a tag that exists as a draft release is refused"
inbox $R "$REL" "$PRS"; step ingest '{"step":"ingest","repo":"'$R'","run_id":1}'; expect_rc0 "back to the fixture"

# render-draft
step_raw render-draft '{"step":"render-draft","draft_id":'$DRAFT1'}'; expect_rc0 "render-draft runs"
print -r -- "$OUT" | node -e '
  const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const order = d.sections.map((s) => s.section).join(",");
  const ok = d.next_tag === "v2.0.0" && order === "breaking,features,fixes,docs,internal,other"
    && d.contributors.every((c) => !c.startsWith("app/")) && d.compare_url.endsWith("/compare/v1.4.0...v2.0.0")
    && d.sections.reduce((n, s) => n + s.entries.length, 0) === 17;
  process.exit(ok ? 0 : 1);' && ok "render-draft groups in order, credits people, links the compare" || bad "render-draft output"
step_raw render-draft '{"step":"render-draft","draft_id":999}'; expect_refused unknown_draft "render-draft refuses an unknown draft"
q "UPDATE drafts SET next_tag='v9.9.9' WHERE id=$DRAFT1;"; expect_fail "a saved draft cannot be changed"

step run-end '{"step":"run-end","run_id":1,"note":"other/repo: fetch failed: HTTP 404"}'; expect_has "run-end" '"ended_at":"'
step run-end '{"step":"run-end","run_id":1}'; expect_refused run_unknown_or_ended "run-end refuses a run that already ended"
step_raw digest '{"step":"digest","run_id":1}'; expect_rc0 "digest runs"
print -r -- "$OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(d.drafts.length>0&&d.reads.length>0&&d.run.note.includes("HTTP 404")?0:1)' \
  && ok "digest has reads, drafts and the run note" || bad "digest content"
step_raw digest '{"step":"digest","run_id":42}'; expect_refused unknown_run "digest refuses an unknown run"
finish
