// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs six fixed `gh` reads with no shell: open and recently dismissed Dependabot alerts,
// open and recently dismissed code scanning alerts, and the open Dependabot and Renovate PRs.
// It keeps only the fields the triage needs (no advisory descriptions, no code scanning
// messages or help text), writes them to inbox/<owner>__<repo>/, and prints a one-line JSON
// summary. It never writes to GitHub. The command is the same on every run for a repository,
// so the owner can approve it once with "Always allow here". ingest.sql reads the files it writes.
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LIMITS = { open: 100, dismissed: 30, prs: 100 };
export const CAPS = { summary: 200, rule_description: 200, path: 300, package: 214, manifest: 300, range: 100, version: 64 };
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;

export function reads(repo) {
  const q = (state, n) => `?state=${state}&per_page=${n}&sort=updated&direction=desc`;
  const prs = (author) => [
    "pr", "list", "--repo", repo, "--state", "open", "--author", author,
    "--limit", String(LIMITS.prs), "--json", "number,title,headRefName",
  ];
  return {
    // In the order main() runs them: the PRs first, so alerts can be matched to them.
    prs_dependabot: prs("app/dependabot"),
    prs_renovate: prs("app/renovate"),
    dependabot_open: ["api", `repos/${repo}/dependabot/alerts${q("open", LIMITS.open)}`],
    dependabot_dismissed: ["api", `repos/${repo}/dependabot/alerts${q("dismissed", LIMITS.dismissed)}`],
    code_scanning_open: ["api", `repos/${repo}/code-scanning/alerts${q("open", LIMITS.open)}`],
    code_scanning_dismissed: ["api", `repos/${repo}/code-scanning/alerts${q("dismissed", LIMITS.dismissed)}`],
  };
}

export function slug(repo) {
  return repo.replace("/", "__");
}

// What an alert read that GitHub refused means. Observed with gh 2.102 (November 2026):
//   403 "Dependabot alerts are disabled for this repository."    -> disabled
//   404 "no analysis found" (code scanning never ran)             -> disabled
//   403 "You are not authorized to perform this operation."       -> no_access
//   403 "You are not authorized to read code scanning alerts."    -> no_access
// From GitHub's docs, not observed: 403 "Advanced Security must be enabled ..." -> disabled,
// 404 "Not Found" (repository not visible to this login) -> no_access.
// Anything else (5xx after one retry, network) fails the fetch.
export function classify(status, message) {
  if (status !== 401 && status !== 403 && status !== 404) return null;
  if (/disabled|not enabled|must be enabled|no analysis found/i.test(message)) return "disabled";
  return "no_access";
}

// One gh call. Returns { data } or { status, message } for an HTTP error.
// gh prints the error body as JSON on stdout and "gh: <message> (HTTP <code>)" as the first
// stderr line; later stderr lines can be unrelated scope hints, so only the first is used.
function gh(args) {
  for (let attempt = 1; ; attempt++) {
    try {
      return { data: JSON.parse(execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] })) };
    } catch (err) {
      const line = String(err.stderr || err.message || err).trim().split("\n")[0];
      const m = /\(HTTP (\d{3})\)/.exec(line);
      const status = m ? Number(m[1]) : 0;
      if (attempt === 1 && status >= 502 && status <= 504) continue;
      let message = line.replace(/^gh: /, "").replace(/ \(HTTP \d{3}\)$/, "");
      try {
        const body = JSON.parse(String(err.stdout || ""));
        if (body && typeof body.message === "string") message = body.message;
      } catch { /* keep the stderr line */ }
      return { status, message: message.slice(0, 200) };
    }
  }
}

const str = (v, cap) => (typeof v === "string" ? v.slice(0, cap) : "");

export function reduceDependabot(a) {
  const pkg = (a.dependency && a.dependency.package) || {};
  const adv = a.security_advisory || {};
  const vuln = a.security_vulnerability || {};
  return {
    number: a.number,
    state: a.state,
    created_at: a.created_at,
    updated_at: a.updated_at,
    html_url: str(a.html_url, 300),
    ecosystem: str(pkg.ecosystem, 30),
    package: str(pkg.name, CAPS.package),
    manifest_path: str(a.dependency && a.dependency.manifest_path, CAPS.manifest),
    scope: str(a.dependency && a.dependency.scope, 20),
    ghsa_id: str(adv.ghsa_id, 40),
    cve_id: str(adv.cve_id, 40),
    severity: str(adv.severity || vuln.severity, 20),
    summary: str(adv.summary, CAPS.summary),
    vulnerable_range: str(vuln.vulnerable_version_range, CAPS.range),
    patched_version: str(vuln.first_patched_version && vuln.first_patched_version.identifier, CAPS.version),
    dismissed_reason: str(a.dismissed_reason, 40),
  };
}

