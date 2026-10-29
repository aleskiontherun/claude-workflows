---
name: wf-implement
description: Implement a task, feature or fix in the current project, then hand off to the wf-review-loop skill to get it independently reviewed and readied as a PR for the human's final review and merge. Use whenever the user asks to implement, build, add or fix something that should go through a real implement-review-fix loop -- any PR-sized coding task, not just a step of a larger plan. Do NOT use it to put a trivial one-line fix through review.
---

# Implement, then review

Implements what the human asked for, then hands off to `wf-review-loop`, which has it
reviewed by an independent subagent, fixed up, and readied as a PR. This file covers only
the implementing; the review protocol is that skill's, and is not summarised here because a
summary is a copy nothing keeps in step.

## The protocol

1. **Work out which repo you're in, first.** The change belongs to the repo that contains
   the files it touches — resolve it, since checkouts can nest
   (`~/.claude/wf/reference/workspace.md`). Branch and commit inside that repo, cutting the
   branch from a freshly fetched `origin/<default>` (the local default branch when the repo has
   no remote) — or, when you were handed a branch and
   worktree for this work, use those as given — and stage explicit paths rather than
   `git add -A`, which in a directory with nested checkouts can pick one up as a stray
   gitlink. A repo that takes no PRs — a workspace or plans repo, or one with no GitHub
   remote — still goes through review; `wf-review-loop` step 0.1 says what its no-PR mode
   drops.

2. **Read before writing.** `~/.claude/wf/reference/project-docs.md` says which files carry
   this project's rules and how to treat each — `AGENTS.md` and `CLAUDE.md` with their
   imports, `CONTRIBUTING.md` for checks, the decision record, `README.md`. Read the
   instruction files; grep the decision record for whatever you are about to touch, and
   append to it only where the project's docs say entries belong. Where a repo ships none
   of these, that may be a decision rather than a gap: take its conventions from the code
   and what it does ship, and don't add the files.

3. **Implement the work**, following the conventions already in the code. Commit as you
   go. **When you change a number** — a limit, a size, a count — grep for the old value
   before you hand over: docstrings, comments, test names and docs will have copies, and a
   figure restated away from what it counts gets a second place to be wrong.

4. **Follow `wf-review-loop` for everything after that**: its pre-review gate, invoking the
   reviewer, validating and fixing what it flags, capping the loop, opening the PR, and
   stopping for the human. Invoke the skill rather than working from memory of it, and use
   it as written — including its rule that the reviewer is told nothing about the change.
   You wrote this code; you are exactly the party that shouldn't frame its review.

## If this depends on another repo

If the human's instructions name a contract from another repo's change — an endpoint this
frontend work calls — treat it as fixed input, not something to re-derive. If they haven't
given one and the work clearly depends on another repo, ask for it rather than guessing.

Don't work across two repos in one session. A task needing changes in two repos is two runs
of this skill, each in its own session and its own repo; `cd`-ing between repos in one
session reliably produces more confused, more expensive, worse work than running it twice.

## What this skill is not for

- Chaining into another task once this one is handed off. One task is one full pass
  through implement and review, then a full stop.
- Being a conductor's implementer. Nodes `wf-conduct` launches follow
  `~/.claude/wf/reference/implementer-protocol.md`, which enters this skill itself. A hand-off
  from `wf-verify-plan` is ordinary work for this skill.
