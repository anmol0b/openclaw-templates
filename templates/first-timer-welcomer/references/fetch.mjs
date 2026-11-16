// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs one fixed `gh api graphql` query with no shell: the owner's login, the repository's
// labels, the newest open PRs and issues with each author's association to the repository.
// It writes inbox/<owner>__<repo>/{user,repo,labels,prs,issues,fetch}.json and prints a one-line
// JSON summary. It never writes to GitHub.
// Issue bodies are read only to count their characters; no body or comment text is written.
// The command is the same on every run for a repository, so the owner can approve it once
// with "Always allow here". ingest.sql reads the files it writes.
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LIMITS = { labels: 100, prs: 50, issues: 100, comments: 30 };
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;

// `authorAssociation` is only in the GraphQL API: `gh pr list --json` and `gh issue list --json`
// do not offer it (gh 2.102). `viewerDidAuthor` marks the owner's own comments without reading them.
export const QUERY = `query($owner: String!, $name: String!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    nameWithOwner
    hasIssuesEnabled
    labels(first: ${LIMITS.labels}, orderBy: {field: NAME, direction: ASC}) { totalCount nodes { name } }
    pullRequests(states: OPEN, first: ${LIMITS.prs}, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes {
        number title url createdAt updatedAt isDraft authorAssociation
        author { __typename login }
        labels(first: 20) { nodes { name } }
        comments(last: ${LIMITS.comments}) { totalCount nodes { viewerDidAuthor createdAt } }
      }
    }
    issues(states: OPEN, first: ${LIMITS.issues}, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes {
        number title url createdAt updatedAt authorAssociation body
        author { __typename login }
        assignees(first: 1) { totalCount }
        labels(first: 20) { nodes { name } }
        closedByPullRequestsReferences(first: 1, includeClosedPrs: false) { totalCount }
        comments(last: ${LIMITS.comments}) { totalCount nodes { viewerDidAuthor createdAt } }
      }
    }
  }
}`;

export function reads(repo) {
  const [owner, name] = repo.split("/");
  // -f (raw string), never -F: -F reads a local file for a value starting with "@".
  return ["api", "graphql", "-f", `query=${QUERY}`, "-f", `owner=${owner}`, "-f", `name=${name}`];
}

export function slug(repo) {
  return repo.replace("/", "__");
}

// One item as ingest.sql reads it. Values are passed through as GitHub sent them, so ingest
// can refuse a wrong type. The body becomes a character count; comments become the time of
// the owner's latest one.
export function item(kind, n) {
  const comments = (n.comments && Array.isArray(n.comments.nodes)) ? n.comments.nodes : [];
  const mine = comments.filter((c) => c && c.viewerDidAuthor === true && typeof c.createdAt === "string")
    .map((c) => c.createdAt).sort();
  return {
    number: n.number,
    title: n.title,
    url: n.url,
    createdAt: n.createdAt,
    updatedAt: n.updatedAt,
    isDraft: kind === "pr" && n.isDraft === true,
    authorAssociation: n.authorAssociation,
    // A deleted account comes back as null.
    author: n.author ? { login: n.author.login, type: n.author.__typename } : null,
    labels: (n.labels && Array.isArray(n.labels.nodes)) ? n.labels.nodes.map((l) => l && l.name) : [],
    assignees: kind === "issue" && n.assignees ? n.assignees.totalCount : 0,
    linkedPrs: kind === "issue" && n.closedByPullRequestsReferences ? n.closedByPullRequestsReferences.totalCount : 0,
    bodyChars: kind === "issue" && typeof n.body === "string" ? [...n.body.trim()].length : 0,
    comments: n.comments ? n.comments.totalCount : 0,
    ownerLastCommentAt: mine.length ? mine[mine.length - 1] : "",
  };
}

// A large query can time out on GitHub's side (HTTP 502, 503, 504). One retry covers that.
function gh(repo, args) {
  for (let attempt = 1; ; attempt++) {
    try {
      return JSON.parse(execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] }));
    } catch (err) {
      const msg = String(err.stderr || err.message || err).trim().split("\n")[0];
      if (attempt === 1 && /HTTP 50[234]/.test(msg)) continue;
      console.error(`gh read failed for ${repo}: ${msg}`);
      process.exit(1);
    }
  }
}

function main(argv) {
  const repo = argv[2];
  if (argv.length !== 3 || !REPO.test(repo || "")) {
    console.error("usage: node references/fetch.mjs <owner/repo>");
    process.exit(2);
  }
  const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "inbox", slug(repo));
  const res = gh(repo, reads(repo));
  const r = res && res.data && res.data.repository;
  const login = res && res.data && res.data.viewer && res.data.viewer.login;
  if (!r || typeof login !== "string" || typeof r.nameWithOwner !== "string" || r.nameWithOwner.toLowerCase() !== repo.toLowerCase()
      || !r.labels || !Array.isArray(r.labels.nodes) || !r.pullRequests || !Array.isArray(r.pullRequests.nodes)
      || !r.issues || !Array.isArray(r.issues.nodes)) {
    console.error(`gh read for ${repo} did not return a login, the same repository and the expected lists`);
    process.exit(1);
  }
  const issuesOn = r.hasIssuesEnabled !== false;
  const data = {
    user: { login },
    repo: { nameWithOwner: r.nameWithOwner },
    labels: r.labels.nodes.map((l) => l && l.name),
    prs: r.pullRequests.nodes.map((n) => item("pr", n)),
    issues: issuesOn ? r.issues.nodes.map((n) => item("issue", n)) : [],
  };
  mkdirSync(dir, { recursive: true });
  // Write then rename, so ingest never reads a half-written file.
  for (const [name, value] of Object.entries(data)) {
    const file = join(dir, `${name}.json`);
    writeFileSync(file + ".tmp", JSON.stringify(value));
    renameSync(file + ".tmp", file);
  }
  const summary = {
    repo, login, issues_enabled: issuesOn,
    labels: data.labels.length, labels_total: r.labels.totalCount,
    prs: data.prs.length, prs_total: r.pullRequests.totalCount,
    issues: data.issues.length, issues_total: issuesOn ? r.issues.totalCount : 0,
    limits: LIMITS,
    fetched_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  writeFileSync(join(dir, "fetch.json.tmp"), JSON.stringify(summary));
  renameSync(join(dir, "fetch.json.tmp"), join(dir, "fetch.json"));
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
