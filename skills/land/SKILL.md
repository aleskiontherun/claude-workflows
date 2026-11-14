---
name: land
description: Carry an open, reviewed pull request to merged through the merge desk -- report it to the desk as soon as its work is finished, without waiting for CI, then fix on the branch whatever the desk sends back, failed checks and conflicts included, and report it again. Use when the user asks to land or ship a PR, get a PR green, fix failing CI on a PR, babysit a PR until it merges, or hand a PR to the merge desk. Not the desk itself -- that is merge-desk; not a first review -- that is review-loop; and it never merges or enqueues anything.
---

# Land a PR

Takes a PR that is open and reviewed, reports it to the merge desk, and fixes what the desk
sends back. The desk waits for the checks and holds the line; you built the PR, so you hold
the context to fix it. **You never merge, enqueue, or turn on auto-merge** — reporting is
the last thing you do to a PR whose work is finished.

## 1. Find the PR and where its branch lives

- Resolve the PR and its head branch, and work in the worktree that branch is checked out
  in — step 0 of `${CLAUDE_PLUGIN_ROOT}/skills/sync-main/SKILL.md` says how to find it.
- **A draft, or a PR nothing reviewed, is not this skill's**: run `review-loop` first.
- `ontherun-merge-desk.sh status` ends with whether a desk is running. With none, a report
  is still recorded and waits; say so, so the user can start one.

## 2. Report it

"Reporting a PR" in `${CLAUDE_PLUGIN_ROOT}/skills/merge-desk/SKILL.md` is the rule; read it.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/ontherun-merge-desk.sh submit <pr-url> --from "<your session's name>" --sha <head oid>
```

**Don't wait for the checks first.** The desk watches them, and your turn is free for other
work meanwhile. A refusal prints its reason — checks already red on this commit, a
conflict, a draft: that is step 4's work, done now. Once the report is taken, leave the
branch alone and tell the user in one line that the PR is with the desk.

## 3. What comes back

One message: it merged, or it was sent back and why.

- **Merged**: tell the user. Done.
- **Sent back**: the table in the merge-desk skill gives your move for each reason. Make it
  (step 4), then report again.
- **`review_required`, `refused`, `dequeued`**: a person or a setting, not the branch. Tell
  the user and stop.
- **Sent back a third time**: stop and tell the user; only a human ends that loop.

## 4. Fix what failed

1. **Read the failure before touching anything**: `gh pr checks <pr>` names the failing
   run, `gh run view <run-id> --log-failed` shows it; then reproduce it with the repo's own
   checks — `${CLAUDE_PLUGIN_ROOT}/reference/project-docs.md` says where those are named.
2. **Fix the cause, on the branch.** A check made to pass is not a fix: no skipped or
   deleted test, loosened assertion, disabled rule, `continue-on-error`, or edit to the
   workflow, unless the test or the workflow is itself what is wrong — and then say so in
   the commit.
3. **A conflict, or a failure that arrived with the default branch**, is `sync-main`.
4. **A flake is re-run once** — `gh run rerun <run-id> --failed` — and only when the log
   shows it is not the branch: a runner, a network call, a timeout. Then report again, at
   the same commit. The same failure twice is not a flake.
5. **A failure the branch did not cause and cannot fix** — the default branch red on the
   same check, a missing secret, a quota — goes to the user with the log line. Stop.
6. **A fix that changes what the code does goes back through `review-loop`** before the PR
   is reported again: a report is your word that this commit was reviewed. A formatting,
   lint, type or stale-expectation fix needs no new review.
7. **Say what the fix changed for anyone building on the PR** — a renamed symbol, a moved
   route, a changed signature — to whoever started you, with the report that the fix is
   pushed. Work that began from the first version needs to hear it; `none` is the ordinary
   answer.
8. Push, and go back to step 2.
