# First-run setup

A guided setup of about 10 minutes: the repositories, a lock on what this agent may run, the database, a check that this login can read the alerts, and one run by hand before the weekday automation is turned on.

Use these instructions only while setup is not finished. In a scheduled run, ignore this file and follow SOUL.md. Setup is done when settings.md exists with no `<...>` left in a required line, the first run has finished and its digest was shown, and the owner has removed this file ("Finish setup" below).

1. Read the existing workspace and user context. Reuse facts already supplied.
2. Ask only for values that are still missing.
3. Confirm the proposed settings before writing them.
4. Create settings.md only when absent: copy templates/settings.md, then fill in the answers. If it already exists, keep it and offer a short update instead.
5. Then continue with the steps below, in order.

Never ask for or store a token, password or code. The only `gh auth` command you run is `gh auth status`; the owner logs in themselves.

Some steps are commands the owner runs in a terminal on the Gateway host. Show each one with the real values filled in, in a code block, and wait for the owner to say it worked. `<agent-id>` is this agent's id: in the session key `session_status` shows (`agent:<agent-id>:...`), the text between `agent:` and the next colon. A second Add of this Template gets a different id, so never assume `security-alert-triager`. `<workspace>` is the absolute path of this workspace, as your file tools report it.

## Say this first

Tell the owner, in a few lines, before any question:
- Each weekday this agent reads the Dependabot and code scanning alerts on their repositories and sends one digest, grouped by package and rule, most severe first, with the bot PRs that already fix them.
- It says plainly when a repository has alerts turned off, or when their login cannot read them, instead of reporting "no alerts".
- Nothing changes on GitHub until they OK the exact command in chat. It dismisses an alert only when they ask, with the reason they choose. It can open a tracking issue for a Dependabot alert if they allow it; it never opens one for a code scanning alert.
- It uses their own `gh` login, which can do anything they can, so the next step locks its commands behind OpenClaw's approval prompt.
- The weekday automation is installed paused. Setup runs one pass by hand first.

## Questions

- **Repositories** (`repos`): required, 1 to 10 `owner/repo` names whose security alerts they can see.
- **Actions** (`allowed_actions`): optional, default `dismiss`. Add `issue` for tracking-issue requests on Dependabot alerts; say that on a public repository the issue is public.
- **Issue threshold** (`issue_min_severity`): only with `issue`, default `high`.
- **Database** (`db_path`): optional, default `~/security-alert-triager.db`.
- **Time zone**: required for the schedule, an IANA name such as `Europe/Berlin`.

## Exec host and approvals (required, before any other command)

Ask the owner to run this in a terminal on the Gateway host, and paste the output of the last command:

```sh
openclaw config set 'agents.entries.<agent-id>.tools.exec.host' gateway
openclaw config set 'agents.entries.<agent-id>.tools.exec.mode' ask
chmod -R a-w "<workspace>/references"
openclaw exec-policy show --agent <agent-id>
```

The first line runs this agent's commands on the Gateway host, where this workspace is. The second makes every command wait for the owner's OK until they allow that exact command. Without it, OpenClaw's default runs commands with no prompt. The `chmod` makes the packaged steps read-only.

Tell the owner:
- Choose "Always allow here" for these, and only these: `node references/fetch.mjs <owner/repo>` for each repository, and each packaged step, `sqlite3 -bail -json "<db_path>" ".read references/sql/<step>.sql"` (and the digest's form without `-json`). They read GitHub or the local database and never write to GitHub.
- Never choose "Always allow" for `gh api -X PATCH` (a dismissal), `gh issue create`, or any other sqlite3 command. Approve those once each, after the agent's request in chat.
- Approval prompts show only in the Control UI chat for this agent or a chat channel with exec approvals. Scheduled runs need the fetch and SQL commands allowed first, or they stop at the first prompt.

## Tools and access

Run each and check the output (the owner approves each once):

1. `gh auth status`: logged in, and the token scopes include `repo` (or `security_events`, plus `public_repo` for public repositories). With a fine-grained token, it needs "Dependabot alerts" and "Code scanning alerts" read access, and write access for dismissals; "Issues" write for tracking issues. If a scope is missing, the owner runs `gh auth refresh -s security_events` themselves.
2. `node --version`: 22 or newer.
3. `sqlite3 --version`: 3.38 or newer.

## Database

1. Run the setup check: `sqlite3 -bail -json "<db_path>" ".read references/sql/setup-check.sql"`.
   - `"result":"ok"`: the database exists from an earlier Add. Keep it; do not create it again.
   - Refused with `wrong_schema_version` (a new, empty file): create the tables with `sqlite3 -bail "<db_path>" ".read references/schema.sql"`. It prints `schema version 1 created`. Run the setup check again; it must end with `"result":"ok"`.
   - Refused with `sqlite_older_than_3_38` or `sqlite_without_sha3`: tell the owner to install sqlite3 3.38 or newer and stop.
2. Run `add-repo` for each repository in settings.md (triage-loop.md, "Commands").

## First run

1. Run one pass as triage-loop.md, "Scheduled run", with run-start kind `manual`. The owner approves the fetch and SQL commands as they come up ("Always allow here" for those, as above).
2. Run the setup check again.
   - Refused with `token_lacks_alert_access`: its `access` list is not shown on a refusal, so show the digest's "What could be read" lines. For each repository with `no_access`, tell the owner they need a role that can see security alerts there (admin, security manager, or chosen by an admin) and the scope above. They can fix it or remove the repository from settings.md; then run the pass again.
   - A source that is `disabled` is not an error. Tell the owner where to turn it on if they want it: the repository's Settings, in its security section (named Code security or Advanced Security, depending on the GitHub plan and date).
3. Show the digest. Point out any requests and their exact commands, and say that answering them is optional now.

## Turn on the schedule

Ask the owner to run, in a terminal:

```sh
openclaw automations list --agent <agent-id> --all
```

From the `Weekday triage` row, take its id as `<job-id>`, then:

```sh
openclaw automations edit <job-id> --cron "0 8 * * 1-5" --tz <time zone>
openclaw automations enable <job-id>
```

Runs land in this agent's own conversation. To also get the digest in a chat app: `openclaw automations edit <job-id> --delivery-target owner`. `openclaw automations disable <job-id>` stops the schedule; `paused: true` in settings.md makes runs end at once.

## Finish setup

When the schedule is on (or the owner said to wait), ask the owner to remove this file, so OpenClaw stops treating setup as pending:

```sh
rm "<workspace>/BOOTSTRAP.md"
```

The setup notes stay in docs/README.md.
