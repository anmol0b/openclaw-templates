#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and runs the real fetch.mjs against a stand-in `gh` that serves
# recorded gh output, so every snapshot goes through the same path as a real run.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
FIXTURES="${0:A:h}/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/wrh-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data" "$SCRATCH/bin" "$SCRATCH/served"
cp -R "$PKG/references" "$SCRATCH/ws/"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/wrh.db"
PASSES=0
FAILS=0
OUT=""
RC=0
# The stand-in gh: serves $SCRATCH/served/<read>.json for each of fetch.mjs's reads.
cat > "$SCRATCH/bin/gh" <<EOF
#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
const d = "$SCRATCH/served/";
const has = (x) => a.includes(x);
const out = (n) => process.stdout.write(fs.readFileSync(d + n + ".json", "utf8"));
if (a[0] === "repo") out("repo");
else if (a[0] === "pr" && has("all")) out("window_prs");
else if (a[0] === "pr" && has("open")) out("open_prs");
else if (a[0] === "issue" && has("all")) out("window_issues");
else if (a[0] === "issue" && has("open")) out("open_issues");
else if (a[0] === "run") out("runs");
else { process.stderr.write("unexpected gh call\n"); process.exit(3); }
EOF
chmod +x "$SCRATCH/bin/gh"
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
# serve <fixture dir>: the stand-in gh serves this fixture. Its times are moved once per test
# so the newest one was an hour ago, whatever day the test runs.
serve() {
  local shifted="$SCRATCH/shifted-${1:t}"
  if [[ ! -d "$shifted" ]]; then
    mkdir -p "$shifted"
    node -e '
      const fs = require("fs");
      const [src, dst] = process.argv.slice(1);
      const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
      const files = fs.readdirSync(src).filter((n) => n.endsWith(".json"));
      const docs = Object.fromEntries(files.map((n) => [n, JSON.parse(fs.readFileSync(`${src}/${n}`, "utf8"))]));
      const times = [];
      const walk = (v, fn) => Array.isArray(v) ? v.map((x) => walk(x, fn)) : v && typeof v === "object"
        ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x, fn)])) : fn(v);
      const real = (v) => typeof v === "string" && ISO.test(v) && !v.startsWith("0001-");
      for (const d of Object.values(docs)) walk(d, (v) => (real(v) && times.push(Date.parse(v)), v));
      const shift = Date.now() - 3600e3 - Math.max(...times);
      const move = (v) => real(v) ? new Date(Date.parse(v) + shift).toISOString().replace(/\.\d{3}Z$/, "Z") : v;
      for (const [n, d] of Object.entries(docs)) fs.writeFileSync(`${dst}/${n}`, JSON.stringify(walk(d, move)));
    ' "$1" "$shifted"
  fi
  cp "$shifted"/*.json "$SCRATCH/served/"
}
# edit_served <read> <js expression over a>: changes one served file, e.g. to drop an item.
edit_served() {
  node -e 'const fs=require("fs"),f=process.argv[1];const a=JSON.parse(fs.readFileSync(f,"utf8"));fs.writeFileSync(f,JSON.stringify(eval(process.argv[2])))' \
    "$SCRATCH/served/$1.json" "$2"
}
# fetch <repo>: the real fetch.mjs with the stand-in gh first on PATH.
fetch() {
  OUT="$(PATH="$SCRATCH/bin:$PATH" node references/fetch.mjs "$1" 2>&1)"
  RC=$?
}
# inbox_edit <repo> <file> <js expression over a>: changes a file fetch.mjs wrote, to test ingest's checks.
inbox_edit() {
  node -e 'const fs=require("fs"),f=process.argv[1];const a=JSON.parse(fs.readFileSync(f,"utf8"));fs.writeFileSync(f,JSON.stringify(eval(process.argv[2])))' \
    "inbox/${1/\//__}/$2.json" "$3"
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
