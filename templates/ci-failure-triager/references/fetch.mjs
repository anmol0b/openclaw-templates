// Read-only fetch for one repository. Usage, from the workspace root:
//   node references/fetch.mjs <owner/repo>
// It runs fixed `gh` reads with no shell and writes their output to inbox/<owner>__<repo>/:
//   runs.json      the 100 newest workflow runs (any result)
//   prs.json       the 100 newest open pull requests (to find the PR a failing commit belongs to)
//   failures.json  one entry per failed job of a failed run still in runs.json
// For each failed run not fetched before, it reads the run's jobs and its failed-step log,
// at most LIMITS.newLogs runs per call. Each failed job keeps only its first error lines and an
// excerpt around the first error, with ANSI codes and timestamps removed, secret-looking strings
// masked, and fixed line and character caps. The full log is never kept. Log text is untrusted.
// It never writes to GitHub. The command is the same on every run for a repository, so the
// owner can approve it once with "Always allow here". ingest.sql reads the files it writes.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LIMITS = {
  runs: 100, prs: 100, newLogs: 10,
  // Per failed job: error lines and an excerpt of the log around the first error.
  errorLines: 5, lineChars: 200, excerptBefore: 5, excerptLines: 20, excerptChars: 3000,
  // Names from the repository (job, step, workflow, branch) and run titles.
  nameChars: 100, titleChars: 120,
};
export const FAILED = new Set(["failure", "timed_out", "startup_failure"]);
// Owner and name start with a letter, digit or underscore, so neither can read as a flag.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;
const RUN_FIELDS = "attempt,conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,name,number,status,updatedAt,url,workflowName";

export function listReads(repo) {
  return {
    runs: ["run", "list", "--repo", repo, "--limit", String(LIMITS.runs), "--json", RUN_FIELDS],
    // Only what matches a failing commit to its PR: no titles or bodies.
    prs: ["pr", "list", "--repo", repo, "--state", "open", "--limit", String(LIMITS.prs), "--json", "number,headRefOid,url"],
  };
}

export function runReads(repo, id, attempt) {
  return {
    jobs: ["run", "view", String(id), "--repo", repo, "--attempt", String(attempt), "--json", "jobs"],
    log: ["run", "view", String(id), "--repo", repo, "--attempt", String(attempt), "--log-failed"],
  };
}

export function slug(repo) {
  return repo.replace("/", "__");
}

// Color codes as raw ESC bytes, and as the caret form `^[[1m` that gh prints when its output goes to a pipe.
const ANSI = /(\u001b|\^\[)\[[0-9;?]*[ -/]*[@-~]/g;
const STAMP = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z ?/;
const ERRORISH = /##\[error\]|\b(error|errors|fail|failed|failure|fatal|panic|exception|assertion|traceback|segmentation fault)\b/i;
// Lines that mention errors without being one: runner markers, warnings, success summaries, and
// action inputs echoed at the start of a step (`fail-on-cache-miss: false`, `continue-on-error: true`).
const NOISE = /##\[(warning|notice|group|endgroup|debug|start-action|end-action)|^\s*$|^\s*warning\b|\b(0 failed|no errors?|errors?: 0)\b|deprecationwarning|^deprecation:|\b(fail|continue)[-_]on[-_][a-z-]*:/i;

// Strings that look like credentials are masked before anything is kept: GitHub, AWS, Slack and
// npm token shapes, bearer and basic auth headers, and key=value pairs whose key names a secret.
const SECRETS = [
  /\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abpors]-[A-Za-z0-9-]{10,}|npm_[A-Za-z0-9]{30,})\b/g,
  /\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{12,}/gi,
  /\b([A-Za-z0-9_]*(token|secret|password|passwd|api[_-]?key)[A-Za-z0-9_]*)\s*[=:]\s*['"]?[^\s'"]{6,}/gi,
];
export function mask(text) {
  return SECRETS.reduce((t, re) => t.replace(re, (m, a) => (re === SECRETS[2] ? `${a}=<masked>` : "<masked>")), text);
}

// One clean line: no ANSI, no BOM, no control characters, no leading timestamp, secrets masked, capped.
export function clean(line, cap = LIMITS.lineChars) {
  return mask(line.replace(/^\uFEFF/, "").replace(ANSI, "").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "").replace(STAMP, "")).slice(0, cap);
}

