# First-Timer Welcomer

An OpenClaw Template for maintainers who want every newcomer to get a human reply. Once a week it finds PRs and issues opened recently by people new to your repositories that nobody answered yet, drafts a short welcome in your voice for each, and suggests a newcomer label for issues that look like a fit. Each person is welcomed once per repository. Nothing changes on GitHub until you OK the exact command.

## What a Monday looks like

```
Welcome pass 2026-11-16: 3 newcomers waiting, 4 newcomer items in the last 14 days.

Waiting for a welcome
- [31] example-org/example-repo#412 Fix typo in install docs, by example-newbie-a (NONE), open 2 days
  Would run: gh pr comment 412 --repo example-org/example-repo --body-file drafts/example-org__example-repo-412.md
  > Thanks for your first PR here, @example-newbie-a! A maintainer will take a look. The contributing guide is at CONTRIBUTING.md.
- [32] example-org/example-repo#409 Add a dark theme toggle, by example-newbie-b (FIRST_TIME_CONTRIBUTOR), open 4 days, draft
  Would run: gh pr comment 409 --repo example-org/example-repo --body-file drafts/example-org__example-repo-409.md
  > Thanks for opening this, @example-newbie-b! No rush while it's a draft; say when it's ready for a look.

Could take a newcomer label
- [33] example-org/example-repo#377 Document the proxy settings
  Would run: gh issue edit 377 --repo example-org/example-repo --add-label 'good first issue'

Reply "approve <id>", "send all the welcomes", or "no <id>".
```

You answer "approve 31". The agent reads the repository again, checks that the PR has not changed and that nobody welcomed that person since, checks the draft is the exact text you saw, runs exactly that command, then reads again to confirm the comment is there and records the person as welcomed.

## Who counts as new

- **Newcomer:** GitHub marks the author `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER` or `NONE` for that PR or issue, the author is a person (not a bot), and it is not you.
- **Waiting:** this agent has not welcomed that person in this repository, and you have not commented on the item.
- **Label candidate:** an open issue with no assignee, no open PR that would close it, a description of at least 80 characters, and none of your allowed labels yet. Whether it is small enough for a newcomer is a judgment from the title, so the agent suggests few, and you decide.

`NONE` also marks people who opened issues before but never contributed code, so on a busy repository the list is longer than the people who are truly new. The once-per-person rule and `recent_days` keep it bounded.

## How you stay in control

- Every write (a welcome comment, or adding one allowed label) is its own request with the exact command shown. The database builds the command; the agent cannot change it after you saw it.
- A request is tied to what you saw: the item's last update. If the item changes, the request is refused and asked again.
- A welcome is tied to the exact text of its draft file. Each approval is used once. One person gets one welcome per repository, even across several PRs and issues.
- A label must be in your `allowed_labels` and exist in the repository under that exact name.
- A write counts as done only when a read afterward shows it on GitHub.
- Scheduled runs never write to GitHub.
- On top of that, setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the read commands once; write commands prompt every time.

These are the agent's rules plus OpenClaw's approval prompt. The agent uses your own `gh` login, which can do anything you can. It is not a sandbox.

## What it never does

Welcome a bot, you, or the same person twice in a repository; comment where you already commented; remove a label; assign, close, merge or review anything; edit titles or bodies; mention anyone but the item's author.

## Untrusted text

Anyone who can open an issue or pull request can write text this agent reads. This is exactly what reaches the model:

| Source | What the model sees | Cap | Why |
|--------|---------------------|-----|-----|
| PR and issue titles | the title | 300 characters | to name each item and judge if an issue suits a newcomer |
| Author logins | the login | GitHub's login rules (letters, digits, dash) | to name and thank the person |
| Label names | the name | 50 characters, 20 per item | to show what an issue already has |
| Issue bodies | a character count only | a number | to skip issues with no real description |
| Comments | only whether you wrote one, and when | a time | to skip items you already answered |

- None of this text ever reaches a command line. GitHub is read with one fixed command per repository, and every write command is built by the database from checked values (numbers, labels from your settings, file paths it chooses), never from text the model read.
- Text cannot cause a write. Every write is a request you approve in chat for the exact command, and a scheduled run never writes.
- The agent's instructions tell it to treat this text as data and ignore any instructions in it. Sizes are capped when the text is stored, so one item cannot flood the model.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in, Node 22 or newer, and sqlite3 3.38 or newer.
- Model cost: a run is one agent turn over at most 30 newcomer items and 20 label candidates. Cost depends on your model.
- GitHub cost: one GraphQL read per repository per run.

## Add it

Not published on ClawHub yet. From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/first-timer-welcomer
```

Then open the new agent's chat. Setup asks for your repositories and labels, locks its commands behind the approval prompt, creates the database, runs one pass, and helps you turn on the weekly schedule.

## Settings

`settings.md` in the agent's workspace:

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 10 `owner/repo` names you maintain |
| `recent_days` | 14 | PRs and issues opened in this many days are listed |
| `allowed_actions` | `welcome, add-label` | Which writes it may suggest |
| `allowed_labels` | `good first issue, help wanted` | 1 to 5 labels it may suggest, spelled as in your repositories |
| `welcome_note` | none | One sentence added to every welcome, such as a link to your contributing guide |
| `max_requests_per_run` | 10 | Requests prepared per run |
| `max_label_suggestions` | 3 | Label suggestions per run |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs one fixed `gh api graphql` query with no shell: your login, the first 100 labels, and the newest 50 open PRs and 100 open issues by last update, each with its author's association to the repository. The association is only in GitHub's GraphQL API; `gh pr list` and `gh issue list` do not return it. Issue bodies are turned into a character count and comments into the time of your latest one before anything is written to disk. A SQL step loads the result into the database, so the command never changes. The list says when a repository has more than was read.

## Data

- The database at `db_path` (default `~/first-timer-welcomer.db`) holds items, requests, your answers, and who was welcomed. It is outside the workspace, so deleting and re-adding the agent keeps the history and nobody is welcomed twice.
- `inbox/` holds the latest reads (no bodies or comment text); `drafts/` holds welcome drafts. Both are in the workspace.

## Remove it

```sh
openclaw agents delete <agent-id>
```

This removes the workspace and the automation. Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3:
  - every SQL step and every approval check (`tests/`), with a fixture in the exact shape of the real GraphQL response and made-up names
  - `fetch.mjs` against a stand-in `gh` that records every call
  - a live read-only pass on two public repositories: fetch, ingest, the newcomer list, label candidates and the digest
  - `openclaw templates validate`, `build`, and `add --dry-run`
- Not yet: a run with a model, the weekly automation over several weeks, a welcome or label approved end to end on a throwaway repository, and Linux.

## License

MIT. See [LICENSE](LICENSE).
