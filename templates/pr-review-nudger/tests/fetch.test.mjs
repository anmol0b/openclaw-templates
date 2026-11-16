// fetch.mjs runs only fixed read-only gh calls, with no shell, keeps only the fields the steps need,
// and writes what ingest.sql reads. A stand-in `gh` on PATH records every call and serves the fixtures.
// Usage: node tests/fetch.test.mjs <package dir>
import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const pkg = resolve(process.argv[2] || ".");
const { codeownerLogins, collaboratorLogins, reducePr } = await import(join(pkg, "references", "fetch.mjs"));
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};

const scratch = mkdtempSync(join(tmpdir(), "prn-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  mkdirSync(bin);
  const log = join(scratch, "gh-calls.jsonl");
  const fixtures = join(pkg, "tests", "fixtures", "example");
  const fail504 = join(scratch, "fail-504");
  writeFileSync(join(bin, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
const f = ${JSON.stringify(fixtures)};
const out = (o) => process.stdout.write(typeof o === "string" ? o : JSON.stringify(o));
const err = (m, c = 1) => { process.stderr.write(m + "\\n"); process.exit(c); };
const path = a[a.length - 1];
if (process.env.GH_FAIL && a[0] === process.env.GH_FAIL) err("HTTP 401: Bad credentials");
if (a[0] === "pr" && fs.existsSync(${JSON.stringify(fail504)})) { fs.rmSync(${JSON.stringify(fail504)}); err("HTTP 504: 504 Gateway Timeout"); }
if (a[0] === "api" && a[1] === "user") out({ login: "example-owner", id: 1 });
else if (a[0] === "repo") out({ nameWithOwner: process.env.GH_OTHER ? "other/repo" : "example-org/example-repo" });
else if (a[0] === "pr") out(fs.readFileSync(f + "/prs.json", "utf8"));
else if (a[0] === "api" && path.includes("/collaborators")) {
  if (process.env.GH_NO_PUSH) err("gh: Must have push access to view repository collaborators. (HTTP 403)");
  if (process.env.GH_COLLAB_500) err("gh: Server Error (HTTP 500)");
  out(fs.readFileSync(f + "/collaborators.json", "utf8"));
}
else if (a[0] === "api" && path.includes("/contents/")) {
  const want = process.env.GH_CODEOWNERS_AT || ".github/CODEOWNERS";
  if (path.endsWith("/contents/" + want) && !process.env.GH_NO_CODEOWNERS) out(fs.readFileSync(f + "/CODEOWNERS", "utf8"));
  else err("gh: Not Found (HTTP 404)");
}
else err("unexpected gh call", 3);
`);
  chmodSync(join(bin, "gh"), 0o755);
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH };
  const run = (args, extra = {}) => spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env: { ...env, ...extra }, encoding: "utf8" });
  const calls = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
  const R = "example-org/example-repo";

  const r = run([R]);
  ok("fetch exits 0", r.status === 0, r.stderr);
  const s = JSON.parse(r.stdout.trim() || "{}");
  ok("summary has login, counts and sources",
    s.login === "example-owner" && s.prs === 10 && s.collaborators_readable === true && s.collaborators_cut === false
    && s.codeowners_path === ".github/CODEOWNERS" && s.candidates === 8 && s.limits.prs === 30, r.stdout);
  ok("summary carries an ISO UTC time", /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(s.fetched_at));
  const dir = join(ws, "inbox", "example-org__example-repo");
  for (const f of ["prs", "candidates", "fetch"]) ok(`writes inbox/<repo>/${f}.json`, existsSync(join(dir, f + ".json")));
  ok("leaves no temp files", !existsSync(join(dir, "prs.json.tmp")) && !existsSync(join(dir, "candidates.json.tmp")));

  const written = readFileSync(join(dir, "prs.json"), "utf8");
  ok("no PR, comment or review body is written", !/Please split|rm -rf|Automated summary|Thanks, will look|Looks reasonable/.test(written));
  ok("no commit message or email is written", !/Change for|@example\.com/.test(written));
  const prs = JSON.parse(written);
  const p108 = prs.find((p) => p.number === 108);
  ok("owner comments are counted, other comments only counted",
    p108.comments === 2 && p108.owner_comments === 1 && typeof p108.owner_last_comment_at === "string");
  ok("team requests are counted, not named", p108.requested_teams === 1 && p108.requested_users.length === 0);
  ok("a review bot is kept but not marked maintainer", p108.reviews.length === 1 && p108.reviews[0].maintainer === false);
  const p103 = prs.find((p) => p.number === 103);
  ok("last commit time is the newest commit", p103.last_commit_at > p103.created_at && p103.requested_users[0] === "carol");
  ok("a bot author is flagged", prs.find((p) => p.number === 107).author_is_bot === true);
  const cands = JSON.parse(readFileSync(join(dir, "candidates.json"), "utf8"));
  const names = cands.map((c) => `${c.login}:${c.source}`).sort().join(" ");
  ok("candidates: push collaborators, CODEOWNERS users, maintainer reviewers; no bot, no read-only user, no team",
    names === "carol:codeowner carol:collaborator carol:reviewer example-owner:collaborator ivan:codeowner ivan:collaborator ivan:reviewer kim:codeowner", names);

  const c = calls();
  const verbs = c.map((x) => x.slice(0, 2).join(" "));
  ok("calls: user, repo view, pr list, collaborators, CODEOWNERS (first path found)",
    JSON.stringify(verbs) === JSON.stringify(["api user", "repo view", "pr list", `api repos/${R}/collaborators?per_page=100&affiliation=all`, "api -H"]), verbs.join(", "));
  ok("open PRs only, fixed limit, the named repo", c[2].includes("open") && c[2][c[2].indexOf("--limit") + 1] === "30" && c[2][c[2].indexOf("--repo") + 1] === R);
  ok("no call uses an HTTP method flag, a raw field or a write verb",
    !c.flat().some((a) => /^(-X|--method|-f|-F|--field|--raw-field|--input|edit|comment|close|merge|create|review|--add-reviewer|--body|--body-file)$/.test(a)));
  ok("the only header asks for the raw file", c.flat().filter((a) => a === "-H").length === 1 && c[4][2] === "Accept: application/vnd.github.raw+json");

  writeFileSync(log, "");
  run([R]);
  ok("a second fetch makes the same calls", JSON.stringify(calls()) === JSON.stringify(c));

  writeFileSync(log, "");
  const nc = run([R], { GH_CODEOWNERS_AT: "docs/CODEOWNERS" });
  ok("CODEOWNERS is looked up in GitHub's order and the first found is used",
    nc.status === 0 && JSON.parse(nc.stdout).codeowners_path === "docs/CODEOWNERS"
    && JSON.stringify(calls().slice(4).map((x) => x.at(-1).split("/contents/")[1])) === JSON.stringify([".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]));

  const np = run([R], { GH_NO_PUSH: "1", GH_NO_CODEOWNERS: "1" });
  const nps = JSON.parse(np.stdout || "{}");
  ok("no push access and no CODEOWNERS: the fetch goes on with reviewers only",
    np.status === 0 && nps.collaborators_readable === false && nps.codeowners_path === "" && nps.candidates === 2, np.stdout + np.stderr);

  const before = readFileSync(join(dir, "fetch.json"), "utf8");
  const c5 = run([R], { GH_COLLAB_500: "1" });
  ok("a collaborators read that fails for another reason fails the fetch", c5.status === 1 && c5.stderr.includes("HTTP 500"), c5.stderr);
  const f = run([R], { GH_FAIL: "pr" });
  ok("a failed PR read exits 1 with the gh error line", f.status === 1 && f.stderr.includes("HTTP 401"), f.stderr);
  ok("a failed read writes nothing, so files stay from one fetch", readFileSync(join(dir, "fetch.json"), "utf8") === before);
  const o = run([R], { GH_OTHER: "1" });
  ok("a repo view for another repository fails the fetch", o.status === 1);

  writeFileSync(fail504, "1");
  const t = run([R]);
  ok("one GitHub 504 on the PR list is retried", t.status === 0, t.stderr);

  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "$(id)/x", "-x/y", "a/-y", "", "a"]) {
    writeFileSync(log, "");
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && readFileSync(log, "utf8") === "", b.stderr);
  }

  // The reducers on their own.
  ok("codeowners: users only, comments and teams skipped",
    JSON.stringify(codeownerLogins("* @org/team\n/a/ @kim @Kim2 # @hidden\n# @nope\nb/ dev@example.com @-x @y-\n")) === JSON.stringify(["kim", "Kim2"]));
  ok("collaborators: push users only",
    JSON.stringify(collaboratorLogins([{ login: "a", type: "User", permissions: { push: true } }, { login: "b", type: "User", permissions: { push: false } },
      { login: "c[bot]", type: "Bot", permissions: { push: true } }, { login: "d", type: "Organization", permissions: { push: true } }])) === JSON.stringify(["a"]));
  const big = reducePr({ number: 1, title: "t".repeat(500), author: { login: "x" }, reviewRequests: [{ __typename: "User", login: "bad login" }, { login: "ok" }] }, "me");
  ok("titles are cut to 300 characters and bad logins dropped", big.title.length === 300 && JSON.stringify(big.requested_users) === '["ok"]');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
