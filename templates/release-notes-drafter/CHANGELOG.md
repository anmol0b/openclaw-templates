# Changelog

## 0.1.2

- Ships the Blobster as `assets/icon.png` so ClawHub shows it as the catalog icon. ClawHub does not build an icon from the Blobster SVG.

## 0.1.1

- The avatar and catalog icon is now a Blobster rendered with `openclaw agents render-blobster`. Its design is in `blobsters/release-notes-drafter.json` at the repository root.

## 0.1.0

First version.

- Finds each repository's base release (GitHub's latest, or the newest published one) and the pull requests merged into the default branch after its tagged commit, with one fixed read-only command per repository (`node references/fetch.mjs <owner/repo>`). The search date is computed inside, so the command never changes.
- Suggests a section for every pull request from labels and conventional-commit prefixes. The draft must place every pull request exactly once.
- Computes the next tag from the sections: breaking bumps the major (the minor while on 0.x, a setting), features the minor, anything else the patch. The owner can choose another tag; their words are recorded.
- Writes a release body and a changelog section as workspace files.
- The only write is a draft GitHub release, an owner approval for a command the database builds, bound to the same base release and newest merge the owner saw and to the exact bytes of the notes file. Used once; after the write it checks GitHub lists the draft.
- PR descriptions are off by default (`include_pr_bodies: false`); notes are drafted from titles, labels and authors. README and CLAW.md list what reaches the model.
