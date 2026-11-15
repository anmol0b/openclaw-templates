#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and checks sqlite3 output.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
FIXTURES="${0:A:h}/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/rnd-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data"
cp -R "$PKG/references" "$SCRATCH/ws/"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/rnd.db"
PASSES=0
FAILS=0
OUT=""
RC=0
# step <sql-step> <json>: writes db-input.json, runs the step, sets OUT and RC.
step() {
  print -r -- "$2" > db-input.json
  OUT="$(sqlite3 -bail -json "$DB" ".read references/sql/$1.sql" 2>&1)"
  RC=$?
}
# step_raw <sql-step> <json>: like step, without -json, for steps that print their own JSON.
step_raw() {
  print -r -- "$2" > db-input.json
  OUT="$(sqlite3 -bail "$DB" ".read references/sql/$1.sql" 2>&1)"
  RC=$?
}
# q <sql>: a plain read for checks, sets OUT and RC.
q() {
  OUT="$(sqlite3 "$DB" "$1" 2>&1)"
  RC=$?
}
# inbox <repo> <releases.json> <prs.json> [branch]: stands in for fetch.mjs. It picks the base
# release the way fetch.mjs does (pickBase) and writes the same summary, fetched now.
inbox() {
  local d="inbox/${1/\//__}"
  mkdir -p "$d"
  cp "$2" "$d/releases.json"
  cp "$3" "$d/prs.json"
  node --input-type=module -e '
    import { readFileSync, writeFileSync } from "node:fs";
    import { pickBase, LIMITS, NO_RELEASE_DAYS, iso } from "./references/fetch.mjs";
    const [repo, dir, branch] = process.argv.slice(1);
    const rel = JSON.parse(readFileSync(`${dir}/releases.json`, "utf8"));
    const prs = JSON.parse(readFileSync(`${dir}/prs.json`, "utf8"));
    const base = pickBase(rel);
    writeFileSync(`${dir}/fetch.json`, JSON.stringify({
      repo, default_branch: branch, base_tag: base ? base.tagName : null,
      since: base ? base.createdAt : iso(Date.now() - NO_RELEASE_DAYS * 864e5),
      releases: rel.length, prs: prs.length, limits: LIMITS, fetched_at: iso(Date.now()),
    }));
  ' "$1" "$d" "${4:-main}"
}
ok() { PASSES=$((PASSES + 1)); print -r -- "PASS $1"; }
bad() { FAILS=$((FAILS + 1)); print -r -- "FAIL $1 :: rc=$RC out=$OUT"; }
expect_rc0() { [[ $RC -eq 0 ]] && ok "$1" || bad "$1"; }
expect_fail() { [[ $RC -ne 0 ]] && ok "$1" || bad "$1"; }
# expect_refused <guard name> <description>: the step failed on that named check.
expect_refused() { [[ $RC -ne 0 && "$OUT" == *"constraint failed: $1"* ]] && ok "$2 ($1)" || bad "$2 (want refusal $1)"; }
expect_has() { [[ $RC -eq 0 && "$OUT" == *"$2"* ]] && ok "$1" || bad "$1 (want $2)"; }
expect_eq() { [[ $RC -eq 0 && "$OUT" == "$2" ]] && ok "$1" || bad "$1 (want $2)"; }
schema() { sqlite3 -bail "$DB" ".read references/schema.sql" >/dev/null 2>&1 || { print "FAIL schema"; exit 1; }; }
finish() { print "passed=$PASSES failed=$FAILS"; [[ $FAILS -eq 0 ]]; }
# entries <section-for-all|auto>: every pending pull request with its suggested section, as JSON.
entries_from_pending() {
  print -r -- "$1" | node -e '
    const rows = JSON.parse(require("fs").readFileSync(0, "utf8") || "[]");
    process.stdout.write(JSON.stringify(rows.map((r) => ({ number: r.number, section: r.suggested_section }))));
  '
}
