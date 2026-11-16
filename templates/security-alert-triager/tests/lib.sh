#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and checks sqlite3 output. Fetches run the real references/fetch.mjs
# against tests/fake-gh.cjs, which serves the fixtures.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
TESTS="${0:A:h}"
FIXTURES="$TESTS/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sat-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data" "$SCRATCH/bin" "$SCRATCH/serve"
cp -R "$PKG/references" "$SCRATCH/ws/"
cp "$TESTS/fake-gh.cjs" "$SCRATCH/bin/gh"
chmod +x "$SCRATCH/bin/gh"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/sat.db"
PASSES=0
FAILS=0
OUT=""
RC=0
# serve <fixture dir>: what the stand-in gh returns from now on. The fixture times are moved once per
# test so the newest alert was updated an hour ago, whatever day the test runs.
serve() {
  local shifted="$SCRATCH/shifted-${1:t}"
  if [[ ! -d "$shifted" ]]; then
    mkdir -p "$shifted"
    node -e '
      const fs = require("fs");
      const [src, dst] = process.argv.slice(1);
      const files = fs.readdirSync(src).filter((f) => f.endsWith(".json"));
      const data = Object.fromEntries(files.map((f) => [f, JSON.parse(fs.readFileSync(`${src}/${f}`, "utf8"))]));
      const alerts = files.filter((f) => !f.startsWith("prs-")).flatMap((f) => data[f]);
      const shift = Date.now() - 3600e3 - Math.max(...alerts.map((a) => Date.parse(a.updated_at)));
      const iso = (t) => new Date(Date.parse(t) + shift).toISOString().replace(/\.\d{3}Z$/, "Z");
      for (const a of alerts) { a.created_at = iso(a.created_at); a.updated_at = iso(a.updated_at); }
      for (const f of files) fs.writeFileSync(`${dst}/${f}`, JSON.stringify(data[f]));
    ' "$1" "$shifted"
  fi
  rm -f -- "$SCRATCH/serve/"*(N)
  cp "$shifted"/*.json "$SCRATCH/serve/"
}
# fail_source <name> <error fixture>: the stand-in gh answers that read with the recorded HTTP error.
fail_source() { cp "$FIXTURES/errors/$2.err" "$SCRATCH/serve/$1.err"; }
# fetch <repo>: the real fetch.mjs with the stand-in gh. Sets OUT and RC.
fetch() {
  OUT="$(PATH="$SCRATCH/bin:$PATH" FAKE_GH_DIR="$SCRATCH/serve" node references/fetch.mjs "$1" 2>&1)"
  RC=$?
}
# edit_served <name> <node expression on a>: change a served list in place, for example to touch an alert.
edit_served() {
  node -e 'const fs=require("fs");const f=process.argv[1];let a=JSON.parse(fs.readFileSync(f,"utf8"));a=('"$2"');fs.writeFileSync(f,JSON.stringify(a));' "$SCRATCH/serve/$1.json"
}
# step <sql-step> <json>: writes db-input.json, runs the step, sets OUT and RC.
step() {
  print -r -- "$2" > db-input.json
  OUT="$(sqlite3 -bail -json "$DB" ".read references/sql/$1.sql" 2>&1)"
  RC=$?
}
# step_raw: like step, without -json, for steps that print their own JSON.
step_raw() {
  print -r -- "$2" > db-input.json
  OUT="$(sqlite3 -bail "$DB" ".read references/sql/$1.sql" 2>&1)"
  RC=$?
}
q() {
  OUT="$(sqlite3 "$DB" "$1" 2>&1)"
  RC=$?
}
ok() { PASSES=$((PASSES + 1)); print -r -- "PASS $1"; }
bad() { FAILS=$((FAILS + 1)); print -r -- "FAIL $1 :: rc=$RC out=$OUT"; }
expect_rc0() { [[ $RC -eq 0 ]] && ok "$1" || bad "$1"; }
expect_fail() { [[ $RC -ne 0 ]] && ok "$1" || bad "$1"; }
# expect_refused <reason> <description>: the step failed on that named check.
expect_refused() { [[ $RC -ne 0 && "$OUT" == *"CHECK constraint failed: $1"* ]] && ok "$2 ($1)" || bad "$2 (want refusal $1)"; }
expect_has() { [[ $RC -eq 0 && "$OUT" == *"$2"* ]] && ok "$1" || bad "$1 (want $2)"; }
expect_eq() { [[ $RC -eq 0 && "$OUT" == "$2" ]] && ok "$1" || bad "$1 (want $2)"; }
schema() { sqlite3 -bail "$DB" ".read references/schema.sql" >/dev/null 2>&1 || { print "FAIL schema"; exit 1; }; }
finish() { print "passed=$PASSES failed=$FAILS"; [[ $FAILS -eq 0 ]]; }