// The comparable form of an error line: run-specific details (hashes, numbers, temp paths,
// durations) are replaced, so the same failure on another run gives the same text.
export function normalize(line) {
  return line
    .toLowerCase()
    .replace(/##\[error\]/g, "")
    .replace(/\b[0-9a-f]{7,64}\b/g, "<hex>")
    .replace(/\/(tmp|var|private|home|users|runner)\/[^\s:'"]*/g, "<path>")
    .replace(/\d+(\.\d+)?(ms|s|m)\b/g, "<time>")
    .replace(/\d+/g, "<n>")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
}

export function signature(workflow, job, lines) {
  return createHash("sha256").update([workflow, job, ...lines].join("\n")).digest("hex").slice(0, 16);
}

// Turn one run's jobs JSON and --log-failed text into failed-job entries.
export function summarize(run, jobsDoc, logText) {
  const byJob = new Map();
  for (const raw of String(logText || "").split("\n")) {
    const parts = raw.split("\t");
    if (parts.length < 3) continue;
    const job = clean(parts[0], LIMITS.nameChars);
    const text = clean(parts.slice(2).join("\t"));
    if (!byJob.has(job)) byJob.set(job, []);
    byJob.get(job).push(text);
  }
  const jobs = (jobsDoc && Array.isArray(jobsDoc.jobs) ? jobsDoc.jobs : []).filter((j) => FAILED.has(j.conclusion));
  return jobs.map((j) => {
    const name = clean(String(j.name || ""), LIMITS.nameChars);
    const lines = byJob.get(name) || [];
    const isError = (l) => ERRORISH.test(l) && !NOISE.test(l);
    const errors = [...new Set(lines.filter(isError))].slice(0, LIMITS.errorLines);
    const failedSteps = (j.steps || []).filter((s) => FAILED.has(s.conclusion)).map((s) => clean(String(s.name || ""), LIMITS.nameChars));
    const basis = errors.length ? errors.map(normalize) : failedSteps.map(normalize);
    // The excerpt: a few lines before the first error and the lines after it, or the last lines
    // when no error line was found. Noise lines (debug, groups, warnings) are left out.
    const kept = lines.filter((l) => !NOISE.test(l));
    const first = kept.findIndex(isError);
    const from = first < 0 ? Math.max(0, kept.length - LIMITS.excerptLines) : Math.max(0, first - LIMITS.excerptBefore);
    let excerpt = kept.slice(from, from + LIMITS.excerptLines).join("\n");
    if (excerpt.length > LIMITS.excerptChars) excerpt = excerpt.slice(0, LIMITS.excerptChars);
    return {
      run_id: run.databaseId,
      attempt: run.attempt,
      job_id: j.databaseId,
      job_name: name,
      job_url: String(j.url || ""),
      failed_steps: failedSteps,
      error_lines: errors,
      excerpt,
      log_found: lines.length > 0,
      signature: signature(clean(String(run.workflowName || ""), LIMITS.nameChars), name, basis),
    };
  });
}

function gh(args) {
  return execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
}

function writeAtomic(file, data) {
  writeFileSync(file + ".tmp", JSON.stringify(data));
  renameSync(file + ".tmp", file);
}

function main(argv) {
  const repo = argv[2];
  if (argv.length !== 3 || !REPO.test(repo || "")) {
    console.error("usage: node references/fetch.mjs <owner/repo>");
    process.exit(2);
  }
  const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "inbox", slug(repo));
  const cache = join(dir, "logs");
  mkdirSync(cache, { recursive: true });
  const read = (name, args) => {
    try {
      const data = JSON.parse(gh(args));
      if (!Array.isArray(data)) throw new Error("did not return a list");
      return data;
    } catch (err) {
      const msg = String(err.stderr || err.message || err).trim().split("\n")[0];
      console.error(`gh ${name} read failed for ${repo}: ${msg}`);
      process.exit(1);
    }
  };
  const lists = listReads(repo);
  const runs = read("runs", lists.runs);
  const prs = read("prs", lists.prs);

  // Failed runs, newest first. Each run attempt's log is read once and cached.
  const failed = runs.filter((r) => r.status === "completed" && FAILED.has(r.conclusion));
  let fetched = 0;
  let skipped = 0;
  const logErrors = [];
  for (const run of failed) {
    const file = join(cache, `${run.databaseId}-${run.attempt}.json`);
    if (existsSync(file)) continue;
    if (fetched >= LIMITS.newLogs) { skipped++; continue; }
    fetched++;
    const r = runReads(repo, run.databaseId, run.attempt);
    let jobsDoc;
    let log = "";
    let logError = "";
    try {
      jobsDoc = JSON.parse(gh(r.jobs));
    } catch (err) {
      logErrors.push(`run ${run.databaseId}: jobs read failed: ${String(err.stderr || err.message).trim().split("\n")[0]}`);
      continue;
    }
    try {
      log = gh(r.log);
    } catch (err) {
      // An expired or missing log still leaves the failed jobs and steps.
      logError = String(err.stderr || err.message).trim().split("\n")[0].slice(0, 300);
    }
    writeAtomic(file, { run_id: run.databaseId, attempt: run.attempt, log_error: logError, jobs: summarize(run, jobsDoc, log) });
  }

  // failures.json: every cached entry for a failed run still in the list.
  const keep = new Set(failed.map((r) => `${r.databaseId}-${r.attempt}.json`));
  const failures = [];
  for (const name of readdirSync(cache).filter((n) => keep.has(n))) {
    const entry = JSON.parse(readFileSync(join(cache, name), "utf8"));
    for (const j of entry.jobs) failures.push({ ...j, log_error: entry.log_error });
  }
  writeAtomic(join(dir, "runs.json"), runs);
  writeAtomic(join(dir, "prs.json"), prs);
  writeAtomic(join(dir, "failures.json"), failures);
  const summary = {
    repo,
    runs: runs.length,
    prs: prs.length,
    failed_runs: failed.length,
    logs_fetched: fetched,
    logs_left_for_next_fetch: skipped,
    failed_jobs: failures.length,
    errors: logErrors,
    limits: LIMITS,
    fetched_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  writeFileSync(join(dir, "fetch.json"), JSON.stringify(summary));
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
