# Operating workflow

## Start here

Read or confirm:

- settings.md: repositories, db_path, run limits, allowed actions, digest style
- references/review-loop.md: the commands, the steps, the scheduled run, and how to answer the owner's requests
- the database at db_path, only through the packaged SQL steps

If settings.md is missing, BOOTSTRAP.md has not finished: run setup first.

## Included capability boundaries

- The profile is `minimal` plus read, write, edit, exec and session_status. The `gateway` tool is denied. There is no messaging tool, no browser and no MCP server. GitHub is reached only through `gh` under exec.
- File tools are limited to this workspace. workspaceOnly does not sandbox exec, and `gh` runs with the owner's full login. Setup sets this agent's exec mode to `ask` and makes references/ read-only, so OpenClaw asks the owner before every command they have not allowed with "Always allow here". The rules in SOUL.md apply on top of that prompt.
- The commands the owner may allow once are the per-repository fetch and the packaged SQL steps, exactly as review-loop.md spells them. Every `gh` write command asks every time.

## Process

1. Scheduled run (the Daily dependency review automation): review-loop.md, "Scheduled run". Reads, reviews, requests and the digest only. No writes to GitHub.
2. The owner answers requests in chat: review-loop.md, "Answering requests". Each write is one granted, used-once approval for the exact command.
3. A manual pass when the owner asks ("check my dependency PRs"): the same steps as a scheduled run with run-start kind `manual`.
4. Questions about one PR ("is the example-http bump safe?"): fetch, ingest, to-review or the digest, then answer from what they show, and say what the release notes do not cover.

## Example setting

```
- repos:
  example-org/example-repo
- allowed_actions: approve
- max_reviews_per_run: 20
```

## Standard deliverables

- The digest at the end of every run, from templates/digest.md
- Comment drafts in drafts/, one file per PR, named by ask-approval
- One line per answered request: the command, done or failed, and the link

## Done when

- Every repository in settings.md was fetched and ingested, or its fetch error is in the run-end note
- Every PR to-review returned in this run has a saved review, or the run-end note says why not
- Every request this run prepared is in the digest with its exact command
- No GitHub write ran without a granted, used approval, and every used approval has an outcome
