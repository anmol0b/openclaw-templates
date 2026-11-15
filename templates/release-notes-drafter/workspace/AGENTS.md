# Operating workflow

## Start here

Read or confirm:

- settings.md: repositories, db_path, bot pull requests, the 0.x rule, the title format
- references/release-loop.md: the commands, the steps, the drafting run, and how to answer the owner's requests
- the database at db_path, only through the packaged SQL steps

If settings.md is missing, BOOTSTRAP.md has not finished: run setup first.

## Included capability boundaries

- The profile is `minimal` plus read, write, edit, exec and session_status. The `gateway` tool is denied. There is no messaging tool, no browser and no MCP server. GitHub is reached only through `gh` under exec.
- File tools are limited to this workspace. workspaceOnly does not sandbox exec, and `gh` runs with the owner's full login. Setup sets this agent's exec mode to `ask` and makes references/ read-only, so OpenClaw asks the owner before every command they have not allowed with "Always allow here". The rules in SOUL.md apply on top of that prompt.
- The commands the owner may allow once are the per-repository fetch and the packaged SQL steps, exactly as release-loop.md spells them. `gh release create` asks every time.

## Process

1. Drafting run (the Weekly release draft automation, or the owner says "draft release notes"): release-loop.md, "Drafting run". Reads, drafts, files and a request per repository. No writes to GitHub.
2. The owner answers in chat: release-loop.md, "Answering requests". One granted, used-once approval creates one draft release.
3. Questions such as "what changed since the last release?": run the read steps and answer from pending-prs, without saving a draft.

## Example setting

```
- repos:
  example-org/example-repo
- list_bot_prs: false
- zero_major_breaking_is_minor: true
```

## Standard deliverables

- Per repository: the release body (notes_file) and the changelog section (changelog_file) in drafts/, named by save-draft
- The digest at the end of every run: base tag, proposed tag and bump, counts per section, the request and its exact command
- One line per answered request: the command, done or failed, and the releases page

## Done when

- Every repository in settings.md was fetched and ingested, or its fetch error is in the digest
- Every repository with merges has a saved draft, both files written from render-draft, and a request, or the digest says why not
- No GitHub write ran without a granted, used approval, and every used approval has an outcome
