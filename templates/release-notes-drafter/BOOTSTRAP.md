# First-run setup

A guided setup of about 10 minutes: the repositories, a lock on what this agent may run, the database, and one draft by hand.

Use these instructions only while setup is not finished. In a scheduled run, ignore this file and follow SOUL.md. Setup is done when settings.md exists with no `<...>` left in a required line, the first draft has been shown, and the owner has removed this file ("Finish setup" below).

1. Read the existing workspace and user context. Reuse facts already supplied.
2. Ask only for values that are still missing.
3. Confirm the proposed settings before writing them.
4. Create settings.md only when absent: copy templates/settings.md, then fill in the answers. If it already exists, keep it and offer a short update instead.
5. Then continue with the steps below, in order.

Never ask for or store a token, password or code. The only `gh auth` command you run is `gh auth status`; the owner logs in themselves.

Some steps are commands the owner runs in a terminal on the Gateway host. Show each one with the real values filled in, in a code block, and wait for the owner to say it worked. `<agent-id>` is this agent's id: in the session key `session_status` shows (`agent:<agent-id>:...`), the text between `agent:` and the next colon. A second Add of this Template gets a different id, so never assume `release-notes-drafter`. `<workspace>` is the absolute path of this workspace, as your file tools report it.

## Say this first

Tell the owner, in a few lines, before any question:
- This agent drafts release notes from the pull requests merged since each repository's last release, and proposes the next version.
- It writes the notes as files here. The only thing it does on GitHub is create a draft release, and only after they OK the exact command. It never publishes a release, pushes a tag, or edits files in the repository.
- It uses their own `gh` login, so the next step locks its commands behind OpenClaw's approval prompt.
- The weekly automation is installed paused.

## Questions

- **Repositories** (`repos`): required, 1 to 5 `owner/repo` names they release by hand.
- **Database** (`db_path`): optional, default `~/release-notes-drafter.db`.
- **Bot pull requests** (`list_bot_prs`): optional, default false.
- **0.x rule** (`zero_major_breaking_is_minor`): optional, default true.
- **Time zone**: only if they want the weekly draft, an IANA name such as `Europe/Berlin`.

## Exec host and approvals (required, before any other command)

Ask the owner to run this in a terminal on the Gateway host, and paste the output of the last command:

```sh
openclaw config set 'agents.entries.<agent-id>.tools.exec.host' gateway
openclaw config set 'agents.entries.<agent-id>.tools.exec.mode' ask
chmod -R a-w "<workspace>/references"
openclaw exec-policy show --agent <agent-id>
```

The second line makes every command wait for the owner's OK until they allow that exact command. Without it, OpenClaw's default runs commands with no prompt.

Tell the owner:
- Choose "Always allow here" only for `node references/fetch.mjs <owner/repo>` for each repository, and for each packaged step, `sqlite3 -bail -json "<db_path>" ".read references/sql/<step>.sql"` (and the form without `-json` for render-draft and digest). They read GitHub or the local database and never write.
- Never choose "Always allow" for `gh release create` or any other sqlite3 command. Approve each one once, after the agent's request in chat.
- Approval prompts show only in the Control UI chat for this agent or a chat channel with exec approvals. Scheduled runs need the fetch and SQL commands allowed first, or they stop at the first prompt.

## Tools

Run each and check the output (the owner approves each once):

1. `gh auth status`: logged in. If not, the owner runs `gh auth login` themselves.
2. `node --version`: 22 or newer.
3. `sqlite3 --version`: 3.38 or newer.

## Database

1. Run the setup check: `sqlite3 -bail -json "<db_path>" ".read references/sql/setup-check.sql"`.
   - `"result":"ok"`: the database exists from an earlier Add. Keep it.
   - Refused with `wrong_schema_version` (a new, empty file): create the tables with `sqlite3 -bail "<db_path>" ".read references/schema.sql"`, then run the setup check again.
   - Refused with `sqlite_older_than_3_38` or `sqlite_without_sha3`: tell the owner to install a newer sqlite3 and stop.
2. Run `add-repo` for each repository (release-loop.md, "Commands").

## First draft

1. Run release-loop.md, "Drafting run", with run-start kind `manual`. The owner approves the fetch and SQL commands as they come up.
2. Show the digest and both files for one repository. Point out the proposed tag and the bump reason, and say that creating the draft release is optional now.
3. If the owner answers the request, follow release-loop.md, "Answering requests".

## Weekly draft (optional)

If the owner wants a draft every week, ask them to run:

```sh
openclaw automations list --agent <agent-id> --all
```

From the `Weekly release draft` row, take its id as `<job-id>`, then:

```sh
openclaw automations edit <job-id> --cron "0 9 * * 5" --tz <time zone>
openclaw automations enable <job-id>
```

`openclaw automations disable <job-id>` stops it; `paused: true` in settings.md makes runs end at once.

## Finish setup

When the first draft has been shown, ask the owner to remove this file, so OpenClaw stops treating setup as pending:

```sh
rm "<workspace>/BOOTSTRAP.md"
```

The setup notes stay in docs/README.md.
