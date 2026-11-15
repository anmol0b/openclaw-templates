#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and checks sqlite3 output.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
FIXTURES="${0:A:h}/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/cift-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data"
cp -R "$PKG/references" "$SCRATCH/ws/"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/cift.db"
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
# inbox <repo> <fixture dir>: stands in for fetch.mjs with recorded output. The run times are
# moved once per test so the newest run finished an hour ago, whatever day the test runs.
inbox() {
  local d="inbox/${1/\//__}"
  local shifted="$SCRATCH/shifted-${2:t}"
  mkdir -p "$d"
  if [[ ! -d "$shifted" ]]; then
    mkdir -p "$shifted"
    node -e '
      const fs = require("fs");
      const [src, dst] = process.argv.slice(1);
      const runs = JSON.parse(fs.readFileSync(`${src}/runs.json`, "utf8"));
      const newest = Math.max(...runs.map((x) => Date.parse(x.updatedAt)));
      const shift = Date.now() - 3600e3 - newest;
      const iso = (t) => new Date(Date.parse(t) + shift).toISOString().replace(/\.\d{3}Z$/, "Z");
      fs.writeFileSync(`${dst}/runs.json`, JSON.stringify(runs.map((x) => ({ ...x, createdAt: iso(x.createdAt), updatedAt: iso(x.updatedAt) }))));
      fs.copyFileSync(`${src}/prs.json`, `${dst}/prs.json`);
      fs.copyFileSync(`${src}/failures.json`, `${dst}/failures.json`);
    ' "$2" "$shifted"
  fi
  cp "$shifted"/{runs,prs,failures}.json "$d/"
  fetched "$1"
}
# fetched <repo> [logs_left]: writes the fetch summary with the current time.
fetched() {
  print -r -- "{\"repo\":\"$1\",\"limits\":{\"runs\":100,\"prs\":100,\"newLogs\":10},\"logs_left_for_next_fetch\":${2:-0},\"errors\":[],\"fetched_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "inbox/${1/\//__}/fetch.json"
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
