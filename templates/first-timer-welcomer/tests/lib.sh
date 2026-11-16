#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and checks sqlite3 output. Fetches run the real references/fetch.mjs
# against a stand-in `gh` that serves the fixture.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
FIXTURES="${0:A:h}/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ftw-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data" "$SCRATCH/bin" "$SCRATCH/serve"
cp -R "$PKG/references" "$SCRATCH/ws/"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/ftw.db"
PASSES=0
FAILS=0
OUT=""
RC=0
# The stand-in gh: `gh api graphql ...` prints $SCRATCH/serve/graphql.json.
cat > "$SCRATCH/bin/gh" <<EOF
#!/usr/bin/env node
process.stdout.write(require("fs").readFileSync("$SCRATCH/serve/graphql.json", "utf8"));
EOF
chmod +x "$SCRATCH/bin/gh"
# serve <fixture dir>: what the stand-in gh returns from now on. The fixture dates are moved once
# per test so the newest update was an hour ago, whatever day the test runs.
serve() {
  local shifted="$SCRATCH/shifted-${1:t}.json"
  if [[ ! -f "$shifted" ]]; then
    node -e '
      const fs = require("fs");
      const [src, dst] = process.argv.slice(1);
      const j = JSON.parse(fs.readFileSync(src, "utf8"));
      const r = j.data.repository;
      const newest = Math.max(...[...r.pullRequests.nodes, ...r.issues.nodes].map((x) => Date.parse(x.updatedAt)));
      const shift = Date.now() - 3600e3 - newest;
      const walk = (o) => {
        if (Array.isArray(o)) return o.forEach(walk);
        if (o && typeof o === "object") for (const k of Object.keys(o)) {
          if ((k === "createdAt" || k === "updatedAt") && typeof o[k] === "string")
            o[k] = new Date(Date.parse(o[k]) + shift).toISOString().replace(/\.\d{3}Z$/, "Z");
          else walk(o[k]);
        }
      };
      walk(j);
      fs.writeFileSync(dst, JSON.stringify(j));
    ' "$1/graphql.json" "$shifted"
  fi
  cp "$shifted" "$SCRATCH/serve/graphql.json"
}
# fetch <repo>: the real fetch.mjs with the stand-in gh. Sets OUT and RC.
fetch() {
  OUT="$(PATH="$SCRATCH/bin:$PATH" node references/fetch.mjs "$1" 2>&1)"
  RC=$?
}
# edit_served <node expression on r (the repository object)>: change the served response in place.
edit_served() {
  node -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f,"utf8"));const r=j.data.repository;'"$1"';fs.writeFileSync(f,JSON.stringify(j));' "$SCRATCH/serve/graphql.json"
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
# expect_refused <guard name> <description>: the step failed on that named check.
expect_refused() { [[ $RC -ne 0 && "$OUT" == *"CHECK constraint failed: $1"* ]] && ok "$2 ($1)" || bad "$2 (want refusal $1)"; }
expect_has() { [[ $RC -eq 0 && "$OUT" == *"$2"* ]] && ok "$1" || bad "$1 (want $2)"; }
expect_eq() { [[ $RC -eq 0 && "$OUT" == "$2" ]] && ok "$1" || bad "$1 (want $2)"; }
schema() { sqlite3 -bail "$DB" ".read references/schema.sql" >/dev/null 2>&1 || { print "FAIL schema"; exit 1; }; }
finish() { print "passed=$PASSES failed=$FAILS"; [[ $FAILS -eq 0 ]]; }
