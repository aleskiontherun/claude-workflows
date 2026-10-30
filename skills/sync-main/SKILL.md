---
name: sync-main
description: Bring the latest default branch (main) into a branch that is still in flight, resolve the conflicts, and re-check the branch's own work against what just arrived. Use whenever the user asks to update from main, sync or refresh a branch, pull in main, fix a PR that has gone stale or shows conflicts, or check whether in-progress work still holds after main moved. Not a first review -- that is review-loop.
---

# Sync with main

Merges the current default branch into a branch that isn't finished, resolves what
conflicts, and then does the part git can't: re-checks the branch's own work against what
arrived. The dangerous drift is never the kind that conflicts. Git only refuses when two
sides edited the same lines; a new file of yours calling a function the default branch just
renamed merges cleanly, and the first thing to notice is CI, or nothing.

It doesn't implement features and doesn't merge PRs. It ends by handing back to
`review-loop`. `${CLAUDE_PLUGIN_ROOT}/reference/workspace.md` defines the repo, nesting and
default-branch terms used below; "main" means the repo's default branch.

## Step 0: find the actual working copy

1. **Pick the repo and resolve `$MAIN`** — `origin/<default>`, per `workspace.md`. A repo
   with no remote uses its local default branch and skips the fetch.

2. **Find the worktree the branch is checked out in**: `git -C <repo> worktree list`.
   Three traps, each ending with you syncing something other than what you were asked to:
   - **Read the branch from the brackets in that listing, never from the directory name**;
     the two drift.
   - **A detached HEAD names no branch.** Gate on `git -C $REPO symbolic-ref -q HEAD`; if
     it exits non-zero, merging there advances HEAD and leaves the branch ref behind,
     silently. Confirm the sha matches the branch and re-attach with
     `git -C $REPO checkout -B <branch>`, or stop and ask.
   - **The branch may be in no worktree at all.** Then
     `git -C <repo> worktree add <path> <branch>` makes a fresh one for it. Use the main checkout only if `git -C <repo> branch --show-current` proves
     something disposable is checked out there, and never leave the default branch sitting
     on a merge made for another branch.

   Set the resolved path as `$REPO` and run `git -C $REPO …` throughout. Git refuses to
   check out a branch already checked out elsewhere; the plausible recovery — merging in the
   main checkout instead — merges into the default branch and leaves yours untouched.

   **`$REPO`, `$MAIN` and `$BASE` are values to write down, not shell variables**: nothing
   carries a variable from one Bash call to the next, so substitute the resolved value into
   each command.

3. **Refuse a dirty tree.** `git -C $REPO status --porcelain` must be empty, disregarding
   untracked nested checkouts (`workspace.md`). Stop and tell the human rather than
   committing or stashing for them: a stash popped on top of a resolved merge is a second
   conflict resolution layered over the first.

## Step 1: look at what's arriving, before merging it

```bash
git -C $REPO fetch origin            # skip with no remote
BASE=$(git -C $REPO merge-base HEAD $MAIN)
git -C $REPO log --oneline $BASE..$MAIN
git -C $REPO diff --stat $BASE..$MAIN
```

An empty range means the branch is already current: say so and stop.

**Keep `$BASE`** — run that block as one call and write the sha down. The merge moves the merge-base to `$MAIN`, so these commands re-run
afterwards return nothing; that sha is the only way back to what arrived, and step 3 needs
it. Read the log rather than skimming it — resolving conflicts without knowing what the
other side meant is how a resolution ends up syntactically fine and semantically wrong.

## Step 2: merge — don't rebase

`git -C $REPO merge $MAIN`.

Merge is the default for two reasons. Repos that squash-merge PRs never carry branch shape
onto the default branch, so a linear branch buys nothing. And a rebase needs a force-push,
which rewrites the shas `review-loop` recorded to scope its rounds, leaving its next range
pointing at commits that no longer exist; a merge disturbs that scoping recoverably (step 5).
Rebase only if the human asks by name, or the repo's own docs require a linear history.

Conflict classes where the obvious resolution is wrong:

