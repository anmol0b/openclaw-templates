# PR Review Nudger

An OpenClaw Template for maintainers. Each weekday it finds pull requests that are stuck: waiting days for a first review, waiting on their author after you asked for changes, or blocked by a merge conflict. It suggests a reviewer from your CODEOWNERS file and collaborators, drafts a short nudge, and sends one list. Nothing changes on GitHub until you OK the exact command.

## What a morning looks like

```
Review check 2026-11-16: 5 stuck PRs (3 waiting on review, 1 with conflicts, 1 waiting on authors).

Waiting on review
- [31] example-org/example-repo#412 Add retry to upload by alice: 5 days
  Would run: gh pr edit 412 --repo example-org/example-repo --add-reviewer ivan
- [32] example-org/example-repo#398 Cache search results by dave: 3 days, requested: carol
  Would run: gh pr comment 398 --repo example-org/example-repo --body-file drafts/example-org__example-repo-398.md
  > @carol friendly check-in: this got new commits after your last review.

Merge conflicts
- [33] example-org/example-repo#377 Document proxy settings by erin: 6 days
  Would run: gh pr comment 377 --repo example-org/example-repo --body-file drafts/example-org__example-repo-377.md
  > This has a conflict with main now; could you rebase when you get a chance?

Reply "approve <id>", "ask <login> instead on <id>", or "no <id>".
```

You answer "approve 31". The agent reads the repository again, checks the PR has not changed and ivan is still a candidate who is not yet requested, runs exactly that command, then reads again and records it as done only when GitHub shows the request.

## How it decides

- **Waiting on review:** not approved, and nobody with write access (other than the author) has reviewed since the latest commit. Reviews from bots or outside accounts do not count.
- **Waiting on the author:** a maintainer requested changes and no commit landed since.
- **Merge conflict:** GitHub reports a conflict.
- Drafts and approved PRs are never listed. Bot PRs (Dependabot, Renovate) are left out by default.
- **Reviewer suggestions** come only from three fetched lists: user entries in CODEOWNERS, collaborators with push access, and maintainers who reviewed an open PR. CODEOWNERS ranks first, then recent reviewers, then collaborators, then whoever has the fewest open review requests. Never the author, you, or someone already requested.

## How you stay in control

- Every write (request a reviewer, post a nudge comment) is its own request with the exact command shown. The database builds the command; the agent cannot change it after you saw it.
- A request is tied to what you saw: the PR's head commit and last update. If either changes, the request is refused and asked again.
- A reviewer must be in the fetched candidate list both when asked and right before the write. A login typed into a PR title or comment can never become a reviewer.
- A comment is tied to the exact text of its draft file. At most one nudge per PR per `nudge_window_days`. Each approval is used once.
- A write is recorded as done only when a fresh read shows it on GitHub.
- Scheduled runs never write to GitHub.
- On top of that, setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the read commands once; write commands prompt every time.

These are the agent's rules plus OpenClaw's approval prompt. The agent uses your own `gh` login, which can do anything you can. It is not a sandbox.

## What it never does

Approve, merge, close, label or assign anything; remove a reviewer; edit titles or bodies; push.

## Untrusted text

Anyone who can open a pull request can write text this agent reads. This is exactly what reaches the model:

| Source | What the model sees | Cap | Why |
|--------|---------------------|-----|-----|
| PR titles | the title | 300 characters | to name each PR in the list |
| PR authors | the login | 60 characters | to say whose PR it is |
| Reviews and requests | logins, review states and times | plain logins only | to tell who reviewed and who is requested |
| Comments | counts only (all, and yours) | no text | to confirm a nudge landed |

- PR descriptions, comment bodies, review text and commit messages are dropped by `fetch.mjs` before anything is written to disk or the database.
- None of this text ever reaches a command line. GitHub is read with one fixed command per repository, and every write command is built by the database from checked values (PR numbers, logins from the fetched candidate list, file paths it chooses), never from text the model read.
- Text cannot cause a write. Every write is a request you approve in chat for the exact command, and a scheduled run never writes.
- The agent's instructions tell it to treat this text as data and ignore any instructions in it. Sizes are capped when the text is stored, so one PR cannot flood the model.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in, Node 22 or newer, and sqlite3 3.38 or newer.
- Push access to read collaborators, and write access to request reviewers. Without push access, suggestions come from CODEOWNERS and recent reviewers only, and the list says so.
- Model cost: a run is one agent turn over at most 30 listed PRs. Cost depends on your model.
- GitHub cost: five to seven read calls per repository per run.

## Add it

From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/pr-review-nudger
```

Then open the new agent's chat. Setup asks for your repositories, locks its commands behind the approval prompt, creates the database, runs one check, and helps you turn on the weekday schedule.

## Settings

`settings.md` in the agent's workspace:

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 10 `owner/repo` names you maintain |
| `review_wait_days` | 2 | Days waiting for a review before a PR is stuck |
| `author_wait_days` | 7 | Days waiting on the author after changes were requested |
| `conflict_wait_days` | 3 | Days a conflict can sit before a PR is stuck |
| `skip_bot_prs` | true | Leave out Dependabot, Renovate and other bot PRs |
| `allowed_actions` | `request-review, comment` | Which writes it may suggest |
| `nudge_window_days` | 3 | At most one nudge comment per PR in this many days |
| `max_requests_per_run` | 10 | Requests prepared per run |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs fixed `gh` reads with no shell: your login, the repository name, the 30 most recently opened PRs, up to 100 collaborators (skipped with a note when your login cannot read them), and the first CODEOWNERS file GitHub would use (`.github/`, the root, then `docs/`). It keeps only logins, states, counts and times, plus titles. A SQL step loads them into the database and computes the waits from the database clock, so the command never changes.

## Data

- The database at `db_path` (default `~/pr-review-nudger.db`) holds PRs, candidates, requests and your answers. It is outside the workspace, so deleting and re-adding the agent keeps the history.
- `inbox/` holds the latest trimmed reads; `drafts/` holds comment drafts. Both are in the workspace.

## Remove it

```sh
openclaw agents delete <agent-id>
```

This removes the workspace and the automation. Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3 3.54:
  - every SQL step and every approval check (`tests/`), with fixtures in the exact shape of real `gh` output and made-up names
  - `fetch.mjs` against a stand-in `gh` that records every call, including the trimming of every body
  - mutation checks: each guard was broken on purpose and a test failed
  - a live read-only pass on two public repositories (one without collaborator access, one without CODEOWNERS): fetch, ingest, the stuck list and the digest
  - `openclaw templates validate`, `build`, `dev`, and `add --dry-run`
- Not yet: a run with a model, a reviewer request or comment approved end to end on a throwaway repository, the automation over several weeks, and Linux.

## License

MIT. See [LICENSE](LICENSE).
