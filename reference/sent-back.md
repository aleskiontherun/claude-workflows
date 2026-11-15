# A PR the merge desk sent back

What the session or agent that built a PR does when the merge desk answers its report. The
desk itself, how to report, and the move each reason asks for are in the merge-desk skill,
`skills/merge-desk/SKILL.md` under the plugin root (the parent of this file's `reference/`
directory). Whoever built the PR fixes it: it holds the context, and two parties pushing to
one branch collide. **Nobody here merges, enqueues, or turns on auto-merge** — reporting is
the last thing done to a PR whose work is finished.

## What comes back

One message per report: it merged, or it was sent back and why. `submit` refusing a report
counts as sent back, with the reason it printed.

- **Merged**: tell whoever started you. Done.
- **Sent back for something the branch can fix** — `checks_failed`, `conflict`,
  `head_moved`, `draft`, `timed_out`: fix it as below, then report again.
- **`review_required`, `refused`, `dequeued`**: a person or a setting, not the branch. Tell
  whoever started you, and stop.
- **Sent back a third time**: stop and say so; only a human ends that loop.

## Fixing it

1. **Read the failure before touching anything**: `gh pr checks <pr>` names the failing
   run, `gh run view <run-id> --log-failed` shows it; then reproduce it with the repo's own
   checks — `project-docs.md` beside this file says where those are named. A failure from
   inside the queue ran on the queue's merge of the PR with those ahead of it, not on the
   PR's own head.
2. **Fix the cause, on the branch.** A check made to pass is not a fix: no skipped or
   deleted test, loosened assertion, disabled rule, `continue-on-error`, or edit to the
   workflow, unless the test or the workflow is itself what is wrong — and then say so in
   the commit.
3. **A conflict, or a failure that arrived with the default branch**, is the sync-main
   skill.
4. **A flake is re-run once** — `gh run rerun <run-id> --failed` — and only when the log
   shows it is not the branch: a runner, a network call, a timeout. Then report again, at
   the same commit. The same failure twice is not a flake.
5. **A failure the branch did not cause and cannot fix** — the default branch red on the
   same check, a missing secret, a quota — goes to whoever started you with the log line.
   Stop.
6. **A fix that changes what the code does goes back through the review-loop skill** before
   the PR is reported again: a report is your word that this commit was reviewed. A
   formatting, lint, type or stale-expectation fix needs no new review.
7. **Say what the fix changed for anyone building on the PR** — a renamed symbol, a moved
   route, a changed signature — to whoever started you, with the word that the fix is
   pushed. Work that began from the first version needs to hear it; `none` is the ordinary
   answer.
8. Push, and report the PR again at the new head.
