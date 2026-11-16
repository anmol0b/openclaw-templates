// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs fixed `gh` reads with no shell: the owner's login, the repository name, open PRs,
// collaborators with push access (when the login may read them) and the CODEOWNERS file.
// It keeps only the fields the steps need, writes inbox/<owner>__<repo>/prs.json,
// candidates.json and fetch.json, and prints a one-line JSON summary. It never writes to GitHub.
// The command is the same on every run for a repository, so the owner can approve it once
// with "Always allow here". ingest.sql reads the files it writes.
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// 30 PRs: with commits, comments and reviews, a page of 50 exceeds GitHub's 500,000-node GraphQL limit.
export const LIMITS = { prs: 30, collaborators: 100, title: 300 };
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;
// A GitHub user login: letters, digits and inner dashes, 1 to 39 characters. Teams (org/team)
// and bots (name[bot]) never match, so neither can become a reviewer candidate.
export const LOGIN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/;
// GitHub looks for CODEOWNERS in this order and uses the first one it finds.
export const CODEOWNERS_PATHS = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"];
// Reviews from these associations count as a maintainer review. A review by an outside
// account or a review bot (CONTRIBUTOR, NONE) does not end the wait for a review.
const MAINTAINER = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);
const PR_FIELDS = "number,title,author,isDraft,reviewDecision,reviewRequests,latestReviews,mergeable,createdAt,updatedAt,headRefOid,url,comments,commits";

export function reads(repo) {
  return {
    user: ["api", "user"],
    repo: ["repo", "view", repo, "--json", "nameWithOwner"],
    prs: ["pr", "list", "--repo", repo, "--state", "open", "--limit", String(LIMITS.prs), "--json", PR_FIELDS],
    collaborators: ["api", `repos/${repo}/collaborators?per_page=${LIMITS.collaborators}&affiliation=all`],
    codeowners: CODEOWNERS_PATHS.map((p) => ["api", "-H", "Accept: application/vnd.github.raw+json", `repos/${repo}/contents/${p}`]),
  };
}

export function slug(repo) {
  return repo.replace("/", "__");
}

const login = (x) => (x && typeof x.login === "string" ? x.login : "");
const valid = (l) => LOGIN.test(l);
const maxTime = (list) => list.filter((t) => typeof t === "string").sort().at(-1) ?? null;

// One PR, reduced to the fields the steps need. Bodies of the PR, its comments and its reviews
// are dropped here and never written: only logins, states, counts and times remain.
export function reducePr(pr, owner) {
  const comments = Array.isArray(pr.comments) ? pr.comments : [];
  const mine = comments.filter((c) => login(c.author).toLowerCase() === owner.toLowerCase());
  const requests = Array.isArray(pr.reviewRequests) ? pr.reviewRequests : [];
  return {
    number: pr.number,
    title: typeof pr.title === "string" ? pr.title.slice(0, LIMITS.title) : "",
    url: typeof pr.url === "string" ? pr.url : "",
    author: login(pr.author).slice(0, 60),
    author_is_bot: Boolean(pr.author && pr.author.is_bot),
    is_draft: Boolean(pr.isDraft),
    review_decision: typeof pr.reviewDecision === "string" ? pr.reviewDecision : "",
    mergeable: typeof pr.mergeable === "string" ? pr.mergeable : "",
    created_at: pr.createdAt,
    updated_at: pr.updatedAt,
    head_sha: pr.headRefOid,
    last_commit_at: maxTime((Array.isArray(pr.commits) ? pr.commits : []).map((c) => c.committedDate)),
    requested_users: requests.filter((r) => r.__typename !== "Team").map(login).filter(valid),
    requested_teams: requests.filter((r) => r.__typename === "Team").length,
    reviews: (Array.isArray(pr.latestReviews) ? pr.latestReviews : [])
      .filter((r) => valid(login(r.author)))
      .map((r) => ({ login: login(r.author), maintainer: MAINTAINER.has(r.authorAssociation), state: r.state, submitted_at: r.submittedAt })),
    comments: comments.length,
    owner_comments: mine.length,
    owner_last_comment_at: maxTime(mine.map((c) => c.createdAt)),
  };
}

