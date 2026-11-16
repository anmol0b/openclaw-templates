#!/usr/bin/env node
// Stand-in for `gh` in the tests. Serves files from $FAKE_GH_DIR and appends each call to $FAKE_GH_LOG.
//   gh api repos/R/<dependabot|code-scanning>/alerts?state=<open|dismissed>...  -> <source>-<state>.json
//   gh pr list ... --author app/<bot> ...                                      -> prs-<bot>.json
// When <name>.err exists instead, it behaves like gh 2.102 on an HTTP error: the JSON body on stdout,
// "gh: <message> (HTTP <status>)" and an unrelated scope hint on stderr, exit 1.
const fs = require("fs");
const a = process.argv.slice(2);
const dir = process.env.FAKE_GH_DIR;
if (process.env.FAKE_GH_LOG) fs.appendFileSync(process.env.FAKE_GH_LOG, JSON.stringify(a) + "\n");
let name = null;
if (a[0] === "api" && a.length === 2) {
  const m = /^repos\/[^/]+\/[^/]+\/(dependabot|code-scanning)\/alerts\?state=(open|dismissed)&/.exec(a[1]);
  if (m) name = `${m[1]}-${m[2]}`;
} else if (a[0] === "pr" && a[1] === "list") {
  name = "prs-" + (a[a.indexOf("--author") + 1] || "").replace("app/", "");
}
if (!name) { process.stderr.write("unexpected gh call\n"); process.exit(3); }
const err = `${dir}/${name}.err`;
if (fs.existsSync(err)) {
  const e = JSON.parse(fs.readFileSync(err, "utf8"));
  process.stdout.write(JSON.stringify(e.body));
  process.stderr.write(`gh: ${e.body.message} (HTTP ${e.status})\ngh: This API operation needs the "admin:repo_hook" scope. To request it, run:  gh auth refresh -h github.com -s admin:repo_hook\n`);
  if (e.once) fs.unlinkSync(err);
  process.exit(1);
}
process.stdout.write(fs.readFileSync(`${dir}/${name}.json`, "utf8"));
