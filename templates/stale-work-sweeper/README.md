# Stale Work Sweeper

An OpenClaw Template for developers who work across several repositories and forks. Once a week it finds the branches you left behind, the PRs you opened that went quiet, and the issues assigned to you that nobody touched, and sends one cleanup list, safest first. Nothing changes on GitHub until you OK the exact command.

## What a Monday looks like

```
Sweep 2026-11-16: 6 stale items, no activity for 30+ days.

Safe to clean up
- [21] example-owner/example-repo branch feature/search-cache, merged via #412, idle 48 days
  Would run: node references/delete-branch.mjs example-owner/example-repo feature/search-cache 3f9c2e7a1b4d5c6e8f0a1b2c3d4e5f6a7b8c9d0e

Idle PRs
- [22] example-org/example-repo#398 Add retry to upload: idle 41 days, draft, CI failing, conflicts
  Would run: gh pr comment 398 --repo example-org/example-repo --body-file drafts/example-org__example-repo-398.md
  > Parking this; the retry moved into the client rewrite.

Idle assigned issues
- [23] example-org/example-repo#377 Document proxy settings: idle 63 days
  Would run: gh issue edit 377 --repo example-org/example-repo --remove-assignee @me

Unmerged branches (for you to look at, no action suggested)
- example-owner/example-repo branch wip/theme-tokens, idle 35 days

Reply "approve <id>", "approve all branch deletes", or "no <id>".
```

You answer "approve 21". The agent reads the repository again, checks the branch head has not moved and it is still merged with no open PR, runs exactly that command (GitHub deletes the branch only if it still points at the commit you approved), reads again, and gives you a restore command with the branch's last SHA in case you want it back.

## What counts as yours, and safe

- **Yours:** branches whose last commit is yours, PRs you opened, issues assigned to you. Your login comes from `gh api user`.
- **Safe to delete:** a branch whose commits are all in the default branch, or whose exact head was merged through a PR (squash and rebase merges count), with no open PR, not protected and not the default branch. Unmerged branches are listed for you to look at and never suggested for deletion.

## How you stay in control

- Every write (delete a merged branch, comment, close one of your PRs, unassign yourself) is its own request with the exact command shown. The database builds the command; the agent cannot change it after you saw it.
- A request is tied to what you saw: the branch head, or the PR's or issue's last update. If it changes, the request is refused and asked again.
- A comment is tied to the exact text of its draft file. Each approval is used once.
- Scheduled runs never write to GitHub.
- On top of that, setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the read commands once; write commands prompt every time.

These are the agent's rules plus OpenClaw's approval prompt. The agent uses your own `gh` login, which can do anything you can. It is not a sandbox.

## What it never does

Touch anyone else's branch, PR or issue; delete an unmerged, protected or default branch; force-push, merge or reopen anything; edit titles or bodies.

## Untrusted text

Anyone who can open an issue or pull request can write text this agent reads. This is exactly what reaches the model:

| Source | What the model sees | Cap | Why |
|--------|---------------------|-----|-----|
| Your PR and issue titles | the title | 300 characters | to name each item in the list |
| Branch names | the name | the strict branch-name rules | to name each branch |
| Check states | pass, fail or pending | no free text | to rank idle PRs |

- None of this text ever reaches a command line. GitHub is read with one fixed command per repository, and every write command is built by the database from checked values (numbers, names from fixed lists, file paths it chooses), never from text the model read.
- Text cannot cause a write. Every write is a request you approve in chat for the exact command, and a scheduled run never writes.
- The agent's instructions tell it to treat this text as data and ignore any instructions in it. Sizes are capped when the text is stored, so one item cannot flood the model.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in, Node 22 or newer, and sqlite3 3.38 or newer.
- Model cost: a run is one agent turn over at most 30 listed items. Cost depends on your model.
- GitHub cost: five read calls per repository per run.

## Add it

Not published on ClawHub yet. From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/stale-work-sweeper
```

Then open the new agent's chat. Setup asks for your repositories, locks its commands behind the approval prompt, creates the database, runs one sweep, and helps you turn on the weekly schedule.

## Settings

`settings.md` in the agent's workspace:

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 10 `owner/repo` names: forks for branches, upstream repos for your PRs there |
| `stale_days` | 30 | No activity for this many days counts as stale |
| `allowed_actions` | `delete-branch, unassign, comment` | Which writes it may suggest; add `close` for idle PRs |
| `max_requests_per_run` | 10 | Requests prepared per run |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs five fixed `gh` reads with no shell: your login, the default branch, the newest 100 branches with merge status (one GraphQL query; GitHub computes the comparison, there is no call per branch), your open PRs, and the open issues assigned to you. A SQL step loads them into the database and computes the cutoff from the database clock, so the command never changes. The list says when a repository has more branches than were read.

## Data

- The database at `db_path` (default `~/stale-work-sweeper.db`) holds items, requests and your answers. It is outside the workspace, so deleting and re-adding the agent keeps the history.
- `inbox/` holds the latest raw reads; `drafts/` holds comment drafts. Both are in the workspace.

## Remove it

```sh
openclaw agents delete <agent-id>
```

This removes the workspace and the automation. Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3 3.54:
  - every SQL step and every approval check (`tests/`), with fixtures in the exact shape of real `gh` output and made-up names
  - `fetch.mjs` against a stand-in `gh` that records every call
  - a live read-only pass on real repositories: fetch, ingest, the stale list and the digest
  - `openclaw templates validate`, `dev`, and `add --dry-run`
- Not yet: a run with a model, the weekly automation over several weeks, a branch delete approved end to end on a throwaway repository, and Linux.

## License

MIT. See [LICENSE](LICENSE).
