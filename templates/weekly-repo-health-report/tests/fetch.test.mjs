// fetch.mjs runs only fixed read-only gh calls, with no shell, keeps only numbers, dates, fixed
// states and logins, and writes what ingest.sql reads. A stand-in `gh` on PATH records every call
// and serves the fixtures. Usage: node tests/fetch.test.mjs <package dir>
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};

const scratch = mkdtempSync(join(tmpdir(), "wrh-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  const log = join(scratch, "gh-calls.jsonl");
  const fixtures = join(pkg, "tests", "fixtures", "example");
  execFileSync("mkdir", ["-p", bin]);
  writeFileSync(join(bin, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
const f = ${JSON.stringify(fixtures)};
const has = (x) => a.includes(x);
const out = (n) => process.stdout.write(fs.readFileSync(f + "/" + n + ".json", "utf8"));
if (process.env.GH_FAIL && a[0] === process.env.GH_FAIL) { process.stderr.write("HTTP 404: Not Found\\n"); process.exit(1); }
if (a[0] === "repo") {
  const r = JSON.parse(fs.readFileSync(f + "/repo.json", "utf8"));
  if (process.env.GH_DEFAULT) r.defaultBranchRef.name = process.env.GH_DEFAULT;
  if (process.env.GH_NO_ISSUES) r.hasIssuesEnabled = false;
  if (process.env.GH_OTHER_REPO) r.nameWithOwner = "someone/else";
  process.stdout.write(JSON.stringify(r));
}
else if (a[0] === "pr" && has("all")) out("window_prs");
else if (a[0] === "pr" && has("open")) out("open_prs");
else if (a[0] === "issue" && has("all")) out("window_issues");
else if (a[0] === "issue" && has("open")) out("open_issues");
else if (a[0] === "run") process.env.GH_RUNS_OBJECT ? process.stdout.write("{}") : out("runs");
else { process.stderr.write("unexpected gh call\\n"); process.exit(3); }
`);
  chmodSync(join(bin, "gh"), 0o755);
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH };
  const run = (args, extraEnv = {}) =>
    spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env: { ...env, ...extraEnv }, encoding: "utf8" });
  const calls = () => readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const reset = () => writeFileSync(log, "");

  const t0 = Date.now();
  const r = run(["example-org/example-repo"]);
  ok("fetch exits 0", r.status === 0, r.stderr);
  const s = JSON.parse(r.stdout.trim() || "{}");
  ok("summary has the branch, window and counts",
    s.default_branch === "main" && s.window_days === 7 && s.counts.window_prs === 9 && s.counts.open_issues === 5 && s.counts.runs === 12, r.stdout);
  const span = Date.parse(s.fetched_at) - Date.parse(s.window_start);
  ok("the window is the last 7 days, ending at the fetch", span === 7 * 86400e3 && Math.abs(Date.parse(s.fetched_at) - t0) < 60e3, `${s.window_start} ${s.fetched_at}`);
  const dir = join(ws, "inbox", "example-org__example-repo");
  const files = ["window_prs", "window_issues", "open_prs", "open_issues", "runs", "fetch"];
  for (const f of files) ok(`writes inbox/<repo>/${f}.json`, existsSync(join(dir, f + ".json")));
  ok("leaves no temporary files", readdirSync(dir).every((n) => !n.endsWith(".tmp")), readdirSync(dir).join(","));

  const c = calls();
  ok("runs exactly six gh calls", c.length === 6, JSON.stringify(c.map((x) => x.slice(0, 2))));
  const verbs = c.map((x) => x.slice(0, 2).join(" "));
  ok("calls are repo view, then PR, issue and run lists",
    JSON.stringify(verbs) === JSON.stringify(["repo view", "pr list", "issue list", "pr list", "issue list", "run list"]), verbs.join(", "));
  ok("no call uses an HTTP method flag or a write verb",
    !c.flat().some((a) => /^(-X|--method|--input|-F|-f|api|create|edit|close|comment|delete|merge|rerun|cancel|--add-label|--body|--body-file)$/.test(a)));
  const fields = c.flatMap((x) => x[x.indexOf("--json") + 1].split(","));
  ok("no call asks for a title, body, comment, label or name", !fields.some((x) => /^(title|body|comments|labels|name|displayTitle|workflowName)$/.test(x)), fields.join(","));
  ok("window reads search by the computed start", c[1].includes(`updated:>=${s.window_start}`) && c[2].includes(`updated:>=${s.window_start}`));
  ok("the run read is limited to the default branch", c[5].includes("--branch") && c[5][c[5].indexOf("--branch") + 1] === "main");
  ok("every read has a --limit", c.slice(1).every((x) => x.includes("--limit")));

  const kept = files.filter((f) => f !== "fetch").map((f) => readFileSync(join(dir, f + ".json"), "utf8")).join("\n");
  ok("no title, body, review text or name reaches inbox/",
    !/IGNORE PREVIOUS|Ignore all previous|gh repo delete|Example"|"title"|"body"|"name"/.test(kept), kept.slice(0, 200));
  const wp = JSON.parse(readFileSync(join(dir, "window_prs.json"), "utf8"));
  ok("a PR keeps only the fields ingest reads",
    JSON.stringify(Object.keys(wp[0]).sort()) === JSON.stringify(["author", "authorIsBot", "closedAt", "createdAt", "isDraft", "mergedAt", "number", "reviews", "state"]), Object.keys(wp[0]).join(","));
  ok("a review keeps only author, bot flag, state and time", JSON.stringify(Object.keys(wp[0].reviews[0]).sort()) === JSON.stringify(["author", "authorIsBot", "state", "submittedAt"]));
  ok("an automated reviewer is flagged by login", wp[0].reviews.find((r) => r.author === "copilot-pull-request-reviewer").authorIsBot === true
    && wp[0].reviews.find((r) => r.author === "bob").authorIsBot === false);
  ok("zero times become null", wp.find((p) => p.number === 505).closedAt === null && wp.find((p) => p.number === 505).mergedAt === null);
  ok("a bot author is flagged", wp.find((p) => p.number === 504).authorIsBot === true && wp.find((p) => p.number === 501).authorIsBot === false);

  reset();
  run(["example-org/example-repo"]);
  const again = calls().map((x) => x.map((a) => a.replace(/updated:>=\S+/, "updated:>=T")));
  ok("a second fetch makes the same calls, apart from the window start",
    JSON.stringify(again) === JSON.stringify(c.map((x) => x.map((a) => a.replace(/updated:>=\S+/, "updated:>=T")))));

  reset();
  const ni = run(["example-org/example-repo"], { GH_NO_ISSUES: "1" });
  ok("issues turned off: no issue reads, zero issues", ni.status === 0 && calls().length === 4 && JSON.parse(ni.stdout).counts.open_issues === 0, ni.stderr);

  for (const branch of ["-x", "a b", "$(id)", "@file", ""]) {
    reset();
    const b = run(["example-org/example-repo"], { GH_DEFAULT: branch || " " });
    ok(`refuses default branch ${JSON.stringify(branch)} before the list reads`, b.status === 1 && calls().length === 1, b.stderr);
  }
  reset();
  const other = run(["example-org/example-repo"], { GH_OTHER_REPO: "1" });
  ok("refuses when gh returns another repository", other.status === 1 && calls().length === 1, other.stderr);

  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "$(id)/x", "-x/y", "a/-y", "", "a"]) {
    reset();
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && readFileSync(log, "utf8") === "", b.stderr);
  }
  reset();
  const two = run(["example-org/example-repo", "extra"]);
  ok("refuses extra arguments", two.status === 2 && readFileSync(log, "utf8") === "");

  const before = readFileSync(join(dir, "fetch.json"), "utf8");
  const f = run(["example-org/example-repo"], { GH_FAIL: "run" });
  ok("a failed gh read exits 1 with the gh error line", f.status === 1 && f.stderr.includes("HTTP 404"), f.stderr);
  ok("a failed read leaves fetch.json from the last good fetch", readFileSync(join(dir, "fetch.json"), "utf8") === before);
  const o = run(["example-org/example-repo"], { GH_RUNS_OBJECT: "1" });
  ok("a read that is not a list exits 1", o.status === 1 && o.stderr.includes("did not return a list"), o.stderr);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
