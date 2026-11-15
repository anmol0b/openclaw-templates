// fetch.mjs runs only the two fixed gh reads, with no shell, retries once on a GitHub 5xx,
// and writes what ingest.sql reads. A stand-in `gh` on PATH records every call.
// Usage: node tests/fetch.test.mjs <package dir>
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};

const scratch = mkdtempSync(join(tmpdir(), "dur-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  mkdirSync(bin);
  const log = join(scratch, "calls.jsonl");
  const fails504 = join(scratch, "fail-504-count");
  const fixtures = join(pkg, "tests", "fixtures", "example");
  writeFileSync(join(bin, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
if (process.env.GH_FAIL) { process.stderr.write(process.env.GH_FAIL + "\\n"); process.exit(1); }
const c = ${JSON.stringify(fails504)};
if (fs.existsSync(c)) { const n = Number(fs.readFileSync(c, "utf8")); if (n > 0) { fs.writeFileSync(c, String(n - 1)); process.stderr.write("HTTP 504: 504 Gateway Timeout (https://api.github.com/graphql)\\n"); process.exit(1); } }
const bot = a[a.indexOf("--author") + 1].replace("app/", "");
process.stdout.write(fs.readFileSync(${JSON.stringify(fixtures)} + "/" + bot + ".json", "utf8"));
`);
  chmodSync(join(bin, "gh"), 0o755);
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH };
  const run = (args, extra = {}) => spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env: { ...env, ...extra }, encoding: "utf8" });
  const calls = () => existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];

  const r = run(["example-org/example-repo"]);
  ok("fetch exits 0", r.status === 0, r.stderr);
  const s = JSON.parse(r.stdout.trim());
  ok("summary counts both bots", s.repo === "example-org/example-repo" && s.dependabot === 6 && s.renovate === 7 && s.limit === 30, r.stdout);
  ok("summary carries an ISO UTC time", /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(s.fetched_at));
  const dir = join(ws, "inbox", "example-org__example-repo");
  const prs = JSON.parse(readFileSync(join(dir, "prs.json"), "utf8"));
  ok("prs.json holds every PR, parsed", prs.length === 13 && prs.every((p) => p.bot && Array.isArray(p.updates) && Array.isArray(p.signals) && p.ci));
  ok("prs.json keeps the head SHA", prs.every((p) => /^[0-9a-f]{40}$/.test(p.headRefOid)));
  ok("leaves no temp files", !existsSync(join(dir, "prs.json.tmp")));

  const c = calls();
  ok("runs exactly two gh calls", c.length === 2, JSON.stringify(c));
  ok("both are pr list reads", c.every((a) => a[0] === "pr" && a[1] === "list"));
  ok("one per bot", JSON.stringify(c.map((a) => a[a.indexOf("--author") + 1])) === JSON.stringify(["app/dependabot", "app/renovate"]));
  ok("open PRs only, fixed limit", c.every((a) => a[a.indexOf("--state") + 1] === "open" && a[a.indexOf("--limit") + 1] === "30"));
  ok("every call names the repo", c.every((a) => a[a.indexOf("--repo") + 1] === "example-org/example-repo"));
  ok("no call passes a write verb or flag", !c.flat().some((a) => /^(review|comment|merge|close|edit|create|api|--approve|--body|--body-file|--admin|--auto)$/.test(a)));

  writeFileSync(log, "");
  run(["example-org/example-repo"]);
  ok("a second fetch makes the same calls", JSON.stringify(calls()) === JSON.stringify(c));

  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "$(id)/x", "-x/y", "a/-y", "", "a"]) {
    writeFileSync(log, "");
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && calls().length === 0, b.stderr);
  }
  writeFileSync(log, "");
  ok("refuses extra arguments", run(["example-org/example-repo", "--limit"]).status === 2 && calls().length === 0);

  // One retry on a GitHub 5xx.
  writeFileSync(log, "");
  writeFileSync(fails504, "1");
  const t = run(["example-org/example-repo"]);
  ok("one 504 is retried and the fetch succeeds", t.status === 0 && calls().length === 3, t.stderr + JSON.stringify(calls()));
  writeFileSync(log, "");
  writeFileSync(fails504, "2");
  const t2 = run(["example-org/example-repo"]);
  ok("a second 504 in a row fails the fetch", t2.status === 1 && t2.stderr.includes("HTTP 504") && calls().length === 2, t2.stderr);
  writeFileSync(fails504, "0");

  writeFileSync(log, "");
  const f = run(["example-org/example-repo"], { GH_FAIL: "HTTP 404: Not Found" });
  ok("a 404 is not retried and names the error", f.status === 1 && f.stderr.includes("HTTP 404") && calls().length === 1, f.stderr);
  ok("a failed fetch keeps the last good files", JSON.parse(readFileSync(join(dir, "prs.json"), "utf8")).length === 13);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
