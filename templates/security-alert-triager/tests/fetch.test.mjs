// fetch.mjs runs only fixed read-only gh calls, with no shell, tells a turned-off source from one this login
// cannot read, keeps only the fields the triage needs, and writes what ingest.sql reads.
// tests/fake-gh.cjs on PATH records every call and serves the fixtures.
// Usage: node tests/fetch.test.mjs <package dir>
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};
const R = "example-org/example-repo";
const { classify, cover, reduceDependabot, reduceCodeScanning, reads } = await import(pathToFileURL(join(pkg, "references", "fetch.mjs")).href);

const scratch = mkdtempSync(join(tmpdir(), "sat-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  const serve = join(scratch, "serve");
  const log = join(scratch, "gh-calls.jsonl");
  const fixtures = join(pkg, "tests", "fixtures");
  mkdirSync(bin);
  mkdirSync(serve);
  copyFileSync(join(pkg, "tests", "fake-gh.cjs"), join(bin, "gh"));
  chmodSync(join(bin, "gh"), 0o755);
  const reset = () => {
    rmSync(serve, { recursive: true, force: true });
    cpSync(join(fixtures, "example"), serve, { recursive: true });
    writeFileSync(log, "");
  };
  const err = (name, fixture, extra = {}) =>
    writeFileSync(join(serve, name + ".err"), JSON.stringify({ ...JSON.parse(readFileSync(join(fixtures, "errors", fixture + ".err"), "utf8")), ...extra }));
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH, FAKE_GH_DIR: serve, FAKE_GH_LOG: log };
  const run = (args) => spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env, encoding: "utf8" });
  const calls = () => readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const dir = join(ws, "inbox", "example-org__example-repo");

  reset();
  const r = run([R]);
  ok("fetch exits 0", r.status === 0, r.stderr);
  const s = JSON.parse(r.stdout.trim() || "{}");
  ok("summary has both sources and counts",
    s.dependabot?.status === "ok" && s.dependabot.open === 6 && s.dependabot.dismissed === 1
    && s.code_scanning?.status === "ok" && s.code_scanning.open === 3 && s.code_scanning.dismissed === 1 && s.prs === 3, r.stdout);
  for (const f of ["dependabot", "code-scanning", "fetch"]) ok(`writes inbox/<repo>/${f}.json`, existsSync(join(dir, f + ".json")));

  const c = calls();
  ok("runs exactly six gh calls", c.length === 6, JSON.stringify(c));
  ok("the calls are the fixed reads, in order", JSON.stringify(c) === JSON.stringify(Object.values(reads(R))), JSON.stringify(c));
  ok("alert reads are plain GETs of the alert lists",
    c.filter((x) => x[0] === "api").every((x) => x.length === 2 && /^repos\/example-org\/example-repo\/(dependabot|code-scanning)\/alerts\?state=(open|dismissed)&per_page=(100|30)&sort=updated&direction=desc$/.test(x[1])),
    JSON.stringify(c));
  ok("no call uses an HTTP method, a field or a write verb",
    !c.flat().some((a) => /^(-X|--method|-f|-F|--field|--raw-field|--input|create|edit|close|comment|delete|merge|dismiss)$/.test(a)));
  ok("PR reads are limited to the two bot apps and three fields",
    c.filter((x) => x[0] === "pr").map((x) => x[x.indexOf("--author") + 1] + " " + x[x.indexOf("--json") + 1]).join("|")
      === "app/dependabot number,title,headRefName|app/renovate number,title,headRefName");

  const dep = JSON.parse(readFileSync(join(dir, "dependabot.json"), "utf8"));
  const cs = JSON.parse(readFileSync(join(dir, "code-scanning.json"), "utf8"));
  const raw = JSON.stringify(dep) + JSON.stringify(cs);
  ok("advisory descriptions, code scanning messages and help text are dropped",
    !/Ignore all previous|Ignore previous|"description"|"help"|"message"|full_description|dismissed_comment/.test(raw));
  ok("summaries are kept, capped at 200 characters", dep.every((a) => a.summary.length <= 200) && dep.some((a) => a.summary === "Prototype pollution in lodash"));
  ok("dismissed alerts carry their reason", dep.find((a) => a.number === 9)?.dismissed_reason === "not_used"
    && cs.find((a) => a.number === 40)?.dismissed_reason === "false positive");

  writeFileSync(log, "");
  run([R]);
  ok("a second fetch makes the same calls", JSON.stringify(calls()) === JSON.stringify(c));

  // Observed refusals: each source is recorded, not a failed fetch.
  reset();
  err("dependabot-open", "dependabot-disabled");
  err("code-scanning-open", "code-scanning-disabled");
  const d = run([R]);
  const ds = JSON.parse(d.stdout || "{}");
  ok("Dependabot turned off (403) and code scanning never run (404) are disabled",
    d.status === 0 && ds.dependabot?.status === "disabled" && ds.code_scanning?.status === "disabled"
    && ds.dependabot.message === "Dependabot alerts are disabled for this repository." && ds.code_scanning.message === "no analysis found", d.stdout + d.stderr);
  ok("a disabled source is not read again for dismissed alerts", calls().length === 4, JSON.stringify(calls()));
  ok("a disabled source writes an empty list", readFileSync(join(dir, "dependabot.json"), "utf8") === "[]");

  reset();
  err("dependabot-open", "dependabot-no-access");
  err("code-scanning-open", "code-scanning-no-access");
  const n = run([R]);
  const ns = JSON.parse(n.stdout || "{}");
  ok("not authorized (403) is no_access for both sources",
    n.status === 0 && ns.dependabot?.status === "no_access" && ns.code_scanning?.status === "no_access", n.stdout + n.stderr);
  ok("the gh scope hint on stderr is not taken as the message", !n.stdout.includes("admin:repo_hook"));

  reset();
  writeFileSync(join(serve, "dependabot-open.json"), "[]");
  writeFileSync(join(serve, "dependabot-dismissed.json"), "[]");
  const e = run([R]);
  ok("no alerts is ok with zero open", e.status === 0 && JSON.parse(e.stdout).dependabot.status === "ok" && JSON.parse(e.stdout).dependabot.open === 0, e.stdout);

  ok("classify: GitHub's docs messages", classify(403, "Advanced Security must be enabled for this repository to use code scanning.") === "disabled"
    && classify(404, "Not Found") === "no_access" && classify(500, "Server Error") === null && classify(0, "network") === null);

  // Failures that are not about the feature or access stop the fetch and leave the last files in place.
  reset();
  run([R]);
  const before = readFileSync(join(dir, "fetch.json"), "utf8");
  err("code-scanning-open", "server-error", { once: true });
  const once = run([R]);
  ok("one HTTP 502 is retried", once.status === 0 && calls().filter((x) => x[1]?.includes("code-scanning/alerts?state=open")).length === 3, once.stderr);
  reset();
  run([R]);
  const kept = readFileSync(join(dir, "fetch.json"), "utf8");
  err("code-scanning-open", "server-error");
  const f = run([R]);
  ok("a server error twice fails the fetch with the HTTP status", f.status === 1 && f.stderr.includes("HTTP 502"), f.stderr);
  ok("a failed fetch writes nothing", readFileSync(join(dir, "fetch.json"), "utf8") === kept && before.length > 0);
  reset();
  err("prs-dependabot", "dependabot-no-access");
  const p = run([R]);
  ok("a failed PR read fails the fetch", p.status === 1 && p.stderr.includes("pr list"), p.stderr);

  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "$(id)/x", "-x/y", "a/-y", "", "a", "a/b?x=1"]) {
    writeFileSync(log, "");
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && readFileSync(log, "utf8") === "", b.stderr);
  }

  // Which bot PR covers an alert.
  const prs = JSON.parse(readFileSync(join(fixtures, "example", "prs-dependabot.json"), "utf8"))
    .concat(JSON.parse(readFileSync(join(fixtures, "example", "prs-renovate.json"), "utf8")));
  const cv = (pkgName, patched, list = prs) => cover({ package: pkgName, patched_version: patched }, list);
  ok("cover: a PR to the patched version fixes it", JSON.stringify(cv("lodash", "4.17.21")) === '{"covering_pr":101,"covering_fixes":"yes"}');
  ok("cover: a PR below the patched version does not", JSON.stringify(cv("requests", "2.32.0")) === '{"covering_pr":201,"covering_fixes":"no"}');
  ok("cover: a branch-only match is unknown", JSON.stringify(cv("minimist", "1.2.8")) === '{"covering_pr":102,"covering_fixes":"unknown"}');
  ok("cover: no patched version is unknown", cv("lodash", "").covering_fixes === "unknown");
  ok("cover: a longer package name is not a match", cv("lodash.merge", "4.6.2").covering_pr === null);
  ok("cover: a scoped package in a title matches",
    JSON.stringify(cv("@types/node", "20.1.0", [{ number: 7, title: "Bump @types/node from 20.0.0 to 20.2.5", headRefName: "dependabot/npm_and_yarn/types/node-20.2.5" }])) === '{"covering_pr":7,"covering_fixes":"yes"}');
  ok("cover: the fixing PR wins over one that does not",
    cv("requests", "2.32.0", [...prs, { number: 9, title: "Update dependency requests to v2.32.3", headRefName: "renovate/requests-2.x" }]).covering_pr === 9);

  const fx = JSON.parse(readFileSync(join(fixtures, "example", "code-scanning-open.json"), "utf8"));
  const red = reduceCodeScanning(fx[2]);
  ok("code scanning without a security level is unrated, keeps the rule severity", red.severity === "unrated" && red.rule_severity === "note");
  const big = reduceDependabot({ ...JSON.parse(readFileSync(join(fixtures, "example", "dependabot-open.json"), "utf8"))[0], security_advisory: { summary: "x".repeat(5000), severity: "high", ghsa_id: "GHSA-aaaa-bbbb-cccc" } });
  ok("a long summary is cut to 200 characters", big.summary.length === 200);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
