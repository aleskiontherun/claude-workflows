# Walking a plan's `## Verification` scenarios

**A reference file, not a skill.** `conduct` §6 runs this once, after a plan's last PR has
merged — the first moment the app can do what the plan describes, with the ordinary checkouts
serving it: no worktree stacks, no port arbitration. Nothing else walks these scenarios;
implementers run the suite and the checks (`conduct` §3). `plan-format.md` says what a
scenario is and when a plan owes one.

Bring the app up the way the project's docs say (`project-docs.md`).

## Three checks before you touch a browser

Each has produced a walk reporting an application defect that didn't exist:

1. **Is anything actually being served?** Check what is listening on the ports the project
   documents, not what containers or processes exist — a sibling session's test stack can look
   healthy and publish nothing.
2. **Is every serving checkout at the default branch?** A dev server serves its checkout's
   working tree, and nothing maintains the shared checkouts. Both directions must be zero, and
   the tree clean:
   ```bash
   git -C <repo> fetch -q origin
   git -C <repo> rev-list --left-right --count origin/<default>...HEAD   # must be 0<tab>0
   git -C <repo> status --porcelain                                     # must be empty
   ```
   Ask it of every repo the app runs from. A checkout *ahead* is someone's unmerged work — take
   it to them rather than moving it. A mismatch presents as a defect on the side that's
   *correct*: a frontend on new code against a backend still serving the old shape renders
   blank.
3. **Is derived state current?** Database migrations at head, dependencies reinstalled after a
   manifest or lockfile change, caches and generated files rebuilt — whatever the project's docs
   say the app needs after a pull. Read the commits you just moved through for what changed.

**Then run all three again and read them.** A restart that was supposed to settle a migration
can fail and leave the service listed but not serving. Where the plan changed an API contract,
confirm the running service advertises the landed shape before trusting anything a browser
shows.

## Scenarios that mutate the running app

The running app is the human's. Prefer a probe that exercises the same code path without a
restart, and say it's the variant you ran. Where a restart is the only honest test, announce
what you're bouncing, restore the exact prior configuration, and confirm it serves before
moving on.

## What a failure is

A finding for the human, never a reason to invent a fix: if they want it fixed it is a new node
and a new wave, and the plan doesn't move to `done/` until the scenario holds. Judge severity by
what it does to the project's users, not as survivable by default. The outcome of every
scenario — which ran, against which commits, what each showed — goes into the Status prose at
close-out; `## Verification` itself is never appended to.
