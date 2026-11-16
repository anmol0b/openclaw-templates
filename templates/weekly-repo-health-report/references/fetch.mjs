// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs six fixed `gh` reads with no shell: the repository, PRs and issues updated in the
// last WINDOW_DAYS, all open PRs and issues, and recent workflow runs on the default branch.
// The window start is computed here, so the command is the same on every run and the owner
// can approve it once with "Always allow here".
// Each record is cut down to numbers, dates, fixed states and logins before it is written:
// no title, body, comment, review text, name or label reaches inbox/. It writes JSON to
// inbox/<owner>__<repo>/, prints a one-line summary, and never writes to GitHub.
// ingest.sql reads the files.
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const WINDOW_DAYS = 7;
export const LIMITS = { window_prs: 300, window_issues: 300, open_prs: 500, open_issues: 500, runs: 200 };
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;
// A branch name that is safe as one argument and cannot read as a flag.
const BRANCH = /^[A-Za-z0-9_][A-Za-z0-9_./-]{0,199}$/;
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

export const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
// gh prints a missing time as null or as the zero time 0001-01-01T00:00:00Z.
const time = (t) => (typeof t === "string" && !t.startsWith("0001-") ? t : null);
const login = (a) => (a && typeof a.login === "string" ? a.login : "");
const isBot = (a) => Boolean(a && (a.is_bot === true || /\[bot\]$/.test(login(a))));
// gh gives review authors no is_bot flag, so automated reviewers are recognized by login.
// A review bot with an ordinary login is counted as a reviewer (an accepted edge case).
const REVIEW_BOT = /(\[bot\]$|^app\/|-bot$|^copilot-pull-request-reviewer$|^copilot$)/i;

// Only these fields are kept. Anything else gh returns is dropped here.
export const keep = {
  windowPr: (p) => ({
    number: p.number, state: p.state, isDraft: p.isDraft === true,
    createdAt: time(p.createdAt), mergedAt: time(p.mergedAt), closedAt: time(p.closedAt),
    author: login(p.author), authorIsBot: isBot(p.author),
    reviews: (Array.isArray(p.reviews) ? p.reviews : [])
      .map((r) => ({ author: login(r.author), authorIsBot: REVIEW_BOT.test(login(r.author)), state: r.state, submittedAt: time(r.submittedAt) })),
  }),
  windowIssue: (i) => ({ number: i.number, state: i.state, createdAt: time(i.createdAt), closedAt: time(i.closedAt) }),
  openPr: (p) => ({
    number: p.number, isDraft: p.isDraft === true, createdAt: time(p.createdAt), updatedAt: time(p.updatedAt),
    authorIsBot: isBot(p.author),
  }),
  openIssue: (i) => ({ number: i.number, createdAt: time(i.createdAt), updatedAt: time(i.updatedAt) }),
  run: (r) => ({ id: r.databaseId, status: r.status, conclusion: r.conclusion || "", createdAt: time(r.createdAt) }),
};

export function reads(repo, branch, since) {
  return {
    repo: ["repo", "view", repo, "--json", "nameWithOwner,defaultBranchRef,hasIssuesEnabled"],
    windowPrs: [
      "pr", "list", "--repo", repo, "--state", "all", "--search", `updated:>=${since}`,
      "--limit", String(LIMITS.window_prs), "--json", "number,state,isDraft,createdAt,mergedAt,closedAt,author,reviews",
    ],
    windowIssues: [
      "issue", "list", "--repo", repo, "--state", "all", "--search", `updated:>=${since}`,
      "--limit", String(LIMITS.window_issues), "--json", "number,state,createdAt,closedAt",
    ],
    openPrs: [
      "pr", "list", "--repo", repo, "--state", "open",
      "--limit", String(LIMITS.open_prs), "--json", "number,isDraft,createdAt,updatedAt,author",
    ],
    openIssues: [
      "issue", "list", "--repo", repo, "--state", "open",
      "--limit", String(LIMITS.open_issues), "--json", "number,createdAt,updatedAt",
    ],
    runs: [
      "run", "list", "--repo", repo, "--branch", branch,
      "--limit", String(LIMITS.runs), "--json", "databaseId,status,conclusion,createdAt",
    ],
  };
}

export function slug(repo) {
  return repo.replace("/", "__");
}

function gh(name, repo, args) {
  try {
    return JSON.parse(execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] }));
  } catch (err) {
    const msg = String(err.stderr || err.message || err).trim().split("\n")[0];
    console.error(`gh ${name} read failed for ${repo}: ${msg}`);
    process.exit(1);
  }
}

function list(name, repo, args, fn) {
  const value = gh(name, repo, args);
  if (!Array.isArray(value)) {
    console.error(`gh ${name} read for ${repo} did not return a list`);
    process.exit(1);
  }
  return value.map(fn);
}

function main(argv) {
  const repo = argv[2];
  if (argv.length !== 3 || !REPO.test(repo || "")) {
    console.error("usage: node references/fetch.mjs <owner/repo>");
    process.exit(2);
  }
  const now = Date.now();
  const fetchedAt = iso(now);
  const since = iso(now - WINDOW_DAYS * 86400e3);
  const info = gh("repo", repo, reads(repo, "", since).repo);
  const branch = info && info.defaultBranchRef && info.defaultBranchRef.name;
  if (typeof info.nameWithOwner !== "string" || info.nameWithOwner.toLowerCase() !== repo.toLowerCase()) {
    console.error(`gh read for ${repo} did not return the same repository`);
    process.exit(1);
  }
  if (!BRANCH.test(branch || "")) {
    console.error(`${repo}: default branch name is missing or not safe to use: ${JSON.stringify(branch || "").slice(0, 80)}`);
    process.exit(1);
  }
  const r = reads(repo, branch, since);
  const issuesOn = info.hasIssuesEnabled !== false;
  const data = {
    window_prs: list("window PRs", repo, r.windowPrs, keep.windowPr),
    // A repository with issues turned off has no issues to read.
    window_issues: issuesOn ? list("window issues", repo, r.windowIssues, keep.windowIssue) : [],
    open_prs: list("open PRs", repo, r.openPrs, keep.openPr),
    open_issues: issuesOn ? list("open issues", repo, r.openIssues, keep.openIssue) : [],
    runs: list("runs", repo, r.runs, keep.run),
  };
  const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "inbox", slug(repo));
  mkdirSync(dir, { recursive: true });
  // Write then rename, so ingest never reads a half-written file. fetch.json goes last.
  for (const [name, value] of Object.entries(data)) {
    const file = join(dir, `${name}.json`);
    writeFileSync(file + ".tmp", JSON.stringify(value));
    renameSync(file + ".tmp", file);
  }
  const summary = {
    repo, default_branch: branch, issues_enabled: issuesOn,
    window_days: WINDOW_DAYS, window_start: since, fetched_at: fetchedAt,
    counts: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, v.length])),
    limits: LIMITS,
  };
  if (!ISO.test(since) || !ISO.test(fetchedAt)) process.exit(1);
  const file = join(dir, "fetch.json");
  writeFileSync(file + ".tmp", JSON.stringify(summary));
  renameSync(file + ".tmp", file);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
