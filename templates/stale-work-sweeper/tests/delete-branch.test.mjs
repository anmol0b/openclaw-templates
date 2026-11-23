// delete-branch.mjs deletes a branch only through updateRefs with the approved SHA as beforeOid,
// and reports a branch that moved after the approval. A stand-in `gh` on PATH records every call.
// Usage: node tests/delete-branch.test.mjs <package dir>
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const pkg = resolve(process.argv[2] || ".");
let passes = 0;
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (cond) { passes++; console.log("PASS " + name); } else { fails++; console.log("FAIL " + name + " " + extra); }
};

const APPROVED = "a".repeat(40);
const MOVED = "b".repeat(40);
const scratch = mkdtempSync(join(tmpdir(), "sws-delete."));
try {
  const log = join(scratch, "gh-calls.jsonl");
  // The stand-in gh: the mutation fails unless the branch head (GH_HEAD) equals beforeOid, like GitHub.
  writeFileSync(join(scratch, "gh"), `#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + "\\n");
const v = (k) => (a.find((x) => x.startsWith(k + "=")) || "").slice(k.length + 1);
const out = (o) => process.stdout.write(JSON.stringify(o));
if (a[1] === "graphql" && v("query").startsWith("query")) out({ data: { repository: { id: "R_example" } } });
else if (a[1] === "graphql" && v("query").startsWith("mutation")) {
  if (v("before") === process.env.GH_HEAD) out({ data: { updateRefs: { clientMutationId: null } } });
  else { out({ errors: [{ message: "Something went wrong while executing your query." }] }); process.exit(1); }
} else if (a[1].startsWith("repos/")) out({ object: { sha: process.env.GH_HEAD } });
else { process.stderr.write("unexpected gh call\\n"); process.exit(3); }
`);
  chmodSync(join(scratch, "gh"), 0o755);
  const run = (args, head) => {
    writeFileSync(log, "");
    const r = spawnSync("node", [join(pkg, "references", "delete-branch.mjs"), ...args], {
      encoding: "utf8", env: { ...process.env, PATH: scratch + ":" + process.env.PATH, GH_HEAD: head },
    });
    const calls = readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
    return { ...r, calls };
  };

  let r = run(["example-org/example-repo", "feature/merged-old", APPROVED], APPROVED);
  ok("deletes a branch still at the approved SHA", r.status === 0 && r.stdout.includes('"deleted":true'), r.stderr);
  const mutation = r.calls.find((c) => c.some((x) => x.startsWith("query=mutation")));
  ok("the delete is updateRefs bound to the approved SHA",
    mutation && mutation.some((x) => x.includes("beforeOid: $before")) && mutation.includes("before=" + APPROVED)
      && mutation.includes("ref=refs/heads/feature/merged-old") && mutation.includes("repo=R_example"));
  ok("never uses the unconditional REST delete", !r.calls.flat().some((x) => /^(-X|--method|DELETE)$/.test(x)));

  r = run(["example-org/example-repo", "feature/merged-old", APPROVED], MOVED);
  ok("refuses a branch that moved after the approval", r.status === 1 && r.stderr.includes(`moved to ${MOVED}`), r.stderr);
  ok("a moved branch reports no deletion", !r.stdout.includes("deleted"));

  for (const [args, why] of [
    [["example-org/example-repo", "feature/x", "abc"], "a short SHA"],
    [["example-org/example-repo", "-x", APPROVED], "a branch that reads as a flag"],
    [["example-org/example-repo", "a..b", APPROVED], "a branch with .."],
    [["example-org/example-repo", "x;rm", APPROVED], "a branch with shell characters"],
    [["-R", "feature/x", APPROVED], "a repository that reads as a flag"],
    [["example-org/example-repo", "feature/x"], "missing SHA"],
  ]) {
    r = run(args, APPROVED);
    ok("refuses " + why + " without calling gh", r.status === 2 && r.calls.length === 0);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log(`${passes} passed, ${fails} failed`);
process.exit(fails ? 1 : 0);
