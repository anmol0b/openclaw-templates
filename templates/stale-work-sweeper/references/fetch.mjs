// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs five fixed `gh` reads with no shell, writes their JSON output to
// inbox/<owner>__<repo>/, and prints a one-line JSON summary. It never writes to GitHub.
// The command is the same on every run for a repository, so the owner can approve it once
// with "Always allow here". ingest.sql reads the files it writes.
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LIMITS = { branches: 100, prs: 100, issues: 100 };
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;

// One GraphQL read: the newest branches (by last commit), each with its last commit,
// protection, open or merged PRs from it, and how it compares to the default branch.
// `compare` is computed by GitHub inside this one call; there is no call per branch.
export const BRANCHES_QUERY = `query($owner: String!, $name: String!, $base: String!) {
  repository(owner: $owner, name: $name) {
    refs(refPrefix: "refs/heads/", first: ${LIMITS.branches}, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
      totalCount
      nodes {
        name
        branchProtectionRule { pattern }
        target { ... on Commit { oid committedDate author { user { login } } } }
        associatedPullRequests(first: 5, states: [OPEN, MERGED], orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { number state headRefOid url }
        }
        compare(headRef: $base) { aheadBy behindBy status }
      }
    }
  }
}`;

export function reads(repo, defaultBranch) {
  const [owner, name] = repo.split("/");
  return {
    user: ["api", "user"],
    repo: ["repo", "view", repo, "--json", "nameWithOwner,defaultBranchRef,hasIssuesEnabled"],
    branches: defaultBranch === undefined ? null : [
      // -f (raw string), never -F: -F reads a local file for a value starting with "@".
      "api", "graphql", "-f", `query=${BRANCHES_QUERY}`,
      "-f", `owner=${owner}`, "-f", `name=${name}`, "-f", `base=${defaultBranch}`,
    ],
    prs: [
      "pr", "list", "--repo", repo, "--author", "@me", "--state", "open", "--limit", String(LIMITS.prs),
      "--json", "number,title,isDraft,updatedAt,headRefName,headRefOid,mergeable,statusCheckRollup,url,author",
    ],
    issues: [
      "issue", "list", "--repo", repo, "--assignee", "@me", "--state", "open", "--limit", String(LIMITS.issues),
      "--json", "number,title,updatedAt,url,assignees,author",
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

function main(argv) {
  const repo = argv[2];
  if (argv.length !== 3 || !REPO.test(repo || "")) {
    console.error("usage: node references/fetch.mjs <owner/repo>");
    process.exit(2);
  }
  const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "inbox", slug(repo));
  mkdirSync(dir, { recursive: true });
  const first = reads(repo);
  const user = gh("user", repo, first.user);
  const info = gh("repo", repo, first.repo);
  const defaultBranch = info && info.defaultBranchRef && info.defaultBranchRef.name;
  if (typeof user.login !== "string" || typeof defaultBranch !== "string" || info.nameWithOwner.toLowerCase() !== repo.toLowerCase()) {
    console.error(`gh read for ${repo} did not return a login, a default branch and the same repository`);
    process.exit(1);
  }
  const all = reads(repo, defaultBranch);
  const data = {
    user: { login: user.login },
    repo: { nameWithOwner: info.nameWithOwner, defaultBranch },
    branches: gh("branches", repo, all.branches),
    prs: gh("prs", repo, all.prs),
    // A repository with issues turned off (common for forks) has no assigned issues to read.
    issues: info.hasIssuesEnabled === false ? [] : gh("issues", repo, all.issues),
  };
  const refs = data.branches && data.branches.data && data.branches.data.repository && data.branches.data.repository.refs;
  if (!refs || !Array.isArray(refs.nodes) || !Array.isArray(data.prs) || !Array.isArray(data.issues)) {
    console.error(`gh reads for ${repo} did not return the expected lists`);
    process.exit(1);
  }
  // Write then rename, so ingest never reads a half-written file.
  for (const [name, value] of Object.entries(data)) {
    const file = join(dir, `${name}.json`);
    writeFileSync(file + ".tmp", JSON.stringify(value));
    renameSync(file + ".tmp", file);
  }
  const summary = {
    repo, login: user.login, default_branch: defaultBranch, issues_enabled: info.hasIssuesEnabled !== false,
    branches: refs.nodes.length, branches_total: refs.totalCount,
    prs: data.prs.length, issues: data.issues.length, limits: LIMITS,
    fetched_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  writeFileSync(join(dir, "fetch.json"), JSON.stringify(summary));
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
