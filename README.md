# OpenClaw Templates

Engineering Templates for OpenClaw by anmol0b. Nothing here is published on ClawHub yet.
A Template is a package that `openclaw templates add` turns into a new, ordinary OpenClaw agent.

Each folder under `templates/` holds one Template, with the package source at its root.
`tests/` holds its tests and is left out of the published package.

## Templates

| Template | What it does | Folder |
|----------|--------------|--------|
| Repo Maintainer Helper | Triages new issues and PRs on your repos, finds likely duplicates, suggests labels and replies | `templates/repo-maintainer-helper/` |
| CI Failure Triager | Groups failed GitHub Actions runs by failure signature, tells flaky from new breaks, drafts reruns and issues | `templates/ci-failure-triager/` |
| Dependency Update Reviewer | Sorts Dependabot and Renovate PRs into looks safe, needs a look and blocked by CI | `templates/dependency-update-reviewer/` |
| Release Notes Drafter | Drafts release notes from PRs merged since the last release and proposes the next version | `templates/release-notes-drafter/` |
| Stale Work Sweeper | Lists your own stale branches, PRs and assigned issues, safest cleanup first | `templates/stale-work-sweeper/` |

## How they work

All five follow the same rules:

- GitHub is read with one fixed, read-only command per repository: `node references/fetch.mjs <owner/repo>`. It runs fixed `gh` reads with no shell, so you can allow it once.
- State lives in a SQLite database outside the workspace, reached only through packaged SQL steps.
- Every GitHub write is a request you approve in chat for an exact command the database builds from checked values. It is tied to what you saw and used once. Scheduled runs never write.
- Each Template's README has an "Untrusted text" section listing exactly which GitHub text reaches the model and how much.

## Check a Template locally

You need OpenClaw with the `templates` command, Node 22 or newer, and sqlite3 3.38 or newer with FTS5 (the stock macOS sqlite3 has it).

```sh
cd templates/<name>
openclaw templates validate .
openclaw templates dev .
for t in tests/*.test.sh; do zsh "$t" .; done
for t in tests/*.test.mjs; do node "$t" .; done
```

## Status

Every Template passes its own tests, `openclaw templates validate`, `dev` and `add --dry-run`, and a live read-only pass on public repositories. None has been run with a model yet.

## License

MIT. See [LICENSE](LICENSE).
