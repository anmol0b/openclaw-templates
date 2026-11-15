// fetch.mjs runs only its three fixed gh reads, with no shell, picks the base release the way
// GitHub does, and computes the merge cutoff itself, so the command the owner approves never
// changes while the search date does. A stand-in `gh` on PATH records every call.
// Usage: node tests/fetch.test.mjs <package dir>
import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};
const { pickBase } = await import(pathToFileURL(join(pkg, "references", "fetch.mjs")).href);

// pickBase: GitHub's latest wins; drafts and prereleases never; newest published otherwise.
const r = (tagName, createdAt, extra = {}) => ({ tagName, createdAt, isDraft: false, isPrerelease: false, isLatest: false, ...extra });
ok("pickBase prefers GitHub's latest over a newer backport", pickBase([r("v6.4.6", "2026-11-12T00:00:00Z"), r("v8.3.8", "2026-11-11T00:00:00Z", { isLatest: true })]).tagName === "v8.3.8");
ok("pickBase skips a newer prerelease and a newer draft", pickBase([r("v2.0.0-rc.1", "2026-11-14T00:00:00Z", { isPrerelease: true }), r("v2.0.0", "2026-11-13T00:00:00Z", { isDraft: true }), r("v1.9.0", "2026-11-01T00:00:00Z")]).tagName === "v1.9.0");
ok("pickBase takes the newest published when none is marked latest", pickBase([r("v1.0.0", "2026-01-01T00:00:00Z"), r("v1.1.0", "2026-02-01T00:00:00Z")]).tagName === "v1.1.0");
ok("pickBase returns null with no published release", pickBase([r("v1.0.0", "2026-01-01T00:00:00Z", { isDraft: true })]) === null);

const scratch = mkdtempSync(join(tmpdir(), "rnd-fetch."));
try {
  const ws = join(scratch, "ws");
  cpSync(join(pkg, "references"), join(ws, "references"), { recursive: true });
  const bin = join(scratch, "bin");
  mkdirSync(bin);
  const log = join(scratch, "gh-calls.jsonl");
  const state = join(scratch, "state.json");
  const fixtures = join(pkg, "tests", "fixtures", "example");
  writeFileSync(join(bin, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
const s = JSON.parse(fs.readFileSync(${JSON.stringify(state)}, "utf8"));
if (s.fail === a[0] + " " + a[1]) { process.stderr.write("HTTP 404: Not Found\\n"); process.exit(1); }
if (a[0] === "repo") process.stdout.write(JSON.stringify({ nameWithOwner: a[2], defaultBranchRef: { name: s.branch } }));
else if (a[0] === "release") process.stdout.write(fs.readFileSync(s.releases, "utf8"));
else process.stdout.write(fs.readFileSync(${JSON.stringify(join(fixtures, "prs.json"))}, "utf8"));
`);
  chmodSync(join(bin, "gh"), 0o755);
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH };
  const setState = (s) => writeFileSync(state, JSON.stringify({ branch: "main", releases: join(fixtures, "releases.json"), ...s }));
  const run = (args) => spawnSync(process.execPath, ["references/fetch.mjs", ...args], { cwd: ws, env, encoding: "utf8" });
  const calls = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
  const R = "example-org/example-repo";

  setState({});
  const first = run([R]);
  ok("fetch exits 0", first.status === 0, first.stderr);
  const s1 = JSON.parse(first.stdout.trim());
  ok("summary names the base and the window", s1.base_tag === "v1.4.0" && s1.default_branch === "main" && s1.prs === 30 && s1.releases === 6, first.stdout);
  const c1 = calls();
  ok("runs exactly three gh calls", c1.length === 3, JSON.stringify(c1));
  ok("every call is a read", c1.map((c) => c.slice(0, 2).join(" ")).join(",") === "repo view,release list,pr list");
  ok("no call passes a write flag", !c1.flat().some((a) => /^(create|edit|delete|upload|--draft|--notes|--notes-file|api|merge|close|comment)$/.test(a)));
  const fixtureRel = JSON.parse(readFileSync(join(fixtures, "releases.json"), "utf8"));
  const v140 = fixtureRel.find((x) => x.tagName === "v1.4.0").createdAt;
  const search1 = c1[2][c1[2].indexOf("--search") + 1];
  ok("the search cutoff is the base release's createdAt, strictly after", search1 === `merged:>${v140}`, search1);
  ok("the pull request read names the default branch", c1[2][c1[2].indexOf("--base") + 1] === "main");
  const dir = join(ws, "inbox", "example-org__example-repo");
  for (const f of ["releases", "prs", "fetch"]) ok(`writes inbox/<repo>/${f}.json`, existsSync(join(dir, f + ".json")));

  // A later day with a newer release: the same command, a new internal search date.
  const newer = [{ ...fixtureRel[1], tagName: "v1.5.0", createdAt: "2026-11-20T10:00:00Z", isLatest: true }, ...fixtureRel.map((x) => ({ ...x, isLatest: false }))];
  writeFileSync(join(scratch, "rel-newer.json"), JSON.stringify(newer));
  writeFileSync(log, "");
  setState({ releases: join(scratch, "rel-newer.json") });
  const second = run([R]);
  const c2 = calls();
  const search2 = c2[2][c2[2].indexOf("--search") + 1];
  // run() passes the same two arguments both times: that is the whole outer command.
  ok("a later run with the same command succeeds", second.status === 0, second.stderr);
  ok("while the internal search date moves to the new base", search2 === "merged:>2026-11-20T10:00:00Z" && search2 !== search1, search2);
  ok("the other reads are byte for byte the same", JSON.stringify(c2.slice(0, 2)) === JSON.stringify(c1.slice(0, 2)));

  // No release yet: the cutoff is 90 days ago.
  writeFileSync(join(scratch, "rel-none.json"), "[]");
  writeFileSync(log, "");
  setState({ releases: join(scratch, "rel-none.json") });
  const none = JSON.parse(run([R]).stdout.trim());
  const since = Date.parse(none.since);
  ok("with no release the cutoff is 90 days ago", none.base_tag === null && Math.abs(Date.now() - 90 * 864e5 - since) < 120e3, none.since);

  // An unsafe default branch stops before the pull request read.
  for (const branch of ["-rf", "main; id", "", "../x"]) {
    writeFileSync(log, "");
    setState({ branch });
    const b = run([R]);
    ok(`refuses default branch ${JSON.stringify(branch)} before reading pull requests`, b.status === 1 && calls().length === 1, b.stderr);
  }
  for (const bad of ["../etc", "a/b/c", "a b/c", "a/b;id", "-x/y", "", "a"]) {
    writeFileSync(log, "");
    const b = run([bad]);
    ok(`refuses repo ${JSON.stringify(bad)} before calling gh`, b.status === 2 && calls().length === 0, b.stderr);
  }
  writeFileSync(log, "");
  setState({ fail: "pr list" });
  const f = run([R]);
  ok("a failed gh read exits 1 with the gh error line", f.status === 1 && f.stderr.includes("HTTP 404"), f.stderr);
  ok("a failed read keeps the last good window", JSON.parse(readFileSync(join(dir, "prs.json"), "utf8")).length === 30);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`passed=${passes} failed=${fails}`);
process.exit(fails ? 1 : 0);
