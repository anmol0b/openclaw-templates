#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and checks sqlite3 output.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
FIXTURES="${0:A:h}/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sws-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data"
cp -R "$PKG/references" "$SCRATCH/ws/"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/sws.db"
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
# inbox <repo> <fixture dir>: stands in for fetch.mjs with recorded gh output. The fixture dates
# are moved once per test so the newest item was active an hour ago, whatever day the test runs.
inbox() {
  local d="inbox/${1/\//__}"
  local shifted="$SCRATCH/shifted-${2:t}"
  mkdir -p "$d"
  if [[ ! -d "$shifted" ]]; then
    mkdir -p "$shifted"
    _shift "$2" "$shifted"
  fi
  cp "$shifted"/{branches,prs,issues,user,repo}.json "$d/"
  print -r -- "{\"repo\":\"$1\",\"login\":\"example-owner\",\"default_branch\":\"main\",\"issues_enabled\":true,\"branches\":15,\"branches_total\":15,\"prs\":4,\"issues\":4,\"limits\":{\"branches\":100,\"prs\":100,\"issues\":100},\"fetched_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$d/fetch.json"
}
_shift() {
  node -e '
    const fs = require("fs");
    const [src, dst] = process.argv.slice(1);
    const read = (n) => JSON.parse(fs.readFileSync(`${src}/${n}.json`, "utf8"));
    const branches = read("branches"), prs = read("prs"), issues = read("issues");
    const times = [...branches.data.repository.refs.nodes.map((n) => n.target.committedDate),
      ...prs.map((x) => x.updatedAt), ...issues.map((x) => x.updatedAt)].map(Date.parse);
    const shift = Date.now() - 3600e3 - Math.max(...times);
    const iso = (t) => new Date(Date.parse(t) + shift).toISOString().replace(/\.\d{3}Z$/, "Z");
    for (const n of branches.data.repository.refs.nodes) n.target.committedDate = iso(n.target.committedDate);
    for (const x of [...prs, ...issues]) x.updatedAt = iso(x.updatedAt);
    fs.writeFileSync(`${dst}/branches.json`, JSON.stringify(branches));
    fs.writeFileSync(`${dst}/prs.json`, JSON.stringify(prs));
    fs.writeFileSync(`${dst}/issues.json`, JSON.stringify(issues));
    for (const n of ["user", "repo"]) fs.copyFileSync(`${src}/${n}.json`, `${dst}/${n}.json`);
  ' "$1" "$2"
}
ok() { PASSES=$((PASSES + 1)); print -r -- "PASS $1"; }
bad() { FAILS=$((FAILS + 1)); print -r -- "FAIL $1 :: rc=$RC out=$OUT"; }
expect_rc0() { [[ $RC -eq 0 ]] && ok "$1" || bad "$1"; }
expect_fail() { [[ $RC -ne 0 ]] && ok "$1" || bad "$1"; }
# expect_refused <guard name> <description>: the step failed on that named check.
expect_refused() { [[ $RC -ne 0 && "$OUT" == *"CHECK constraint failed: $1"* ]] && ok "$2 ($1)" || bad "$2 (want refusal $1)"; }
expect_has() { [[ $RC -eq 0 && "$OUT" == *"$2"* ]] && ok "$1" || bad "$1 (want $2)"; }
expect_eq() { [[ $RC -eq 0 && "$OUT" == "$2" ]] && ok "$1" || bad "$1 (want $2)"; }
schema() { sqlite3 -bail "$DB" ".read references/schema.sql" >/dev/null 2>&1 || { print "FAIL schema"; exit 1; }; }
finish() { print "passed=$PASSES failed=$FAILS"; [[ $FAILS -eq 0 ]]; }
