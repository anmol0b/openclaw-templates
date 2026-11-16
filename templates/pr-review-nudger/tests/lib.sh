#!/bin/zsh
# Shared helpers for the SQL step tests. Usage: source lib.sh <package dir>
# Each test copies references/ into a scratch workspace, keeps the database outside it
# (as db_path does), and checks sqlite3 output. Fetches run the real references/fetch.mjs
# against a stand-in `gh` that serves the fixtures.
set -u
PKG="${1:?package dir}"
PKG="${PKG:A}"
FIXTURES="${0:A:h}/fixtures"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/prn-test.XXXXXX")"
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ws" "$SCRATCH/data" "$SCRATCH/bin" "$SCRATCH/serve"
cp -R "$PKG/references" "$SCRATCH/ws/"
cd "$SCRATCH/ws" || exit 1
DB="$SCRATCH/data/prn.db"
PASSES=0
FAILS=0
OUT=""
RC=0
# The stand-in gh serves $SCRATCH/serve: prs.json, collaborators.json (missing: HTTP 403),
# and CODEOWNERS at .github/CODEOWNERS (missing: HTTP 404 for every path).
cat > "$SCRATCH/bin/gh" <<EOF
#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
const s = "$SCRATCH/serve/";
const out = (x) => process.stdout.write(typeof x === "string" ? x : JSON.stringify(x));
const err = (m) => { process.stderr.write(m + "\\n"); process.exit(1); };
const path = a[a.length - 1];
if (a[0] === "api" && a[1] === "user") out({ login: "example-owner", id: 1 });
else if (a[0] === "repo") out({ nameWithOwner: "example-org/example-repo" });
else if (a[0] === "pr") out(fs.readFileSync(s + "prs.json", "utf8"));
else if (a[0] === "api" && path.includes("/collaborators")) fs.existsSync(s + "collaborators.json") ? out(fs.readFileSync(s + "collaborators.json", "utf8")) : err("gh: Must have push access to view repository collaborators. (HTTP 403)");
else if (a[0] === "api" && path.endsWith("/contents/.github/CODEOWNERS") && fs.existsSync(s + "CODEOWNERS")) out(fs.readFileSync(s + "CODEOWNERS", "utf8"));
else if (a[0] === "api" && path.includes("/contents/")) err("gh: Not Found (HTTP 404)");
else err("unexpected gh call");
EOF
chmod +x "$SCRATCH/bin/gh"
# serve <fixture dir>: what the stand-in gh returns from now on. The fixture dates are moved once per
# test so the newest time is an hour ago, whatever day the test runs.
serve() {
  local shifted="$SCRATCH/shifted-${1:t}"
  if [[ ! -d "$shifted" ]]; then
    mkdir -p "$shifted"
    node -e '
      const fs = require("fs");
      const [src, dst] = process.argv.slice(1);
      const prs = JSON.parse(fs.readFileSync(src + "/prs.json", "utf8"));
      const keys = new Set(["createdAt", "updatedAt", "submittedAt", "committedDate", "authoredDate"]);
      const all = [];
      const walk = (o, f) => { if (Array.isArray(o)) o.forEach((x) => walk(x, f)); else if (o && typeof o === "object") for (const k of Object.keys(o)) { if (keys.has(k)) f(o, k); else walk(o[k], f); } };
      walk(prs, (o, k) => all.push(Date.parse(o[k])));
      const shift = Date.now() - 3600e3 - Math.max(...all);
      walk(prs, (o, k) => { o[k] = new Date(Date.parse(o[k]) + shift).toISOString().replace(/\.\d{3}Z$/, "Z"); });
      fs.writeFileSync(dst + "/prs.json", JSON.stringify(prs));
      for (const n of ["collaborators.json", "CODEOWNERS"]) if (fs.existsSync(src + "/" + n)) fs.copyFileSync(src + "/" + n, dst + "/" + n);
    ' "$1" "$shifted"
  fi
  rm -f -- "$SCRATCH/serve/"*(N)
  cp "$shifted"/* "$SCRATCH/serve/"
}
# fetch <repo>: the real fetch.mjs with the stand-in gh. Sets OUT and RC.
fetch() {
  OUT="$(PATH="$SCRATCH/bin:$PATH" node references/fetch.mjs "$1" 2>&1)"
  RC=$?
}
# edit_served <node expression on a>: change the served PR list in place, for example to push a new head.
edit_served() {
  node -e 'const fs=require("fs");const f=process.argv[1];let a=JSON.parse(fs.readFileSync(f,"utf8"));a=('"$1"');fs.writeFileSync(f,JSON.stringify(a));' "$SCRATCH/serve/prs.json"
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
expect_refused() { [[ $RC -ne 0 && "$OUT" == *"$1"* ]] && ok "$2 ($1)" || bad "$2 (want refusal $1)"; }
expect_has() { [[ $RC -eq 0 && "$OUT" == *"$2"* ]] && ok "$1" || bad "$1 (want $2)"; }
expect_not() { [[ $RC -eq 0 && "$OUT" != *"$2"* ]] && ok "$1" || bad "$1 (did not want $2)"; }
expect_eq() { [[ $RC -eq 0 && "$OUT" == "$2" ]] && ok "$1" || bad "$1 (want $2)"; }
schema() { sqlite3 -bail "$DB" ".read references/schema.sql" >/dev/null 2>&1 || { print "FAIL schema"; exit 1; }; }
finish() { print "passed=$PASSES failed=$FAILS"; [[ $FAILS -eq 0 ]]; }
