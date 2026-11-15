// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs two fixed `gh pr list` reads with no shell (open PRs by Dependabot and by
// Renovate), parses each PR with parse.mjs, writes inbox/<owner>__<repo>/prs.json and
// fetch.json, and prints a one-line JSON summary. It never writes to GitHub.
// The command is the same on every run for a repository, so the owner can approve it once
// with "Always allow here". ingest.sql reads the files it writes.
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parsePr } from "./parse.mjs";

export const LIMIT = 30;
export const BOTS = ["app/dependabot", "app/renovate"];
const FIELDS = "number,title,author,isDraft,labels,createdAt,updatedAt,url,body,headRefOid,headRefName,statusCheckRollup";
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;

export function reads(repo) {
  return BOTS.map((author) => [
    "pr", "list", "--repo", repo, "--state", "open", "--author", author,
    "--limit", String(LIMIT), "--json", FIELDS,
  ]);
}

export function slug(repo) {
  return repo.replace("/", "__");
}

// A large PR list with check results can time out on GitHub's side (HTTP 502, 503, 504).
// One retry covers that; anything else fails the fetch.
function gh(args) {
  for (let attempt = 1; ; attempt++) {
    try {
      return execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      const msg = String(err.stderr || err.message || err).trim().split("\n")[0];
      if (attempt === 1 && /HTTP 50[234]/.test(msg)) continue;
      throw new Error(msg);
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
  mkdirSync(dir, { recursive: true });
  const counts = {};
  const prs = [];
  for (const args of reads(repo)) {
    const author = args[args.indexOf("--author") + 1];
    let data;
    try {
      data = JSON.parse(gh(args));
    } catch (err) {
      console.error(`gh pr list (${author}) failed for ${repo}: ${err.message}`);
      process.exit(1);
    }
    if (!Array.isArray(data)) {
      console.error(`gh pr list (${author}) for ${repo} did not return a list`);
      process.exit(1);
    }
    counts[author.replace("app/", "")] = data.length;
    for (const pr of data) prs.push(parsePr(pr));
  }
  const file = join(dir, "prs.json");
  // Write then rename, so ingest never reads a half-written file.
  writeFileSync(file + ".tmp", JSON.stringify(prs));
  renameSync(file + ".tmp", file);
  const summary = { repo, ...counts, limit: LIMIT, fetched_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z") };
  writeFileSync(join(dir, "fetch.json"), JSON.stringify(summary));
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
