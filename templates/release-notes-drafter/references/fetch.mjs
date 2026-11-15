// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs three fixed `gh` reads with no shell: the repository's default branch, its
// releases, and the pull requests merged into the default branch since the base release.
// The base release is GitHub's latest release, or else the newest published one that is
// not a draft or prerelease. Its createdAt (the date of its tagged commit) is the cutoff;
// the search date is computed here, so the command itself is the same on every run and
// the owner can approve it once with "Always allow here". With no release yet, the cutoff
// is NO_RELEASE_DAYS ago. It writes JSON to inbox/<owner>__<repo>/, prints a one-line
// summary, and never writes to GitHub. ingest.sql reads the files.
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LIMITS = { releases: 30, prs: 300 };
export const NO_RELEASE_DAYS = 90;
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;
// A branch name that is safe as one argument and cannot read as a flag.
const BRANCH = /^[A-Za-z0-9_][A-Za-z0-9_./-]{0,199}$/;
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

export const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

export function pickBase(releases) {
  const published = releases.filter((r) => !r.isDraft && !r.isPrerelease && ISO.test(r.createdAt || ""));
  return published.find((r) => r.isLatest) ||
    published.sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))[0] || null;
}

export function reads(repo) {
  return {
    repo: ["repo", "view", repo, "--json", "nameWithOwner,defaultBranchRef"],
    releases: [
      "release", "list", "--repo", repo, "--limit", String(LIMITS.releases),
      "--json", "tagName,name,isDraft,isPrerelease,isLatest,publishedAt,createdAt",
    ],
    prs: (branch, since) => [
      "pr", "list", "--repo", repo, "--state", "merged", "--base", branch,
      "--limit", String(LIMITS.prs), "--search", `merged:>${since}`,
      "--json", "number,title,author,labels,mergedAt,url,body",
    ],
  };
}

export function slug(repo) {
  return repo.replace("/", "__");
}

function gh(name, repo, args) {
  try {
    const out = execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
    return JSON.parse(out);
  } catch (err) {
    const msg = String(err.stderr || err.message || err).trim().split("\n")[0];
    console.error(`gh ${name} read failed for ${repo}: ${msg}`);
    process.exit(1);
  }
}

function main(argv) {
  const repo = argv[2];
  if (argv.length !== 3 || !REPO.test(repo || "")) {
    console.error("usage: node references/fetch.mjs <owner/repo>");
    process.exit(2);
  }
  const r = reads(repo);
  const info = gh("repo", repo, r.repo);
  const branch = info?.defaultBranchRef?.name || "";
  if (!BRANCH.test(branch)) {
    console.error(`${repo}: default branch name is missing or not safe to use: ${JSON.stringify(branch).slice(0, 80)}`);
    process.exit(1);
  }
  const releases = gh("releases", repo, r.releases);
  if (!Array.isArray(releases)) {
    console.error(`gh releases read for ${repo} did not return a list`);
    process.exit(1);
  }
  const base = pickBase(releases);
  const since = base ? base.createdAt : iso(Date.now() - NO_RELEASE_DAYS * 864e5);
  const prs = gh("prs", repo, r.prs(branch, since));
  if (!Array.isArray(prs)) {
    console.error(`gh prs read for ${repo} did not return a list`);
    process.exit(1);
  }
  const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "inbox", slug(repo));
  mkdirSync(dir, { recursive: true });
  const write = (name, data) => {
    // Write then rename, so ingest never reads a half-written file.
    const file = join(dir, `${name}.json`);
    writeFileSync(file + ".tmp", JSON.stringify(data));
    renameSync(file + ".tmp", file);
  };
  write("releases", releases);
  write("prs", prs);
  const summary = {
    repo,
    default_branch: branch,
    base_tag: base ? base.tagName : null,
    since,
    releases: releases.length,
    prs: prs.length,
    limits: LIMITS,
    fetched_at: iso(Date.now()),
  };
  write("fetch", summary);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
