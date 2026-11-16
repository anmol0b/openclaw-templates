# Operating workflow

## Start here

Read or confirm:

- settings.md: repositories, db_path, allowed actions, issue_min_severity
- references/triage-loop.md: the commands, the steps, what each source can say, the scheduled run, dismissing, and how to answer the owner's requests
- the database at db_path, only through the packaged SQL steps

If settings.md is missing, BOOTSTRAP.md has not finished: run setup first.

## Included capability boundaries

- The profile is `minimal` plus read, write, edit, exec and session_status. The `gateway` tool is denied. There is no messaging tool, no browser and no MCP server. GitHub is reached only through `gh` under exec.
- File tools are limited to this workspace. workspaceOnly does not sandbox exec, and `gh` runs with the owner's full login. Setup sets this agent's exec mode to `ask` and makes references/ read-only, so OpenClaw asks the owner before every command they have not allowed with "Always allow here". The rules in SOUL.md apply on top of that prompt.
- The commands the owner may allow once are the per-repository fetch and the packaged SQL steps, exactly as triage-loop.md spells them. Every `gh` write command asks every time.

## Process

1. Scheduled run (the Weekday triage automation): triage-loop.md, "Scheduled run". Reads, the digest, and tracking-issue requests if allowed. No writes to GitHub, no dismissals.
2. The owner asks to dismiss alerts: triage-loop.md, "Dismissing". The owner chooses the reason.
3. The owner answers requests in chat: triage-loop.md, "Answering requests". Each write is one granted, used-once approval for the exact command.
4. A manual run when the owner asks ("check security alerts"): the same steps with run-start kind `manual`.

## Example setting

```
- repos:
  example-org/example-repo
  example-org/example-service
- allowed_actions: dismiss, issue
- issue_min_severity: high
```

## Standard deliverables

- The digest at the end of every run, from templates/digest.md
- Dismissal comment drafts in drafts/, one file per alert, named by ask-approval, only when the owner wants a comment
- One line per answered request: the command, done or failed, and the issue URL for a tracking issue

## Done when

- Every repository in settings.md was fetched and ingested, or its fetch error is in the digest
- Every source that is turned off or not readable is named in the digest
- No GitHub write ran without a granted, used approval, and every used approval has an outcome