export function reduceCodeScanning(a) {
  const rule = a.rule || {};
  const inst = a.most_recent_instance || {};
  const loc = inst.location || {};
  return {
    number: a.number,
    state: a.state,
    created_at: a.created_at,
    updated_at: a.updated_at,
    html_url: str(a.html_url, 300),
    rule_id: str(rule.id, 200),
    rule_severity: str(rule.severity, 20),
    severity: str(rule.security_severity_level, 20) || "unrated",
    rule_description: str(rule.description, CAPS.rule_description),
    tool: str(a.tool && a.tool.name, 60),
    path: str(loc.path, CAPS.path),
    start_line: Number.isInteger(loc.start_line) ? loc.start_line : null,
    dismissed_reason: str(a.dismissed_reason, 40),
  };
}

// Leading numeric parts of a version, or null.
function parts(v) {
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?/.exec(String(v || "").trim());
  return m ? [Number(m[1]), Number(m[2] || 0), Number(m[3] || 0)] : null;
}
function atLeast(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return true;
}
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Which open bot PR already covers an alert. A PR covers a package when its title names the
// package as a word, or its branch has "/<package>-". fixes: yes when the version after "to"
// reaches the first patched version, no when it is lower, unknown when either is missing.
// Grouped PRs ("Bump the npm group with 3 updates") name no package and are not matched.
export function cover(alert, prs) {
  const name = String(alert.package || "").toLowerCase();
  if (!name) return { covering_pr: null, covering_fixes: "" };
  const word = new RegExp(`(^|[\\s\`'"(])${esc(name)}($|[\\s\`'"),:])`);
  const rank = { yes: 3, unknown: 2, no: 1 };
  let best = { covering_pr: null, covering_fixes: "" };
  for (const pr of prs) {
    const title = String(pr.title || "").toLowerCase();
    const branch = String(pr.headRefName || "").toLowerCase();
    const at = title.search(word);
    if (at < 0 && !branch.includes(`/${name}-`)) continue;
    const to = at < 0 ? null : /\bto\s+v?(\d[\w.+-]*)/.exec(title.slice(at));
    const target = to && parts(to[1]);
    const patched = parts(alert.patched_version);
    const fixes = target && patched ? (atLeast(target, patched) ? "yes" : "no") : "unknown";
    if (!best.covering_pr || rank[fixes] > rank[best.covering_fixes]) best = { covering_pr: pr.number, covering_fixes: fixes };
  }
  return best;
}

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function main(argv) {
  const repo = argv[2];
  if (argv.length !== 3 || !REPO.test(repo || "")) {
    console.error("usage: node references/fetch.mjs <owner/repo>");
    process.exit(2);
  }
  const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "inbox", slug(repo));
  mkdirSync(dir, { recursive: true });
  const r = reads(repo);

  const prs = [];
  for (const name of ["prs_dependabot", "prs_renovate"]) {
    const res = gh(r[name]);
    if (!res.data) fail(`gh pr list (${name}) failed for ${repo}: HTTP ${res.status} ${res.message}`);
    if (!Array.isArray(res.data)) fail(`gh pr list (${name}) for ${repo} did not return a list`);
    for (const p of res.data) prs.push({ number: p.number, title: String(p.title || ""), headRefName: String(p.headRefName || "") });
  }

  const sources = {};
  for (const [src, reduce] of [["dependabot", reduceDependabot], ["code_scanning", reduceCodeScanning]]) {
    const open = gh(r[`${src}_open`]);
    if (!open.data) {
      const status = classify(open.status, open.message);
      if (!status) fail(`gh api (${src} alerts) failed for ${repo}: HTTP ${open.status} ${open.message}`);
      sources[src] = { status, message: open.message, open: 0, dismissed: 0, alerts: [] };
      continue;
    }
    const dismissed = gh(r[`${src}_dismissed`]);
    if (!dismissed.data) fail(`gh api (${src} dismissed alerts) failed for ${repo}: HTTP ${dismissed.status} ${dismissed.message}`);
    if (!Array.isArray(open.data) || !Array.isArray(dismissed.data)) fail(`gh api (${src} alerts) for ${repo} did not return a list`);
    const alerts = [...open.data, ...dismissed.data].map(reduce);
    if (src === "dependabot") for (const a of alerts) Object.assign(a, a.state === "open" ? cover(a, prs) : { covering_pr: null, covering_fixes: "" });
    sources[src] = { status: "ok", message: "", open: open.data.length, dismissed: dismissed.data.length, alerts };
  }

  // Write then rename, so ingest never reads a half-written file.
  for (const [src, file] of [["dependabot", "dependabot"], ["code_scanning", "code-scanning"]]) {
    const f = join(dir, `${file}.json`);
    writeFileSync(f + ".tmp", JSON.stringify(sources[src].alerts));
    renameSync(f + ".tmp", f);
  }
  const summary = {
    repo,
    dependabot: { status: sources.dependabot.status, message: sources.dependabot.message, open: sources.dependabot.open, dismissed: sources.dependabot.dismissed },
    code_scanning: { status: sources.code_scanning.status, message: sources.code_scanning.message, open: sources.code_scanning.open, dismissed: sources.code_scanning.dismissed },
    prs: prs.length,
    limits: LIMITS,
    fetched_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  writeFileSync(join(dir, "fetch.json"), JSON.stringify(summary));
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
