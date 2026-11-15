# Operating workflow

## Start here

Read or confirm:

- settings.md: repositories, db_path, cycle limits, allowed actions, issue branches, digest style
- references/ci-triage-loop.md: the commands, the steps, the scheduled cycle, and how to answer the owner's requests
- the database at db_path, only through the packaged SQL steps

If settings.md is missing, BOOTSTRAP.md has not finished: run setup first.

## Included capability boundaries

- The profile is `minimal` plus read, write, edit, exec and session_status. The `gateway` tool is denied. There is no messaging tool, no browser and no MCP server. GitHub is reached only through `gh` under exec.
- File tools are limited to this workspace. workspaceOnly does not sandbox exec, and `gh` runs with the owner's full login. Setup sets this agent's exec mode to `ask` and makes references/ read-only, so OpenClaw asks the owner before every command they have not allowed with "Always allow here". The rules in SOUL.md apply on top of that prompt.
- The commands the owner may allow once are the per-repository fetch and the packaged SQL steps, exactly as ci-triage-loop.md spells them. Every `gh` write command asks every time.

## Process

1. Scheduled cycle (the Daily CI triage automation): ci-triage-loop.md, "Scheduled cycle". Reads, triage, requests and the digest only. No writes to GitHub.
2. The owner answers requests in chat: ci-triage-loop.md, "Answering requests". Each write is one granted, used-once approval for the exact command.
3. A manual cycle when the owner asks ("check CI", "why is main red?"): the same steps with cycle-start kind `manual`.
4. Questions about the history ("is this test flaky?"): answer from to-triage hints and the digest of earlier cycles, or say what the database does not hold.

## Example setting

```
- repos:
  example-org/example-repo
- allowed_actions: rerun, issue
- issue_branches: main
```

## Standard deliverables

- The digest at the end of every cycle, from templates/digest.md
- Issue and comment drafts in drafts/, one file per run or PR, named by ask-approval
- One line per answered request: the command, done or failed, and the link

## Done when

- Every repository in settings.md was fetched and ingested, or its error is in the cycle-end note
- Every run to-triage returned in this cycle has a saved verdict, or the note says why not
- Every request this cycle prepared is in the digest with its exact command
- No GitHub write ran without a granted, used approval, and every used approval has an outcome
