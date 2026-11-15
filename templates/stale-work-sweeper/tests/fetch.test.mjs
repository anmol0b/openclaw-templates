// fetch.mjs runs only fixed read-only gh calls, with no shell, and writes what ingest.sql reads.
// A stand-in `gh` on PATH records every call and serves the fixtures.
// Usage: node tests/fetch.test.mjs <package dir>
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};

const scratch = mkdtempSync(join(tmpdir(), "sws-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  const log = join(scratch, "gh-calls.jsonl");
  const fixtures = join(pkg, "tests", "fixtures", "example");
  execFileSync("mkdir", ["-p", bin]);
  // The stand-in gh: logs its arguments and prints the fixture for that read.
  writeFileSync(join(bin, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
const f = ${JSON.stringify(fixtures)};
const out = (o) => process.stdout.write(typeof o === "string" ? o : JSON.stringify(o));
if (process.env.GH_FAIL && a[0] === process.env.GH_FAIL) { process.stderr.write("HTTP 404: Not Found\\n"); process.exit(1); }
if (a[0] === "api" && a[1] === "user") out({ login: "example-owner", id: 1 });
else if (a[0] === "repo") out({ nameWithOwner: "example-org/example-repo", defaultBranchRef: { name: process.env.GH_DEFAULT || "main" }, hasIssuesEnabled: !process.env.GH_NO_ISSUES });
else if (a[0] === "api" && a[1] === "graphql") out(fs.readFileSync(f + "/branches.json", "utf8"));
else if (a[0] === "pr") out(fs.readFileSync(f + "/prs.json", "utf8"));
else if (a[0] === "issue") out(fs.readFileSync(f + "/issues.json", "utf8"));
else { process.stderr.write("unexpected gh call\\n"); process.exit(3); }
`);
  chmodSync(join(bin, "gh"), 0o755);
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH };
  const run = (args, extraEnv = {}) =>
    spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env: { ...env, ...extraEnv }, encoding: "utf8" });
  const calls = () => readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));

  const r = run(["example-org/example-repo"]);
  ok("fetch exits 0", r.status === 0, r.stderr);
  const s = JSON.parse(r.stdout.trim() || "{}");
  ok("summary has login, default branch and counts",
    s.login === "example-owner" && s.default_branch === "main" && s.branches === 15 && s.branches_total === 15 && s.prs === 4 && s.issues === 4, r.stdout);
  const dir = join(ws, "inbox", "example-org__example-repo");
  for (const f of ["user", "repo", "branches", "prs", "issues", "fetch"]) ok(`writes inbox/<repo>/${f}.json`, existsSync(join(dir, f + ".json")));

  const c = calls();
  ok("runs exactly five gh calls", c.length === 5, JSON.stringify(c.map((x) => x.slice(0, 2))));
  const verbs = c.map((x) => x.slice(0, 2).join(" "));
  ok("calls are user, repo view, graphql, pr list, issue list",
    JSON.stringify(verbs) === JSON.stringify(["api user", "repo view", "api graphql", "pr list", "issue list"]), verbs.join(", "));
  const gql = c[2];
  const query = gql[gql.indexOf("-f") + 1];
  ok("the graphql call is a query, never a mutation", /^query=query\(/.test(query) && !/mutation/i.test(query));
  ok("graphql variables use raw -f, never -F (which reads @files)", !gql.includes("-F") && gql.includes("base=main"));
  ok("no call uses an HTTP method flag or a write verb",
    !c.flat().some((a) => /^(-X|--method|--input|create|edit|close|comment|delete|merge|--add-label|--body-file)$/.test(a)));
  ok("PR and issue reads are limited to the owner", c[3].includes("--author") && c[3].includes("@me") && c[4].includes("--assignee") && c[4].includes("@me"));

  writeFileSync(log, "");
  run(["example-org/example-repo"]);
  ok("a second fetch makes the same calls", JSON.stringify(calls()) === JSON.stringify(c));

  writeFileSync(log, "");
  run(["example-org/example-repo"], { GH_DEFAULT: "@secret-file" });
  ok("a default branch starting with @ is passed as raw text", calls()[2].includes("base=@secret-file") && !calls()[2].includes("-F"));

  writeFileSync(log, "");
  const ni = run(["example-org/example-repo"], { GH_NO_ISSUES: "1" });
  ok("issues turned off: no issue read, zero issues", ni.status === 0 && calls().length === 4 && JSON.parse(ni.stdout).issues === 0, ni.stderr);

  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "$(id)/x", "-x/y", "a/-y", "", "a"]) {
    writeFileSync(log, "");
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && readFileSync(log, "utf8") === "", b.stderr);
  }

  const before = readFileSync(join(dir, "fetch.json"), "utf8");
  const f = run(["example-org/example-repo"], { GH_FAIL: "pr" });
  ok("a failed gh read exits 1 with the gh error line", f.status === 1 && f.stderr.includes("HTTP 404"), f.stderr);
  ok("a failed read writes nothing, so files stay from one fetch", readFileSync(join(dir, "fetch.json"), "utf8") === before);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
