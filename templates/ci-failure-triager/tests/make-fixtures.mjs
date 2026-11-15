// Rebuilds tests/fixtures/example. Usage: node tests/make-fixtures.mjs <package dir>
// The runs, jobs and log files keep the exact shape of real `gh run list --json`, `gh run view --json jobs`
// and `gh run view --log-failed` output (gh 2.102), with made-up names, commits and log text.
// failures.json is made by fetch.mjs's own summarize(), so it matches what fetch writes.
//
// Scenario (workflow / branch):
//   CI / main        1001 pass (a) -> 1002 fail (b, new break) -> 1003 fail (c, still broken) -> 1004 pass (d)
//   CI / feature-x   2001 attempt 1 fails on PR #42 (e); the tests later show attempt 2 passing: flaky
//   Nightly / main   3001 times out (f), no pass in the history: unclear
//   Docs / main      20 passing runs as filler
import fs from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const pkg = resolve(process.argv[2] || ".");
const { summarize } = await import(pathToFileURL(join(pkg, "references", "fetch.mjs")).href);
const O = join(pkg, "tests", "fixtures", "example");
fs.mkdirSync(join(O, "gh"), { recursive: true });

const base = Date.parse("2026-11-10T08:00:00Z");
const iso = (m) => new Date(base + m * 60e3).toISOString().replace(/\.\d{3}Z$/, "Z");
// A log line time like GitHub's: seven fractional digits.
const stamp = (m, k) => new Date(base + m * 60e3).toISOString().replace(/\.\d{3}Z$/, `.${String(1234560 + k)}Z`);
const sha = (c) => c.repeat(40).slice(0, 40);
const run = (id, attempt, wf, branch, event, s, concl, m, title) => ({
  attempt, conclusion: concl, createdAt: iso(m), databaseId: id, displayTitle: title, event, headBranch: branch,
  headSha: sha(s), name: wf, number: id - 1000, status: "completed", updatedAt: iso(m + 6),
  url: `https://github.com/example-org/example-repo/actions/runs/${id}`, workflowName: wf,
});
const runs = [
  run(1001, 1, "CI", "main", "push", "a", "success", 0, "Merge pull request #40"),
  run(1002, 1, "CI", "main", "push", "b", "failure", 60, "Bump parser to 3.0"),
  run(2001, 1, "CI", "feature-x", "pull_request", "e", "failure", 70, "Add export option"),
  run(1003, 1, "CI", "main", "push", "c", "failure", 120, "Update docs"),
  run(3001, 1, "Nightly", "main", "schedule", "f", "timed_out", 150, "Nightly"),
  run(1004, 1, "CI", "main", "push", "d", "success", 180, "Fix parser import"),
];
for (let k = 0; k < 20; k++) runs.push(run(4000 + k, 1, "Docs", "main", "push", "9", "success", 5 + k, "Docs build"));
runs.sort((x, y) => y.createdAt.localeCompare(x.createdAt));

const step = (n, name, concl) => ({ completedAt: iso(1), conclusion: concl, name, number: n, startedAt: iso(0), status: "completed" });
const job = (id, name, concl, steps) => ({
  completedAt: iso(1), conclusion: concl, databaseId: id, name, startedAt: iso(0), status: "completed", steps,
  url: `https://github.com/example-org/example-repo/actions/runs/1/job/${id}`,
});
const BOM = "﻿";
const E = "\u001b[31m";
const R = "\u001b[0m";
const log = (jobName, m, lines) => lines.map((l, k) => `${k ? "" : BOM}${jobName}\tUNKNOWN STEP\t${stamp(m, k)} ${l}`).join("\n") + "\n";
// gh prints control characters in caret form (^[) when its output is a pipe, so real logs carry both shapes.
const C = "^[[1m^[[31m";
const testLog = (seed, m) => log("test (ubuntu-latest)", m, [
  "##[group]Run make test", "##[debug]Added matchers: 'go'. Problem matchers scan action output for known warning or error strings.",
  "^[[1m^[[33mwarning^[[0m: Cargo.toml: `panic` setting is ignored for `bench` profile",
  "go test ./...", `ok   example/cli  0.${seed}12s`,
  `${E}--- FAIL: TestParseConfig (0.0${seed}s)${R}`, `${C}FAIL^[[0m: parser suite`, `    config_test.go:${40 + seed}: unexpected token at line 3`,
  `FAIL example/parser 0.${seed}31s`, "##[error]Process completed with exit code 1.", "Cleaning up orphan processes",
]);
const jobsTest = (id) => ({ jobs: [
  job(id, "test (ubuntu-latest)", "failure", [step(1, "Set up job", "success"), step(4, "Run make test", "failure")]),
  job(id + 1, "lint", "success", [step(1, "Set up job", "success")]),
] });
const gh = {
  1002: [jobsTest(5101), testLog(1, 60)],
  1003: [jobsTest(5201), testLog(2, 120)],
  2001: [{ jobs: [job(5301, "lint", "failure", [step(3, "Run golangci-lint", "failure")])] },
    log("lint", 70, ["Run golangci-lint", "main.go:12: error: unused variable count", "##[error]Process completed with exit code 2."])],
  3001: [{ jobs: [job(9001, "e2e", "cancelled", []), job(9002, "e2e (macos)", "timed_out", [step(5, "Run e2e", "timed_out")])] },
    log("e2e (macos)", 150, ["Waiting for server on :8080", "##[error]The job running on runner example-runner has exceeded the maximum execution time of 60 minutes."])],
};
const failures = [];
for (const [id, [jobs, text]] of Object.entries(gh)) {
  const r = runs.find((x) => x.databaseId === Number(id));
  fs.writeFileSync(join(O, "gh", `jobs-${id}.json`), JSON.stringify(jobs));
  fs.writeFileSync(join(O, "gh", `log-${id}.txt`), text);
  for (const j of summarize(r, jobs, text)) failures.push({ ...j, log_error: "" });
}
const prs = [{ headRefOid: sha("e"), number: 42, url: "https://github.com/example-org/example-repo/pull/42" }];
fs.writeFileSync(join(O, "runs.json"), JSON.stringify(runs, null, 1));
fs.writeFileSync(join(O, "prs.json"), JSON.stringify(prs, null, 1));
fs.writeFileSync(join(O, "failures.json"), JSON.stringify(failures, null, 1));
for (const f of failures) console.log(f.run_id, f.job_name, f.signature, JSON.stringify(f.error_lines));
