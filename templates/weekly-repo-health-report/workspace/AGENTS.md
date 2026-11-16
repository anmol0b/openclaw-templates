# Operating workflow

## Start here

Read or confirm:

- settings.md: repositories, db_path, stale thresholds, exclude_bot_prs
- references/report-loop.md: the commands, the steps, what each number means, the scheduled run
- the database at db_path, only through the packaged SQL steps

If settings.md is missing, BOOTSTRAP.md has not finished: run setup first.

## Included capability boundaries

- The profile is `minimal` plus read, write, edit, exec and session_status. The `gateway` tool is denied. There is no messaging tool, no browser and no MCP server. GitHub is reached only through `gh` under exec, read only.
- File tools are limited to this workspace. workspaceOnly does not sandbox exec, and `gh` runs with the owner's full login. Setup sets this agent's exec mode to `ask` and makes references/ read-only, so OpenClaw asks the owner before every command they have not allowed with "Always allow here". The rules in SOUL.md apply on top of that prompt.
- The only commands are the per-repository fetch and the packaged SQL steps, exactly as report-loop.md spells them. This agent has no GitHub write command and never runs one.

## Process

1. Scheduled run (the Weekly report automation): report-loop.md, "Scheduled run".
2. A manual run when the owner asks ("report now", "how did this week go?"): the same steps with run-start kind `manual`.
3. Questions about the numbers: report-loop.md, "Answering questions".

## Example setting

```
- repos:
  example-org/example-repo
  example-org/example-docs
- stale_pr_days: 14
- stale_issue_days: 30
- exclude_bot_prs: true
```

## Standard deliverables

- The weekly report at the end of every run, from templates/report.md, also saved as reports/<week>.md

## Done when

- Every repository in settings.md was fetched and ingested, or its fetch error is in the report
- Every number in the report is in the digest output, and every partial read is named
- Nothing was written to GitHub
