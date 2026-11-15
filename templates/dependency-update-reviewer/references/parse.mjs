// Deterministic parsing of Dependabot and Renovate pull requests, used by fetch.mjs.
// Input is GitHub data, so it is untrusted: every function takes plain strings and
// returns plain values, and nothing here runs or follows what the text says.

const BODY_SCAN = 60000;

// Dependabot branch: dependabot/<ecosystem>/...
const DEPENDABOT_ECOSYSTEMS = {
  npm_and_yarn: "npm", bun: "npm", pip: "pip", uv: "pip", go_modules: "go", cargo: "cargo",
  bundler: "rubygems", composer: "composer", maven: "maven", gradle: "gradle", nuget: "nuget",
  github_actions: "github-actions", docker: "docker", docker_compose: "docker", terraform: "terraform",
  pub: "pub", hex: "hex", elm: "elm", gitsubmodule: "git-submodule", swift: "swift", helm: "helm",
};

export function botOf(login) {
  if (login === "app/dependabot") return "dependabot";
  if (login === "app/renovate") return "renovate";
  return null;
}

const strip = (v) => String(v).replace(/^[`'"]+|[`'".,]+$/g, "");

function ecosystemFromBranch(branch) {
  const m = /^dependabot\/([a-z_]+)\//.exec(branch || "");
  return m ? DEPENDABOT_ECOSYSTEMS[m[1]] || m[1] : "unknown";
}

// Versions: "v1.2.3", "1.2", "0.4.34". Digests: 7 to 64 hex characters.
export function bumpType(from, to) {
  if (!from || !to) return "unknown";
  const hex = /^[0-9a-f]{7,64}$/i;
  if (hex.test(from) && hex.test(to) && !/^\d+$/.test(from)) return "digest";
  const nums = (v) => {
    const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?/.exec(v);
    return m ? [m[1], m[2] ?? "0", m[3] ?? "0"].map(Number) : null;
  };
  const a = nums(from);
  const b = nums(to);
  if (!a || !b) return "unknown";
  if (a[0] !== b[0]) return "major";
  if (a[1] !== b[1]) return "minor";
  if (a[2] !== b[2]) return "patch";
  return from === to ? "none" : "patch";
}

function dependabotUpdates(title, body, branch) {
  const ecosystem = ecosystemFromBranch(branch);
  const out = [];
  // Grouped: "Updates `name` from 1.0.0 to 2.0.0" (versions may be in backticks).
  for (const m of body.matchAll(/^Updates `([^`\n]+)` from `?([^\s`]+?)`? to `?([^\s`]+?)`?\.?\s*$/gm)) {
    out.push({ package: m[1], from: strip(m[2]), to: strip(m[3]) });
  }
  if (!out.length) {
    // Single: "Bumps [name](url) from A to B." or "Bumps name from A to B."
    const m = /^Bumps \[([^\]\n]+)\](?:\([^)\n]*\))? from `?([^\s`]+?)`? to `?([^\s`]+?)`?\.?\s*$/m.exec(body)
      || /^Bumps ([^\s[]+) from `?([^\s`]+?)`? to `?([^\s`]+?)`?\.?\s*$/m.exec(body)
      || /\bBump ([^\s]+) from ([^\s]+) to ([^\s]+)/.exec(title);
    if (m) out.push({ package: m[1], from: strip(m[2]), to: strip(m[3]) });
  }
  return out.map((u) => ({ ...u, ecosystem, bump: bumpType(u.from, u.to) }));
}

function renovateUpdates(title, body) {
  const out = [];
  for (const line of body.split("\n")) {
    if (!line.startsWith("|")) continue;
    const change = /`([^`\s]+)`\s*(?:→|->|➔)\s*`([^`\s]+)`/.exec(line);
    if (!change) continue;
    const cells = line.split("|").map((c) => c.trim());
    const first = cells[1] || "";
    const name = (/^\[([^\]]+)\]/.exec(first) || [null, first.split(/\s+/)[0]])[1];
    const ds = /\/badges\/(?:age|confidence)\/([a-z0-9-]+)\//i.exec(line) || /renovatebot\.com\/diffs\/([a-z0-9-]+)\//i.exec(line);
    if (name) out.push({ package: name, from: change[1], to: change[2], ecosystem: ds ? ds[1].toLowerCase() : "unknown" });
  }
  if (!out.length) {
    // Title only gives the target: "Update dependency x to v2.1.0" or "update x docker tag to v3".
    const m = /\bupdate (?:dependency |module )?(\S+?)(?: docker tag| action)? to v?([0-9][^\s()]*)/i.exec(title);
    if (m) out.push({ package: m[1], from: "", to: m[2], ecosystem: "unknown" });
  }
  return out.map((u) => ({ ...u, bump: bumpType(u.from, u.to) }));
}

// The part of the body with release notes and changelogs, without the bots' own
// help text (Dependabot's command list, Renovate's configuration section).
export function notesOf(body) {
  let text = body.slice(0, BODY_SCAN);
  for (const marker of ["<summary>Dependabot commands and options</summary>", "### Configuration", "Dependabot will resolve any conflicts"]) {
    const at = text.indexOf(marker);
    if (at >= 0) text = text.slice(0, at);
  }
  return text;
}

// One entry per package and version change, however many files a bot changed.
function dedupe(updates) {
  const seen = new Set();
  return updates.filter((u) => {
    const k = [u.package, u.from, u.to].join("\u0000");
    return seen.has(k) ? false : (seen.add(k), true);
  });
}

// Signals a reviewer should look at. Only names, never text from the PR.
export function signalsOf(title, body, updates) {
  const text = notesOf(body);
  const s = new Set();
  if (updates.some((u) => u.bump === "major")) s.add("major-bump");
  if (updates.some((u) => u.bump === "minor" && /^v?0\./.test(u.from))) s.add("zero-major-minor");
  if (updates.some((u) => u.bump === "unknown")) s.add("version-unknown");
  if (!updates.length) s.add("no-update-parsed");
  if (new Set(updates.map((u) => u.package)).size > 1) s.add("grouped");
  if (/\bBREAKING\b|breaking change/i.test(text)) s.add("breaking-note");
  if (/\b(?:removed?|drop(?:ped|s)? support)\b/i.test(text)) s.add("removal-note");
  if (/\bdeprecat/i.test(text)) s.add("deprecation-note");
  if (/\b(?:requires?|minimum(?: supported)?|engines?)\b[^\n]{0,40}\b(?:node(?:\.js)?|python|go|java|ruby|php|rust|\.net)\b\s*v?\d/i.test(text)) s.add("runtime-floor-note");
  if (/\[security\]/i.test(title) || /security (?:update|fix|advisory)|\bCVE-\d{4}-\d+/i.test(text)) s.add("security");
  return [...s].sort();
}

// The few release-note lines behind the note signals, so a reviewer can check them
// without reading the whole PR body. At most 8 lines of 200 characters, links replaced.
// This is the only PR body text the model sees.
const NOTE_LINE = /\bBREAKING\b|breaking change|\b(?:removed?|drop(?:ped|s)? support)\b|\bdeprecat|\b(?:requires?|minimum(?: supported)?|engines?)\b[^\n]{0,40}\b(?:node(?:\.js)?|python|go|java|ruby|php|rust|\.net)\b\s*v?\d|security (?:update|fix|advisory)|\bCVE-\d{4}-\d+/i;
export function evidenceOf(body) {
  const out = [];
  for (const raw of notesOf(body).split("\n")) {
    if (out.length >= 8) break;
    if (!NOTE_LINE.test(raw)) continue;
    const line = raw.replace(/https?:\/\/\S+/g, "<link>").replace(/<[^>]{1,200}>/g, (t) => (t === "<link>" ? t : "")).replace(/\s+/g, " ").trim();
    if (line) out.push(line.slice(0, 200));
  }
  return out;
}

const FAILED = /^(FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE|STALE)$/;
const PASSED = /^(SUCCESS|NEUTRAL|SKIPPED)$/;

export function ciOf(rollup) {
  const checks = Array.isArray(rollup) ? rollup : [];
  if (!checks.length) return { state: "none", failing: [] };
  const failing = [];
  let pending = false;
  for (const c of checks) {
    const result = String(c.conclusion || c.state || "").toUpperCase();
    const done = c.__typename === "StatusContext" ? result && result !== "PENDING" && result !== "EXPECTED" : String(c.status || "").toUpperCase() === "COMPLETED";
    if (!done) { pending = true; continue; }
    if (FAILED.test(result)) failing.push(String(c.name || c.context || "check").slice(0, 120));
    else if (!PASSED.test(result)) pending = true;
  }
  const names = [...new Set(failing)].sort().slice(0, 10);
  return { state: names.length ? "failing" : pending ? "pending" : "passing", failing: names };
}

// One PR from `gh pr list --json ...` to the row ingest.sql reads.
export function parsePr(pr) {
  const bot = botOf(pr?.author?.login);
  const title = String(pr.title || "");
  const body = String(pr.body || "");
  const updates = dedupe(bot === "dependabot" ? dependabotUpdates(title, body, pr.headRefName)
    : bot === "renovate" ? renovateUpdates(title, body) : []);
  const ci = ciOf(pr.statusCheckRollup);
  return {
    number: pr.number,
    title,
    bot,
    url: pr.url || "",
    isDraft: !!pr.isDraft,
    createdAt: pr.createdAt || "",
    updatedAt: pr.updatedAt,
    headRefOid: pr.headRefOid || "",
    headRefName: pr.headRefName || "",
    labels: (pr.labels || []).map((l) => l.name),
    updates: updates.slice(0, 50).map((u) => ({ ...u, package: String(u.package).slice(0, 200) })),
    signals: signalsOf(title, body, updates),
    ci: ci.state,
    failingChecks: ci.failing,
    evidence: evidenceOf(body),
  };
}
