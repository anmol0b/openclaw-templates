// fetch.mjs runs only fixed gh reads, with no shell, reads each failed run's log once, caps what it keeps,
// and writes what ingest.sql reads. A stand-in `gh` on PATH records every call and serves the fixtures.
// Usage: node tests/fetch.test.mjs <package dir>
import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};

const scratch = mkdtempSync(join(tmpdir(), "cift-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  mkdirSync(bin);
  const log = join(scratch, "gh-calls.jsonl");
  const fx = join(scratch, "fx");
  cpSync(join(pkg, "tests", "fixtures", "example"), fx, { recursive: true });
  writeFileSync(join(bin, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
const fx = process.env.FX;
const fail = (m) => { process.stderr.write(m + "\\n"); process.exit(1); };
if (a[0] === "run" && a[1] === "list") { if (process.env.GH_LIST_FAIL) fail("HTTP 404: Not Found"); process.stdout.write(fs.readFileSync(fx + "/runs.json", "utf8")); }
else if (a[0] === "pr" && a[1] === "list") process.stdout.write(fs.readFileSync(fx + "/prs.json", "utf8"));
else if (a[0] === "run" && a[1] === "view" && a.includes("--log-failed")) {
  if (process.env.GH_LOG_FAIL) fail("log not found");
  const f = fx + "/gh/log-" + a[2] + ".txt"; process.stdout.write(fs.existsSync(f) ? fs.readFileSync(f, "utf8") : fs.readFileSync(fx + "/gh/log-big.txt", "utf8"));
} else if (a[0] === "run" && a[1] === "view" && a.includes("jobs")) {
  if (process.env.GH_JOBS_FAIL) fail("HTTP 502");
  const f = fx + "/gh/jobs-" + a[2] + ".json"; process.stdout.write(fs.existsSync(f) ? fs.readFileSync(f, "utf8") : fs.readFileSync(fx + "/gh/jobs-1002.json", "utf8"));
} else fail("unexpected gh call: " + a.join(" "));
`);
  chmodSync(join(bin, "gh"), 0o755);
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH, FX: fx };
  const run = (args, extra = {}) => spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env: { ...env, ...extra }, encoding: "utf8" });
  const calls = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
  const R = "example-org/example-repo";
  const dir = join(ws, "inbox", "example-org__example-repo");

  let r = run([R]);
  ok("fetch exits 0", r.status === 0, r.stderr);
  let s = JSON.parse(r.stdout.trim());
  ok("summary counts runs, PRs and failed runs", s.runs === 26 && s.prs === 1 && s.failed_runs === 4 && s.logs_fetched === 4 && s.failed_jobs === 4, r.stdout);
  for (const f of ["runs", "prs", "failures", "fetch"]) ok(`writes inbox/<repo>/${f}.json`, existsSync(join(dir, f + ".json")));
  const first = calls();
  ok("two list reads plus jobs and log for each failed run", first.length === 2 + 4 * 2, JSON.stringify(first.map((c) => c.slice(0, 3))));
  ok("every call is a read", first.every((c) => ["run list", "pr list", "run view"].includes(c.slice(0, 2).join(" "))));
  ok("every call names the repo", first.every((c) => c[c.indexOf("--repo") + 1] === R));
  ok("no call writes", !first.flat().some((a) => /^(rerun|cancel|create|comment|edit|close|delete|api|--body|--body-file|--title)$/.test(a)));
  ok("run views name the attempt", first.filter((c) => c[1] === "view").every((c) => c[c.indexOf("--attempt") + 1] === "1"));
  const want = JSON.parse(readFileSync(join(fx, "failures.json"), "utf8"));
  const got = JSON.parse(readFileSync(join(dir, "failures.json"), "utf8"));
  const key = (x) => x.run_id + ":" + x.job_id;
  ok("failures.json matches what the fixtures were built from", JSON.stringify(got.sort((a, b) => key(a).localeCompare(key(b)))) === JSON.stringify(want.sort((a, b) => key(a).localeCompare(key(b)))));
  ok("cancelled jobs are left out", !got.some((x) => x.job_name === "e2e"));

  // Logs are read once per run attempt.
  writeFileSync(log, "");
  r = run([R]);
  ok("a second fetch reads only the two lists", calls().length === 2 && JSON.parse(r.stdout).logs_fetched === 0, JSON.stringify(calls()));
  ok("a second fetch keeps the failures", JSON.parse(readFileSync(join(dir, "failures.json"), "utf8")).length === 4);

  // A cap of 10 new logs per fetch; the rest wait for the next one.
  const runs = JSON.parse(readFileSync(join(fx, "runs.json"), "utf8"));
  const many = Array.from({ length: 15 }, (_, k) => ({ ...runs[0], databaseId: 7000 + k, attempt: 1, conclusion: "failure", status: "completed", workflowName: "Big" }));
  writeFileSync(join(fx, "runs.json"), JSON.stringify([...many, ...runs]));
  // A 2 MB log with ANSI codes for the new runs.
  const line = (k) => `\u001b[31mtest (ubuntu-latest)\tUNKNOWN STEP\t2026-11-10T08:00:00.1234567Z ^[[1merror^[[0m: case ${k + 1} failed, GH_TOKEN=ghp_${"a".repeat(36)} with a very long message ${"x".repeat(400)}\u001b[0m`;
  writeFileSync(join(fx, "gh", "log-big.txt"), Array.from({ length: 5000 }, (_, k) => line(k)).join("\n"));
  writeFileSync(join(fx, "gh", "jobs-big.json"), "");
  writeFileSync(log, "");
  r = run([R]);
  s = JSON.parse(r.stdout);
  ok("at most 10 new logs per fetch", s.logs_fetched === 10 && s.logs_left_for_next_fetch === 5, r.stdout);
  r = run([R]);
  s = JSON.parse(r.stdout);
  ok("the next fetch reads the rest", s.logs_fetched === 5 && s.logs_left_for_next_fetch === 0, r.stdout);
  const big = JSON.parse(readFileSync(join(dir, "failures.json"), "utf8")).filter((x) => x.run_id >= 7000);
  ok("a big log keeps exactly 5 error lines of at most 200 characters", big.length === 15 && big.every((x) => x.error_lines.length === 5 && x.error_lines.every((l) => l.length <= 200)), JSON.stringify(big.map((x) => x.error_lines.length)));
  ok("a big log keeps an excerpt of at most 20 lines and 3000 characters", big.every((x) => x.excerpt.length > 1000 && x.excerpt.length <= 3000 && x.excerpt.split("\n").length <= 20));
  ok("the excerpt starts near the first error", big.every((x) => x.excerpt.split("\n")[0].includes("case 1 failed")));
  ok("no ANSI codes, caret codes or timestamps are kept", big.every((x) => !/\u001b|\^\[|\d{4}-\d\d-\d\dT\d\d:/.test(x.excerpt + x.error_lines.join(""))));
  ok("secret-looking strings in the log are masked", big.every((x) => !(x.excerpt + x.error_lines.join("")).includes("ghp_") && (x.excerpt + x.error_lines.join("")).includes("<masked>")));

  // Failures of the reads themselves.
  writeFileSync(join(fx, "runs.json"), JSON.stringify(runs));
  rmSync(join(dir, "logs"), { recursive: true, force: true });
  r = run([R], { GH_LOG_FAIL: "1" });
  s = JSON.parse(r.stdout);
  const nolog = JSON.parse(readFileSync(join(dir, "failures.json"), "utf8"));
  ok("an unreadable log still records the failed jobs and steps", r.status === 0 && nolog.length === 4 && nolog.every((x) => x.log_error === "log not found" && x.failed_steps.length > 0 && !x.log_found), r.stdout);
  rmSync(join(dir, "logs"), { recursive: true, force: true });
  r = run([R], { GH_JOBS_FAIL: "1" });
  s = JSON.parse(r.stdout);
  ok("an unreadable jobs list is reported and retried next time", r.status === 0 && s.errors.length === 4 && s.failed_jobs === 0, r.stdout);
  r = run([R], { GH_LIST_FAIL: "1" });
  ok("a failed list read exits 1 with the gh error line", r.status === 1 && r.stderr.includes("HTTP 404"), r.stderr);

  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "-x/y", "", "a"]) {
    writeFileSync(log, "");
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && calls().length === 0, b.stderr);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
