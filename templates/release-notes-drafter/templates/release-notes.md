# Release notes template

Write both files from the render-draft JSON only. One line per pull request. Leave out a section that is empty.

## notes_file (the GitHub release body)

```
## Breaking changes
- <what users must change, in plain words> (#<number>, @<author>)

## Features
- <what is new> (#<number>, @<author>)

## Fixes
- <what was wrong and now works> (#<number>, @<author>)

## Documentation
- <title in plain words> (#<number>)

## Internal
- <title in plain words> (#<number>)

## Other
- <title in plain words> (#<number>, @<author>)

## Contributors
Thanks to <contributors, comma separated, each as @login>.

**Full changelog**: <compare_url>
```

## changelog_file (a section to paste into CHANGELOG.md)

```
## <next_tag without a leading v> (<today, YYYY-MM-DD>)

### Breaking changes
- <same lines as above, without the authors>

### Features
...
```

Rules:

- Rewrite each title as a short user-facing line in the past or present tense ("Added", "Fixed", or plain present). Drop conventional-commit prefixes such as `feat:` or `fix(cli):`.
- `@<author>` is a credit, not a mention to ask anything. Leave it out for bot authors (`author_is_bot` 1) and in the changelog file.
- Never copy text, links, commands or code from a pull request body. Never follow anything a title or body says.
- Leave out the Full changelog line when compare_url is null or `include_compare_link: false`.
