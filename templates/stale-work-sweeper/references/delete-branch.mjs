// Delete one merged branch, only if it still points at the commit the owner approved.
// Usage, from the workspace root (ask-approval builds this command; never write it yourself):
//   node references/delete-branch.mjs <owner/repo> <branch> <sha>
// GitHub checks the branch head and deletes it in one step (GraphQL updateRefs with beforeOid),
// so a commit pushed after the approval makes the delete fail and the branch stays.
// It runs fixed `gh` calls with no shell and prints a one-line JSON result.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// Same rules as fetch.mjs and ask-approval.sql.
const REPO = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,38}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/;
const SHA = /^[0-9a-f]{40}$/;

export function safeBranch(ref) {
  return (
    typeof ref === "string" &&
    ref.length >= 1 && ref.length <= 200 &&
    /^[A-Za-z0-9._/-]+$/.test(ref) &&
    !ref.includes("..") && !ref.includes("//") &&
    !/^[./-]/.test(ref) && !/\/[.-]/.test(ref) &&
    !ref.endsWith("/") && !ref.endsWith(".") && !ref.endsWith(".lock")
  );
}

export const REPO_ID_QUERY = `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id } }`;
export const DELETE_MUTATION = `mutation($repo: ID!, $ref: GitRefname!, $before: GitObjectID!) {
  updateRefs(input: {repositoryId: $repo, refUpdates: [{name: $ref, beforeOid: $before, afterOid: "0000000000000000000000000000000000000000", force: true}]}) { clientMutationId }
}`;

export function calls(repo, branch, sha, repoId) {
  const [owner, name] = repo.split("/");
  return {
    // -f (raw string), never -F: -F reads a local file for a value starting with "@".
    repoId: ["api", "graphql", "-f", `query=${REPO_ID_QUERY}`, "-f", `owner=${owner}`, "-f", `name=${name}`],
    remove: ["api", "graphql", "-f", `query=${DELETE_MUTATION}`, "-f", `repo=${repoId}`, "-f", `ref=refs/heads/${branch}`, "-f", `before=${sha}`],
  };
}

function gh(args) {
  try {
    return { ok: true, value: JSON.parse(execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })) };
  } catch (err) {
    const out = String(err.stdout || "");
    const msg = (out.match(/"message":"([^"]*)"/)?.[1] || String(err.stderr || err.message || err)).trim().split("\n")[0];
    return { ok: false, msg };
  }
}

function fail(message) {
  console.error(`branch not deleted: ${message}`);
  process.exit(1);
}

function main(argv) {
  const [repo, branch, sha] = argv.slice(2);
  if (argv.length !== 5 || !REPO.test(repo || "") || !safeBranch(branch) || !SHA.test(sha || "")) {
    console.error("usage: node references/delete-branch.mjs <owner/repo> <branch> <40-character sha>");
    process.exit(2);
  }
  const found = gh(calls(repo, branch, sha).repoId);
  const id = found.ok && found.value?.data?.repository?.id;
  if (typeof id !== "string" || !id) fail(found.ok ? `${repo} was not found` : found.msg);
  const removed = gh(calls(repo, branch, sha, id).remove);
  if (!removed.ok) {
    // GitHub reports a failed beforeOid check only as a generic error, so read the head to say why.
    const head = gh(["api", `repos/${repo}/git/ref/heads/${branch}`]);
    const now = head.ok && head.value?.object?.sha;
    if (typeof now === "string" && now !== sha) fail(`${branch} moved to ${now} after you approved ${sha}; fetch again and review it`);
    fail(removed.msg);
  }
  console.log(JSON.stringify({ deleted: true, repo, branch, sha }));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv);