- **Lockfiles** — `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `uv.lock`,
  `poetry.lock`, `Cargo.lock`, `Gemfile.lock`, `go.sum`. Never hand-merge one: it can be
  internally consistent and still not describe what the manifest asks for. **Resolve the
  manifest first** — regenerating against an unresolved manifest launders the conflict into
  the lock. Then take main's lock and regenerate it with the project's own tool
  (`git -C $REPO checkout $MAIN -- <lockfile>`, then `npm install`, `uv lock`, `cargo update -w`, …
  as `CONTRIBUTING.md` says).
- **Database migrations** — Alembic, Django, Rails, Prisma, Knex, Flyway and the like. They
  usually merge *clean* and are broken anyway: if main added a migration with the same
  parent as yours, there are now two heads, or two migrations with clashing sequence
  numbers. Re-parent or renumber **yours** onto main's latest rather than adding a merge
  migration, unless the project's docs say otherwise — yours is still on an unmerged branch
  and has run nowhere that matters. Then verify with the tool's own check (one head,
  `check`/`status` clean), and **mind the local database**: it very likely already sits at
  your revision because you applied it while writing it, so "upgrade to head" silently skips
  main's migration. Rebuild the local database from scratch where its data is disposable,
  and ask before touching one whose data isn't.
- **Append-structured docs** — decision records, changelogs, `CONTRIBUTING.md`. A conflict
  is two additions at one anchor, not a disagreement: keep both sides and fix the ordering.
  Picking one silently deletes someone's write-up.
- **Generated files** — snapshots, codegen output, API clients, bundled assets. Regenerate
  from the resolved sources rather than merging the output.
- **Anything you can't resolve from the diff alone.** `git -C $REPO merge --abort` and ask. An abort
  costs nothing; a guessed resolution is invisible afterwards, because the merge commit shows
  the result and never the choice.

Commit the merge.

## Step 3: re-check your own work against what arrived

The step this skill exists for. Everything here merges cleanly and breaks anyway.

1. **Callers of what main changed.** From `git diff $BASE..$MAIN`, list what was renamed,
   removed or re-signatured, and grep the branch's *own* side for each:
   `git diff $MAIN...HEAD` (three dots) is your side alone.
2. **Conventions that moved under you.** If the incoming diff touched any file
   `${CLAUDE_PLUGIN_ROOT}/reference/project-docs.md` lists — instruction files, `CONTRIBUTING.md`, the
   decision record — read those hunks and check the branch still complies. A rule that
   changed while you worked shows up in no code diff.
3. **Cross-repo contracts.** If a sibling repo this one talks to moved an endpoint or a
   shape, nothing in this repo's diff mentions it. In a sync the change has already landed
   there, so read the sibling (`git -C <sibling> log --oneline`, then its diff) rather than
   asking. Reading one repo while editing another is fine. Escalate only if the intended
   contract is genuinely ambiguous.
4. **Work main already did.** Main may have added the helper, migration or component you
   were halfway through. Two implementations of one thing merge perfectly; prefer main's
   and delete yours.

## Step 4: re-run the repo's checks, and get them green

`project-docs.md` says where the commands come from. Two things make a green run a lie:

- **A worktree has no untracked env files.** Gitignored `.env` files and local config never
  follow a `git worktree add`; tests that need them skip or fall back silently. Copy them in
  from the main checkout (or from the committed `.example`) before believing any result.
- **A dependency change needs reinstalling or rebuilding.** New packages mean
  `npm ci`/`uv sync`/the project's equivalent, and a containerised service needs its image
  rebuilt, not restarted — a restart reuses the old dependencies quietly.

Commit fixes from steps 3 and 4 **separately from the merge commit**, so the drift repair
stays legible.

## Step 5: hand back

- Push. Check for a PR (`gh pr list --head <branch>`, with `-R` where needed —
  `workspace.md`); if one exists and the change's scope moved, update its body with
  `gh pr edit --body …`, written as if just created. Don't comment on the PR and don't add a
  "merged main" note. In a repo that takes no PRs: push, and say so.

**A sync always leaves something for `review-loop`**, and two facts have to be said out
loud because neither is inferable from the diff:

- *That a merge happened.* A merge commit drags everything main added into the narrow range
  `review-loop` would use next, so a loop resumed after this sync takes its third
  full-range exception — say so, and give the range (`$MAIN...HEAD`, three dots).
- *What you resolved by hand.* Conflict resolutions live inside the merge commit and are the
  highest-risk lines the operation produces. A merge that applied without conflicts and
  changed nothing in steps 3–4 needs no new round; anything resolved or repaired does.

Report what came in, what conflicted and how you resolved it, and anything step 3 turned up
that git had merged clean. Don't merge the PR; don't pick up the next task unasked.

## What this skill is not for

- The first review of a branch — `review-loop`.
- Syncing several branches in one pass — each has its own worktree and checks; one run each.
- Rewriting history — no rebase, squash or force-push unless the human asks by name.
- Merging or closing the PR — always the human.
