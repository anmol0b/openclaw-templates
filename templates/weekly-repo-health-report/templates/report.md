# Report template

Write the report from the digest step's JSON only, one section per entry in `reports`. Keep it short.

Show a change as `(+n)` or `(-n)` after the number, from `deltas`. When `deltas` is null, write no changes at all and put `baseline_note` under the heading instead. Hours are medians. A rate change is in points (`75% (-5 pts)`).

```
Repo health, week <week> (<window_start date> to <window_end date>)

<repo>
<baseline_note, only when deltas is null>
<"Settings changed since last week, so some changes are not like for like." only when settings_changed is true>
- PRs: <prs_opened> opened, <prs_merged> merged, <prs_closed_unmerged> closed without merging
- Review: first review after <review_hours_median> h, merged after <merge_hours_median> h (medians); <merged_without_review> merged with no review
- Slowest merges: #<number> <merge_hours> h, ...
- Issues: <issues_opened> opened, <issues_closed> closed
- Open now: <open_prs> PRs (<open_draft_prs> drafts, <stale_prs> idle <stale_pr_days>+ days), <open_issues> issues (<stale_issues> idle <stale_issue_days>+ days)
- CI on the default branch: <ci_pass_rate>% passing (<ci_passed> passed, <ci_failed> failed, <ci_other> cancelled or skipped)
- Partial: <which reads were cut>, so <those numbers> may be low

Not reported: <each repo in missing>, <each line of the run's note>
```

Rules:

- A null median or rate is written as `none this week`, never as 0.
- `issues_enabled: 0` means the repository has issues turned off: write "Issues: turned off" instead of the issue numbers.
- Leave out the Slowest merges, Partial and Not reported lines when they are empty.
- PR numbers are the only identifiers in the report. Never add titles, authors or anything not in the digest.
- No advice that reads like a finding the numbers do not show. One plain sentence at the end naming the biggest change is fine when `deltas` is not null.
