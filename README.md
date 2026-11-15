# OpenClaw Templates

Source for OpenClaw Templates by anmol0b. Nothing here is published on ClawHub yet.
A Template is a package that `openclaw templates add` turns into a new, ordinary OpenClaw agent.

Each folder under `templates/` holds one Template, with the package source at its root.
`tests/` holds its tests and is left out of the published package.

## Templates

| Template | Package | Folder |
|----------|---------|--------|
| Repo Maintainer Helper | `@anmol0b/repo-maintainer-helper` | `templates/repo-maintainer-helper/` |

## Check a Template locally

You need OpenClaw with the `templates` command, Node 22 or newer, and sqlite3 3.38 or newer with FTS5.

```sh
cd templates/repo-maintainer-helper
openclaw templates validate .
openclaw templates dev .
zsh tests/steps.test.sh .
zsh tests/approvals.test.sh .
node tests/fetch.test.mjs .
```

## License

MIT. See [LICENSE](LICENSE).
