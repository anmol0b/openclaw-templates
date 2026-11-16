// fetch.mjs runs one fixed read-only gh call, with no shell, and writes what ingest.sql reads.
// A stand-in `gh` on PATH records every call and serves the fixture.
// Usage: node tests/fetch.test.mjs <package dir>
import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};

const scratch = mkdtempSync(join(tmpdir(), "ftw-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  const log = join(scratch, "gh-calls.jsonl");
  const tries = join(scratch, "tries");
  const fixture = join(pkg, "tests", "fixtures", "example", "graphql.json");
  mkdirSync(bin);
  // The stand-in gh: logs its arguments and prints the fixture, changed by env for some cases.
  writeFileSync(join(bin, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
if (process.env.GH_FAIL) { process.stderr.write(process.env.GH_FAIL + "\\n"); process.exit(1); }
if (process.env.GH_502_ONCE && !fs.existsSync(${JSON.stringify(tries)})) {
  fs.writeFileSync(${JSON.stringify(tries)}, "1"); process.stderr.write("HTTP 502: Bad Gateway\\n"); process.exit(1);
}
if (a[0] !== "api" || a[1] !== "graphql") { process.stderr.write("unexpected gh call\\n"); process.exit(3); }
const j = JSON.parse(fs.readFileSync(${JSON.stringify(fixture)}, "utf8"));
if (process.env.GH_OTHER_REPO) j.data.repository.nameWithOwner = "someone/else";
if (process.env.GH_NO_ISSUES) j.data.repository.hasIssuesEnabled = false;
if (process.env.GH_NO_REPO) j.data.repository = null;
process.stdout.write(JSON.stringify(j));
`);
  chmodSync(join(bin, "gh"), 0o755);
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH };
  const run = (args, extraEnv = {}) =>
    spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env: { ...env, ...extraEnv }, encoding: "utf8" });
  const calls = () => readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const R = "example-org/example-repo";

  const r = run([R]);
  ok("fetch exits 0", r.status === 0, r.stderr);
  const s = JSON.parse(r.stdout.trim() || "{}");
  ok("summary has login and counts with totals",
    s.login === "example-owner" && s.prs === 7 && s.prs_total === 7 && s.issues === 7 && s.issues_total === 7 && s.labels === 5 && s.labels_total === 5, r.stdout);
  const dir = join(ws, "inbox", "example-org__example-repo");
  for (const f of ["user", "repo", "labels", "prs", "issues", "fetch"]) ok(`writes inbox/<repo>/${f}.json`, existsSync(join(dir, f + ".json")));
  ok("no temporary files are left", !readdirSync(dir).some((f) => f.endsWith(".tmp")));

  const c = calls();
  ok("runs exactly one gh call", c.length === 1, JSON.stringify(c.map((x) => x.slice(0, 2))));
  ok("the call is gh api graphql", c[0][0] === "api" && c[0][1] === "graphql");
  const query = c[0][c[0].indexOf("-f") + 1];
  ok("the graphql call is a query, never a mutation", /^query=query\(/.test(query) && !/mutation/i.test(query));
  ok("the query asks for authorAssociation on PRs and issues", (query.match(/authorAssociation/g) || []).length === 2);
  ok("variables use raw -f, never -F (which reads @files)", !c[0].includes("-F") && c[0].includes("owner=example-org") && c[0].includes("name=example-repo"));
  ok("no call uses an HTTP method flag or a write verb",
    !c.flat().some((a) => /^(-X|--method|--input|create|edit|close|comment|delete|merge|--add-label|--body-file)$/.test(a)));

  const all = readdirSync(dir).map((f) => readFileSync(join(dir, f), "utf8")).join("\n");
  ok("no issue body is written", !all.includes("Steps to reproduce") && !all.includes('"body"'));
  const issues = JSON.parse(readFileSync(join(dir, "issues.json"), "utf8"));
  const prs = JSON.parse(readFileSync(join(dir, "prs.json"), "utf8"));
  const i25 = issues.find((x) => x.number === 25);
  ok("a body becomes its trimmed character count", i25 && i25.bodyChars === 9, JSON.stringify(i25));
  const p13 = prs.find((x) => x.number === 13), p11 = prs.find((x) => x.number === 11);
  ok("the owner's latest comment time is kept, not its text", p13.ownerLastCommentAt === "2026-11-08T10:00:00Z" && !("comments" in p13 && typeof p13.comments !== "number"));
  ok("someone else's comment is not the owner's", p11.ownerLastCommentAt === "" && p11.comments === 1);
  ok("a deleted account stays null", issues.find((x) => x.number === 27).author === null);
  ok("author type and association are passed through",
    prs.find((x) => x.number === 15).author.type === "Bot" && prs.find((x) => x.number === 12).authorAssociation === "FIRST_TIME_CONTRIBUTOR");
  ok("labels become a list of names", JSON.stringify(issues.find((x) => x.number === 26).labels) === JSON.stringify(["good first issue", "docs"]));
  ok("PR rows carry no issue-only counts", prs.every((x) => x.assignees === 0 && x.linkedPrs === 0 && x.bodyChars === 0));

  writeFileSync(log, "");
  run([R]);
  ok("a second fetch makes the same call", JSON.stringify(calls()) === JSON.stringify(c));

  writeFileSync(log, "");
  const ni = run([R], { GH_NO_ISSUES: "1" });
  ok("issues turned off: zero issues", ni.status === 0 && JSON.parse(ni.stdout).issues === 0 && JSON.parse(ni.stdout).issues_total === 0, ni.stderr);

  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "$(id)/x", "-x/y", "a/-y", "", "a", "@x/y"]) {
    writeFileSync(log, "");
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && readFileSync(log, "utf8") === "", b.stderr);
  }
  writeFileSync(log, "");
  ok("refuses extra arguments", run([R, "--jq"]).status === 2 && readFileSync(log, "utf8") === "");

  const before = readFileSync(join(dir, "fetch.json"), "utf8");
  const f = run([R], { GH_FAIL: "HTTP 404: Not Found" });
  ok("a failed gh read exits 1 with the gh error line", f.status === 1 && f.stderr.includes("HTTP 404"), f.stderr);
  ok("a failed read writes nothing", readFileSync(join(dir, "fetch.json"), "utf8") === before);
  const o = run([R], { GH_OTHER_REPO: "1" });
  ok("a response for another repository is refused and writes nothing", o.status === 1 && readFileSync(join(dir, "fetch.json"), "utf8") === before, o.stderr);
  const n = run([R], { GH_NO_REPO: "1" });
  ok("a response without the repository is refused", n.status === 1, n.stderr);
  const g = run([R], { GH_FAIL: "HTTP 502: Bad Gateway" });
  ok("a 502 on both tries fails", g.status === 1 && g.stderr.includes("HTTP 502"));

  writeFileSync(log, "");
  const t = run([R], { GH_502_ONCE: "1" });
  ok("one 502 is retried once", t.status === 0 && calls().length === 2, t.stderr);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