// User logins named in a CODEOWNERS file. Team owners (@org/team) and email owners are skipped.
export function codeownerLogins(text) {
  const out = new Set();
  for (const line of String(text).split("\n")) {
    const body = line.replace(/#.*/, "").trim().split(/\s+/).slice(1);
    for (const tok of body) if (tok.startsWith("@") && valid(tok.slice(1))) out.add(tok.slice(1));
  }
  return [...out];
}

// Collaborators who can push: only these can be asked for a review that counts.
export function collaboratorLogins(list) {
  return (Array.isArray(list) ? list : [])
    .filter((c) => c && c.type === "User" && c.permissions && c.permissions.push === true && valid(login(c)))
    .map(login);
}

class NotFound extends Error {}

// A large PR list can time out on GitHub's side (HTTP 502, 503, 504). One retry covers that.
// HTTP 403 and 404 are reported to the caller, which decides whether that read is optional.
function gh(args) {
  for (let attempt = 1; ; attempt++) {
    try {
      return execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      const msg = String(err.stderr || err.message || err).trim().split("\n").at(-1);
      if (attempt === 1 && /HTTP 50[234]/.test(msg)) continue;
      if (/HTTP 40[34]/.test(msg)) throw new NotFound(msg);
      throw new Error(msg);
    }
  }
}

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function readJson(name, repo, args) {
  try {
    return JSON.parse(gh(args));
  } catch (err) {
    fail(`gh ${name} read failed for ${repo}: ${err.message}`);
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
  const r = reads(repo);
  const owner = login(readJson("user", repo, r.user));
  const info = readJson("repo", repo, r.repo);
  if (!valid(owner) || !info || String(info.nameWithOwner).toLowerCase() !== repo.toLowerCase()) {
    fail(`gh read for ${repo} did not return a login and the same repository`);
  }
  const rawPrs = readJson("prs", repo, r.prs);
  if (!Array.isArray(rawPrs)) fail(`gh pr list for ${repo} did not return a list`);

  // Collaborators need push access to read. Without it, candidates come from CODEOWNERS and reviews.
  let collaborators = [];
  let collaboratorsReadable = true;
  let collaboratorsRaw = 0;
  try {
    const list = JSON.parse(gh(r.collaborators));
    collaboratorsRaw = Array.isArray(list) ? list.length : 0;
    collaborators = collaboratorLogins(list);
  } catch (err) {
    if (!(err instanceof NotFound)) fail(`gh collaborators read failed for ${repo}: ${err.message}`);
    collaboratorsReadable = false;
  }

  let codeownersPath = "";
  let codeowners = [];
  for (const [i, args] of r.codeowners.entries()) {
    try {
      codeowners = codeownerLogins(gh(args).slice(0, 65536));
      codeownersPath = CODEOWNERS_PATHS[i];
      break;
    } catch (err) {
      if (!(err instanceof NotFound)) fail(`gh CODEOWNERS read failed for ${repo}: ${err.message}`);
    }
  }

  const prs = rawPrs.map((pr) => reducePr(pr, owner));
  const reviewers = new Set(prs.flatMap((p) => p.reviews.filter((x) => x.maintainer).map((x) => x.login)));
  const candidates = [
    ...collaborators.map((l) => ({ login: l, source: "collaborator" })),
    ...codeowners.map((l) => ({ login: l, source: "codeowner" })),
    ...[...reviewers].map((l) => ({ login: l, source: "reviewer" })),
  ];
  // Write then rename, so ingest never reads a half-written file.
  for (const [name, value] of [["prs", prs], ["candidates", candidates]]) {
    const file = join(dir, `${name}.json`);
    writeFileSync(file + ".tmp", JSON.stringify(value));
    renameSync(file + ".tmp", file);
  }
  const summary = {
    repo, login: owner, prs: prs.length, collaborators_readable: collaboratorsReadable,
    collaborators_cut: collaboratorsRaw >= LIMITS.collaborators, codeowners_path: codeownersPath,
    candidates: candidates.length, limits: { prs: LIMITS.prs, collaborators: LIMITS.collaborators },
    fetched_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  writeFileSync(join(dir, "fetch.json"), JSON.stringify(summary));
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
