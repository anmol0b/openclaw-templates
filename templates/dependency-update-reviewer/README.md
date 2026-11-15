# Dependency Update Reviewer

An OpenClaw Template for people who use Dependabot or Renovate. Each weekday it reads the open dependency PRs on your repositories, works out what each one changes, reads the release notes the bots include, checks CI, and sorts them into **looks safe**, **needs a look** and **blocked by CI**. It never merges. Approving, commenting, or asking Dependabot to rebase waits for your OK of the exact command.

## What a morning looks like

```
Dependency updates 2026-11-16: 3 looks safe, 5 needs a look, 1 blocked by CI.

Looks safe
- [21] example-org/example-repo#201 example-cli 4.5.5 → 4.5.6 (patch, npm): Bug fixes only, CI green.
  Would run: gh pr review 201 --repo example-org/example-repo --approve

Needs a look
- example-org/example-repo#102 example-http 2.4.1 → 3.0.0: major-bump, breaking-note. The default timeout changed in 3.0; check callers that rely on it.
- example-org/example-repo#204 example-glob 8.0.6 → 9.0.2: security fix, major-bump.

Blocked by CI
- example-org/example-repo#106 tiny-yaml: failing test, example/status.

Same package in more than one PR
- example-org/example-repo example-glob: #204, #205

Reply "approve <id>", "approve all safe", or "no <id>".
```

## How the sorting works

- The package, versions, ecosystem and bump type (major, minor, patch, digest) come from packaged code that reads both bots' title and body formats, including Dependabot groups and Renovate multi-package tables. The model does not guess them.
- Signals come from the release notes the bot includes: breaking changes, removals, deprecations, new runtime floors, security fixes. The bots' own help text is ignored.
- A PR's lowest lane comes from facts: failing CI blocks; a major bump, a 0.x minor bump, an unknown version, a breaking or removal note, a runtime floor change, a draft, or missing or running CI needs a look. Everything else looks safe.
- The agent reads the notes and can move a PR to a stricter lane with a reason. The database refuses a looser one.

## How you stay in control

- Every write (approve, comment, `@dependabot rebase` or `recreate`) is its own request with the exact command shown. The database builds the command; the agent cannot change it after you saw it.
- A request is tied to the PR's head commit and update time as you saw them. If the bot pushes again, the request is refused and the PR is reviewed again.
- Approve needs a looks-safe review of the current head and passing CI, checked again right before it runs.
- A comment is tied to the exact text of its draft file. Each approval is used once.
- Scheduled runs never write to GitHub.
- Setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the read commands once; write commands prompt every time.

These are the agent's rules plus OpenClaw's approval prompt. The agent uses your own `gh` login, which can do anything you can. It is not a sandbox.

## What it never does

Merge, enable auto-merge, close, reopen, label, push, edit PRs, request changes, post any other bot command (`@dependabot merge`, `ignore ...`, and so on), tick Renovate checkboxes, or @-mention anyone.

## Untrusted text

Anyone who can open an issue or pull request can write text this agent reads. This is exactly what reaches the model:

| Source | What the model sees | Cap | Why |
|--------|---------------------|-----|-----|
| PR titles | the title | 1000 characters | to name the update |
| Release notes in the PR body | only the lines that raised a signal, links replaced | 8 lines of 200 characters | to check a breaking or security note |
| Package names | the parsed name | 200 characters | to group updates to the same package |
| Check names | names of failing checks | 10 names of 120 characters | to say why CI blocks it |

- None of this text ever reaches a command line. GitHub is read with one fixed command per repository, and every write command is built by the database from checked values (numbers, names from fixed lists, file paths it chooses), never from text the model read.
- Text cannot cause a write. Every write is a request you approve in chat for the exact command, and a scheduled run never writes.
- The agent's instructions tell it to treat this text as data and ignore any instructions in it. Sizes are capped when the text is stored, so one item cannot flood the model.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in with access to your repositories, Node 22 or newer, and sqlite3 3.38 or newer.
- Dependabot or Renovate running as the GitHub App (`app/dependabot`, `app/renovate`). A self-hosted Renovate that opens PRs as another account is not read.
- Model cost: a run is one agent turn that reviews at most `max_reviews_per_run` PRs (20 by default).

## Add it

Not published on ClawHub yet. From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/dependency-update-reviewer
```

Then open the new agent's chat. Setup asks for your repositories, locks its commands behind the approval prompt, creates the database, runs one pass, and helps you turn on the schedule.

## Settings

`settings.md` in the agent's workspace. The main ones:

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 5 `owner/repo` names |
| `allowed_actions` | `approve` | Which writes it may suggest: approve, comment, bot-command |
| `max_reviews_per_run` | 20 | PRs reviewed per run, oldest change first |
| `comment_on_holds` | false | Suggest a short comment on PRs that need a look |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs two fixed `gh pr list` reads with no shell (the open PRs by each bot, up to 30 each), retries once if GitHub times out, parses each PR, and writes the result to `inbox/`. A SQL step loads it into the database. A PR that a full read no longer lists is marked as merged or closed. A read that hits 30 is flagged in the digest and marks nothing.

## Data

- The database at `db_path` (default `~/dependency-update-reviewer.db`) holds PRs, reviews, requests and your answers. It is outside the workspace, so deleting and re-adding the agent keeps the history.
- `inbox/` holds the latest parsed reads; `drafts/` holds comment drafts. Both are in the workspace.

## Remove it

```sh
openclaw agents delete <agent-id>
```

This removes the workspace and the automation. Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3 3.54:
  - the parser on every format below, checked first against live public PRs (`tests/parse.test.mjs`): Dependabot single and grouped (semver and digests), Renovate single, multi-package, title-only and lock file maintenance
  - every SQL step and every approval check (`tests/`), with fixtures in the exact shape of real `gh` output and made-up text
  - `fetch.mjs` against a stand-in `gh`, including the one retry on HTTP 504
  - a live read-only pass on a public repository: fetch, ingest and the digest
  - `openclaw templates validate`, `dev`, and `add --dry-run`
- Not yet: a full Add with a model turn, the daily automation over days, an approved write on a throwaway repository, and Linux.

## License

MIT. See [LICENSE](LICENSE).
