# CI Failure Triager

An OpenClaw Template for maintainers whose GitHub Actions go red more often than they would like. Each weekday it reads the runs that failed, groups the ones that look the same, tells flaky failures from real breaks using the run history, points at the first bad commit, and sends you a short digest with suggested reruns and issues. Nothing changes on GitHub until you OK the exact command.

## What a morning looks like

```
CI triage 2026-11-16: 4 failed runs triaged, 0 still waiting.

New breaks
- example-org/example-repo CI / test (ubuntu-latest) on main since bbbbbbb: TestParseConfig fails since the parser bump. https://github.com/example-org/example-repo/actions/runs/1002

Needs you
- [3] example-org/example-repo run 1002: issue
  Would run: gh issue create --repo example-org/example-repo --title 'CI: CI / test (ubuntu-latest) failing on main' --body-file drafts/example-org__example-repo-run-1002.md
  > `test (ubuntu-latest)` in CI fails on main since bbbbbbb. ...
- [4] example-org/example-repo run 3001: rerun
  Would run: gh run rerun 3001 --failed --repo example-org/example-repo

Repeating failures
- test (ubuntu-latest): 2 runs

Flaky and infra: 2 (1 rerun suggested).

Reply "rerun <id>", "open <id>", or "no <id>".
```

You answer "rerun 4". The agent reads the run list again, checks the run has no newer attempt since you saw it, runs exactly that command, reads it once more, and tells you it is done.

## How it sorts failures

- **Flaky:** the same commit passed this workflow, for example a rerun that went green.
- **New break:** the first failure on a branch after a pass. The first bad commit is that run's commit.
- **Still broken:** it already failed since the last pass. The first bad commit is the earliest failure since then.
- **Infra:** the agent's call when the runner or GitHub failed rather than the code.
- **Unclear:** no pass on that branch in the history it has read so far.

Failures are grouped by a signature: the workflow, the job and its first error lines with numbers, hashes, durations and temp paths removed. The same test failing on two runs gets one signature, and at most one issue is suggested per signature.

## How you stay in control

- Every write (rerun failed jobs, open an issue, comment on a PR) is its own request with the exact command shown. The database builds the command; the agent cannot change it after you saw it.
- Issue titles are built from the workflow, job and branch names, and refused if any of them contain a quote or a control character.
- A request is tied to the run attempt as you saw it. If the run was rerun meanwhile, the request is refused and asked again.
- Issue and comment text is tied to the exact bytes of its draft file. Edit the draft and the agent asks again with the new text.
- Each approval is used once. Scheduled cycles never write to GitHub.
- Setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the read commands once; write commands prompt every time.

These are the agent's rules plus OpenClaw's approval prompt. The agent uses your own `gh` login, which can do anything you can. It is not a sandbox.

## Untrusted text

Anyone who can push or open a PR controls some of the text this agent reads. Here is exactly what reaches the model:

| Source | What the model sees | Cap | Why it is needed |
|--------|---------------------|-----|------------------|
| Run list | Run title (commit headline or PR title), workflow name, branch name | 120, 100 and 255 characters | To name the run in the digest and tell runs on different branches apart |
| Jobs | Failed job and step names | 100 characters each, at most 10 steps | To say which job and step failed |
| Failed-step log | Error lines and an excerpt around the first error, ANSI codes and timestamps removed, secret-looking strings masked | 5 lines of 200 characters; 20 lines and 3000 characters | To tell flaky from real breaks and quote the error in an issue |
| Open PRs | PR number, head commit and link only | none needed | To find the PR a failing commit belongs to |

Commit message bodies, PR titles, PR bodies and comments are never read.

- This text never reaches a command line. Logs are read by `fetch.mjs` with no shell, and drafts go through `--body-file`.
- It never chooses which command runs. The database builds every write from checked values (run ids, PR numbers, the repo's name, and an issue title it refuses if it holds a quote or control character).
- It cannot cause a write on its own. Every write needs the owner's approval of the exact command, and any instructions in the text are ignored.

## What it never does

Cancel or delete runs, rerun whole runs or passing jobs, dispatch workflows, edit workflows, secrets or settings, push or merge, assign people, or @-mention anyone. Log text is treated as untrusted: it never reaches a command line, and secrets that show up in a log are never copied into a draft.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in with read access to your repositories (and the write access the actions you approve need), Node 22 or newer, and sqlite3 3.38 or newer.
- A model that follows long instructions well.
- Model cost: a cycle is one agent turn that triages at most `max_triage_per_cycle` failed runs (10 by default).

## Add it

Not published on ClawHub yet. From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/ci-failure-triager
```

Then open the new agent's chat. Setup asks for your repositories, locks its commands behind the approval prompt, creates the database, runs one cycle, and helps you turn on the schedule.

## Settings

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 5 `owner/repo` names |
| `allowed_actions` | `rerun, issue` | Which writes it may suggest; add `pr-comment` for comments on PRs that broke CI |
| `issue_branches` | `main` | Branches where a new break may get an issue suggestion |
| `max_triage_per_cycle` | 10 | Failed runs per cycle, oldest first |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs fixed `gh` reads with no shell: the 100 newest workflow runs, the PR number and head commit of the 100 newest open PRs, and for each failed run not read before (at most 10 per fetch) its jobs and its failed-step log. Each log is cut as described under "Untrusted text" and cached so it is read once. Full logs are never kept. On a busy repository with large logs, a fetch can take a few minutes (about 2.5 minutes for 10 large logs in testing).

## Data

- The database at `db_path` (default `~/ci-failure-triager.db`) holds runs, failed jobs with their cut logs, verdicts, requests and your answers. It is outside the workspace.
- `inbox/` holds the latest reads and the log cache; `drafts/` holds issue and comment drafts.
- Log excerpts can include whatever your CI prints. They are stored in plain text on the Gateway host.

## Remove it

```sh
openclaw agents delete <agent-id>
```

This removes the workspace and the automation. Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3 3.54:
  - every SQL step and every approval check (`tests/`), with fixtures in the exact shape of real `gh run list`, `gh run view --json jobs` and `--log-failed` output and made-up text
  - `fetch.mjs` against a stand-in `gh`: only read calls, logs read once, the 10-log cap, a 2 MB log cut to size with secrets masked, unreadable logs and jobs
  - live read-only cycles on four public repositories (17 failed runs across them): fetch, ingest, the triage queue and the digest
  - `openclaw templates validate`, `dev`, and `add --dry-run`
- Not yet: a run with a model, the daily automation over several days, an approved write on a throwaway repository, and Linux.

## License

MIT. See [LICENSE](LICENSE).
