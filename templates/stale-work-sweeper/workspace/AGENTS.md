# Operating workflow

## Start here

Read or confirm:

- settings.md: repositories, db_path, stale_days, allowed actions
- references/sweep-loop.md: the commands, the steps, the categories, the scheduled run, and how to answer the owner's requests
- the database at db_path, only through the packaged SQL steps

If settings.md is missing, BOOTSTRAP.md has not finished: run setup first.

## Included capability boundaries

- The profile is `minimal` plus read, write, edit, exec and session_status. The `gateway` tool is denied. There is no messaging tool, no browser and no MCP server. GitHub is reached only through `gh` under exec.
- File tools are limited to this workspace. workspaceOnly does not sandbox exec, and `gh` runs with the owner's full login. Setup sets this agent's exec mode to `ask` and makes references/ read-only, so OpenClaw asks the owner before every command they have not allowed with "Always allow here". The rules in SOUL.md apply on top of that prompt.
- The commands the owner may allow once are the per-repository fetch and the packaged SQL steps, exactly as sweep-loop.md spells them. Every `gh` write command asks every time.

## Process

1. Scheduled run (the Weekly sweep automation): sweep-loop.md, "Scheduled run". Reads, the list, requests and the digest only. No writes to GitHub.
2. The owner answers requests in chat: sweep-loop.md, "Answering requests". Each write is one granted, used-once approval for the exact command.
3. A manual sweep when the owner asks ("sweep now", "what did I leave behind?"): the same steps with run-start kind `manual`.

## Example setting

```
- repos:
  example-org/example-repo
  example-owner/example-repo
- stale_days: 30
- allowed_actions: delete-branch, unassign, comment
```

## Standard deliverables

- The cleanup list at the end of every run, from templates/digest.md
- Comment drafts in drafts/, one file per item, named by ask-approval
- One line per answered request: the command, done or failed, and the restore command for a deleted branch

## Done when

- Every repository in settings.md was fetched and ingested, or its fetch error is in the list
- Every request this run prepared is in the list with its exact command
- No GitHub write ran without a granted, used approval, and every used approval has an outcome
