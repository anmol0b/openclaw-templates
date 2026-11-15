#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and checks sqlite3 output. Fetches run the real references/fetch.mjs
# against a stand-in `gh` that serves the fixtures.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
FIXTURES="${0:A:h}/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dur-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data" "$SCRATCH/bin" "$SCRATCH/serve"
cp -R "$PKG/references" "$SCRATCH/ws/"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/dur.db"
PASSES=0
FAILS=0
OUT=""
RC=0
# The stand-in gh: `gh pr list ... --author app/<bot> ...` prints $SCRATCH/serve/<bot>.json.
cat > "$SCRATCH/bin/gh" <<EOF
#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
const bot = (a[a.indexOf("--author") + 1] || "").replace("app/", "");
process.stdout.write(fs.readFileSync("$SCRATCH/serve/" + bot + ".json", "utf8"));
EOF
chmod +x "$SCRATCH/bin/gh"
# serve <fixture dir>: what the stand-in gh returns from now on.
serve() { cp "$1"/{dependabot,renovate}.json "$SCRATCH/serve/"; }
# fetch <repo>: the real fetch.mjs with the stand-in gh. Sets OUT and RC.
fetch() {
  OUT="$(PATH="$SCRATCH/bin:$PATH" node references/fetch.mjs "$1" 2>&1)"
  RC=$?
}
# edit_served <bot> <node expression on a>: change the served list in place, for example to push a new head.
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
# expect_refused <reason> <description>: the step failed on that named check or trigger.
expect_refused() { [[ $RC -ne 0 && "$OUT" == *"$1"* ]] && ok "$2 ($1)" || bad "$2 (want refusal $1)"; }
expect_has() { [[ $RC -eq 0 && "$OUT" == *"$2"* ]] && ok "$1" || bad "$1 (want $2)"; }
expect_eq() { [[ $RC -eq 0 && "$OUT" == "$2" ]] && ok "$1" || bad "$1 (want $2)"; }
schema() { sqlite3 -bail "$DB" ".read references/schema.sql" >/dev/null 2>&1 || { print "FAIL schema"; exit 1; }; }
finish() { print "passed=$PASSES failed=$FAILS"; [[ $FAILS -eq 0 ]]; }
