# Release Notes Drafter

An OpenClaw Template for maintainers who cut releases by hand. It reads the pull requests merged since your last release, groups them, proposes the next version, and writes the release notes and a changelog section. When you OK the exact command, it creates a **draft** GitHub release. Publishing stays yours.

## What a draft looks like

```
example-org/example-repo: v1.4.0 -> v1.5.0 (minor: 3 features, no breaking changes)
  Features 3, Fixes 5, Docs 1, Internal 4. 6 contributors.
  Files: drafts/example-org__example-repo-v1.5.0.md (release body)
         drafts/example-org__example-repo-v1.5.0-CHANGELOG.md (changelog section)
  [7] Would run: gh release create v1.5.0 --repo example-org/example-repo --draft --target main --title 'example-repo v1.5.0' --notes-file drafts/example-org__example-repo-v1.5.0.md

Reply "approve 7", or tell me what to change.
```

## How it decides

- **The base** is the release GitHub marks as latest (or the newest published one). Drafts, prereleases and backport lines are not the base.
- **The window** is every pull request merged into the default branch after the base release's tagged commit.
- **Sections** start from labels and conventional-commit prefixes (`feat:`, `fix:`, `docs:`, `chore:`, `feat!:` and so on); the agent decides the rest from the title and body. Every pull request lands in exactly one section; the database refuses a draft that misses or repeats one.
- **The next version** is computed, not guessed: any breaking change bumps the major version (the minor while on 0.x, a setting), any feature the minor, anything else the patch. You can ask for another version; your words are recorded with it.

## How you stay in control

- The only GitHub write is creating a draft release, and it is its own request with the exact command shown. The database builds the command; the agent cannot change it after you saw it.
- A request is tied to the repository as you saw it. A new merge or a new release after the request makes it refuse, and the agent drafts again.
- It is tied to the exact bytes of the notes file. Edit the notes and the agent asks again.
- Each approval is used once, and after the write the agent checks that GitHub lists the draft release.
- It never publishes a release, pushes a tag, or edits CHANGELOG.md or any other file in your repository.
- Setup sets this agent's exec mode to `ask`, so OpenClaw prompts you for every command you have not allowed. You allow the read commands once; `gh release create` prompts every time.

These are the agent's rules plus OpenClaw's approval prompt. The agent uses your own `gh` login. It is not a sandbox.

## Untrusted text

Anyone who can open an issue or pull request can write text this agent reads. This is exactly what reaches the model:

| Source | What the model sees | Cap | Why |
|--------|---------------------|-----|-----|
| Merged PR titles | the title | 1000 characters | to write each line of the notes |
| Labels and author logins | names only | no free text | to choose sections and credit authors |
| PR descriptions | nothing by default; with `include_pr_bodies: true`, the start of each | 1500 characters | only when titles are not enough |

- None of this text ever reaches a command line. GitHub is read with one fixed command per repository, and every write command is built by the database from checked values (numbers, names from fixed lists, file paths it chooses), never from text the model read.
- Text cannot cause a write. Every write is a request you approve in chat for the exact command, and a scheduled run never writes.
- The agent's instructions tell it to treat this text as data and ignore any instructions in it. Sizes are capped when the text is stored, so one item cannot flood the model.

## Requirements

- OpenClaw with Templates turned on (**Settings → Labs**, or `gateway.controlUi.experimental.templates` set to `true` on a headless install).
- On the Gateway host: `gh` logged in (release permission on the repositories for the drafts you approve), Node 22 or newer, and sqlite3 3.38 or newer.
- A model that follows long instructions well.

## Add it

Not published on ClawHub yet. From a local checkout of this repository, with the Gateway stopped:

```sh
openclaw templates add ./templates/release-notes-drafter
```

Then open the new agent's chat. Setup asks for your repositories, locks its commands behind the approval prompt, creates the database and drafts once.

## Settings

| Setting | Default | What it does |
|---------|---------|--------------|
| `repos` | none | Up to 5 `owner/repo` names |
| `list_bot_prs` | false | List bot pull requests (dependency updates) under Internal |
| `zero_major_breaking_is_minor` | true | On 0.x, a breaking change bumps the minor version |
| `title_format` | `{name} {tag}` | The release title |
| `include_compare_link` | true | End the notes with a Full changelog link |

## How it reads GitHub

One command per repository: `node references/fetch.mjs <owner/repo>`. It runs three fixed `gh` reads with no shell (the default branch, the 30 newest releases, and up to 300 pull requests merged since the base) and writes them to `inbox/`. It computes the search date itself, so the command you allow once never changes. If more than 300 pull requests merged, the digest says the oldest may be missing.

## Data

- The database at `db_path` (default `~/release-notes-drafter.db`) holds releases seen, the current window, drafts, requests and your answers.
- `inbox/` holds the latest raw reads; `drafts/` holds the notes and changelog files.

## Remove it

```sh
openclaw agents delete <agent-id>
```

Delete the file at `db_path` too if you do not want the history.

## Tested, and not yet

- Tested on macOS with gh 2.102, Node 24 and sqlite3 3.54:
  - every SQL step, the version rules and every approval check (`tests/`), with fixtures in the exact shape of real `gh` output
  - `fetch.mjs` against a stand-in `gh`, including that the command stays the same while the search date moves
  - a live read-only pass on a public repository with several release lines: fetch, ingest, sections and the computed tag
  - `openclaw templates validate`, `dev`, and `add --dry-run`
- Not yet: a model following these instructions, a draft release created on a real repository, the weekly automation over weeks, and Linux.

## License

MIT. See [LICENSE](LICENSE).
