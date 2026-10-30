---
name: verify-plan
description: Check whether a plan actually landed on the default branch, rewrite its Status block from what the code says, and move it to the plans directory's done/ once it is fully shipped. Whatever is missing becomes a self-contained hand-off for an implementer in the repo that work lands in. Use when the user asks whether a plan is done, to verify or close out a plan, to file one under done, or to get the unfinished half of one picked up.
argument-hint: "[plan name]"
---

# Verify a plan, then file it or hand off the rest

The rule: **verify by re-reading the tree, not by trusting commit messages, PR titles, or the
plan's own confidence.** A merged PR named after the plan is a place to look, never proof.
A finding that can't be pointed at a file and line doesn't go in the Status block.

The shared references live in `${CLAUDE_PLUGIN_ROOT}/reference/`: `workspace.md` for
the workspace root, the plans repo and node repos, `plan-format.md` for the plan and its Status
block, `project-docs.md` for where each repo's rules and check commands live. Work from the
workspace root; repo paths are relative to it, and `gh` always gets `-R` or runs inside the
node repo.

## 1. Pick the plan

Match the user's words against the plans directory. With no plan named, list the active plans
with their Status lines and ask which; nothing matching, or two, means list and ask. Plans in
`done/` are revisited only when the user explicitly asks.

Detect the non-plans by **shape, not filename**:

- **A strategy document** — no `**Status:` line anywhere. It never ships and never moves. Say
  so and stop.
- **A `DRAFT` marker in the Status.** Verifying is fine and the answer is usually "nothing
  landed", but a hand-off needs the user's go-ahead (§7).

## 2. Turn the prose into claims

Plans are prose, so build the checklist yourself before touching code. Extract every
concretely checkable artifact — files and symbols, endpoints, columns and enum values, response
shapes, user-visible copy, tests the plan asks for, decision-record entries it promises — and
the **negative** claims: what should be *deleted*, which are the ones most often left half-done.

Note the anchors it was written against ("against api `e0fc68c`"), its sequencing ("API
first" is checkable), and its open questions and owner calls — those aren't gaps, they're
questions for the user, and §8 keeps them intact.

## 3. Establish the ref before grepping anything

The working tree is not the default branch, and often isn't on it. Grepping the checkout can
call a plan shipped on the strength of a feature branch. So first, per node repo:

```bash
git -C <repo> fetch --quiet origin
git -C <repo> rev-parse --abbrev-ref HEAD
git -C <repo> status --porcelain
git -C <repo> rev-list --left-right --count origin/<default>...HEAD
```

Then verify against `origin/<default>` itself: `git -C <repo> grep -n '<symbol>' origin/main --`
and `git -C <repo> show origin/main:<path>`.

**An artifact that exists only in the checkout is not landed.** It gets its own class in §5
and never triggers the move. Report the branch it's on — useful news, not a failure.

## 4. Verify each claim

Grep for each artifact, then read enough around it to know it does what the plan said, not
merely that the name exists. Grep the negative claims too: a leftover call to something the
plan removed means it didn't fully land. Search the whole tree when a claim doesn't turn up
where you expected — data-access layers, hooks and contexts are easy to forget and are exactly
where some plans live. A repo with no source tree verifies in the files it does carry: docs,
compose files, workflows, example config.

What gets missed more often than the code:

- **Schema.** Where the repo uses a migration tool (`project-docs.md` says where to find out),
  a promised schema change has a migration to find, and the migration is the artifact to
  verify, not only the model. A live database check runs only through a command the project
  documents; **if it errors instead of answering, the database was unreachable — that is
  *unverified*, not a gap.** Never hand off on it.
- **Decision-record entries.** Plans promise them. Grep each touched repo's record for the
  section; a missing one is a small real gap (§10). What you're looking for is the reasoning
  written out — an entry that merely links to the plan is a defect (`workspace.md`), not the
  promised entry.
- **Tests the plan named.** Confirm they exist *and* assert what the plan said they'd pin — a
  test with the right name asserting something else is a deviation.
- **Suites, only at the end**, when you're about to call it shipped, with each repo's own
  commands and every environment caveat its docs state — a suite that skips itself silently
  proves nothing.

`gh pr list -R <owner>/<name> --state merged --search '<term>'` is for *citations* — the
numbers, titles and shas the Status block carries — after the code has already convinced you.

## 5. Classify every claim

- **landed** — present on `origin/<default>`, doing what the plan said.
- **landed but not merged** — present in a checkout only. Name the branch, and whether it's
  committed or a dirty tree.
- **landed with deviation** — say which: *better*, *neutral* or *worse*.
- **missing.**
- **no longer applicable** — overtaken by other work.

## 6. Verdict

| Where the claims sit | Verdict | What happens |
| --- | --- | --- |
| All landed (+ better/neutral deviations), any rest no longer applicable | **Shipped** | Rewrite Status, move to `done/` |
| Any *worse* deviation | **Shipped with a regression** | Rewrite Status, **no move**; ask, or hand off the regression |
| Anything landed but not merged | **Awaiting merge** | Rewrite Status naming the branches; **no move, no hand-off** — the work exists |
| Some landed, some missing | **Partial** | Rewrite Status, stays, hand off the rest |
| Nothing landed | **Not started** | Rewrite Status, stays, hand off (subject to §7) |
| All claims no longer applicable | **Overtaken** | Report and ask; neither `done/` nor a hand-off is right |

## 7. Show the user before writing anything

Print the classification table and the **proposed Status text**, then wait for a go-ahead
before any edit, move or hand-off. Plans are long hand-written documents and the rewrite is not
cheap to undo. This is also where a `DRAFT` plan's hand-off is approved or declined — say
plainly whether it reads implementable as it stands.

## 8. Rewrite the Status block

**Replace exactly one thing: the Status block** — the paragraph beginning `**Status:` and the
ledger under it. Everything else between the `#` title and the first `##` is preserved
verbatim: owner decisions and forensics live there. On plans with a `## State` block, leave the
block alone — it's owned by `conduct`, and this skill's job is to establish what landed
independently of it. If the old Status carries history the new one drops, move it into
`## Review history` (round narrative) or the preamble's owner decisions (a ruling) rather than
losing it.

Don't append a second Status, don't add a bottom verification section, don't retitle the plan.
Resolve the date with `date +%Y-%m-%d`.

**Take the shape from `plan-format.md`, not from a plan on disk** — older plans in `done/` may
predate it. Keep the sentence naming the exit that promoted the plan. On a plan with a
`## State` block the ledger is only ever regenerated —
`${CLAUDE_PLUGIN_ROOT}/bin/wf-plan-ledger.sh <plan> --write` — and only from a block that matches what
you found. Where the block disagrees with the tree, that is the finding: show it at §7. For a
**Shipped** plan, with the user's go-ahead, correct the block's `status`, `pr`, `sha` and
`merged` to the tree and regenerate — nothing will conduct it again. For any other verdict,
leave the block and its ledger alone, say in the prose where they disagree with the tree, and
tell the user `/ontherun:conduct` reconciles it. A plan without nodes has a hand-written ledger keyed
by repo and PR.

Don't restate PR numbers or shas in the prose; they're in the ledger. The **evidence list** —
one bullet per repo, citing `file:LINE` — sits after the prose. Be specific and honest:
"shipped as planned" is a claim, and if two details drifted, say which two. For a partial, lead
with what's missing. A multi-phase plan may also mark its phase headings `— **SHIPPED**` and
carry a `## Deviations from the plan, worst first` section near the top.

## 9. Move it — only on a clean **Shipped**

In the plans repo, which tracks the plans directory (`workspace.md`):

```bash
git -C <plans repo> ls-files --error-unmatch <plan> || git -C <plans repo> add -- <plan>
mkdir -p <plans>/done
git -C <plans repo> mv <plans>/<name>.md <plans>/done/<name>.md
```

Then repoint what the move broke, **within the plans directory only**
(`git -C <plans repo> grep -n "<name>\.md" -- <plans>`): repoint each to `done/<name>.md`, or
annotate it.

**Don't grep the node repos for plan references, and never repoint one there.** A reference to
a plan from a node repo is a defect to remove (`workspace.md`), not a link to maintain; if you
happen to see one, report it as a gap.

Leave everything staged; commit only if the user asks. Then **commit by pathspec** —
`git -C <plans repo> commit -m "…" -- <paths>` — never a bare `git commit`: other sessions may
have staged their own files in the same index, and a bare commit sweeps them into yours. Never
`git add -A` in a directory with nested checkouts.

## 10. Hand off whatever is missing

Not every gap is a hand-off. Sort them first:

- **Code gaps** → one hand-off per repo with work left.
- **A migration that exists but isn't applied locally** → not a hand-off: it is local machine
  state with no diff, and an implementer would open an empty PR. Give the user the command the
  project documents for applying it.
- **A missing decision-record entry alone** → fold it into that repo's code hand-off, or
  report it. Never its own hand-off.
- **Work in a repo that doesn't exist yet** → a blocker for the user.

A hand-off is a **self-contained prompt** for a session started in the node repo — the spawned
session sees none of this conversation. Include:

- the **absolute path** to the plan and the exact sections that are its half;
- **what already landed**, with `file:line`, so it isn't redone;
- **what's missing**, with the evidence (the grep that came back empty);
- **ordering**, when one repo's half must land before another's — in *every* hand-off;
- the PR title, and that the decision record gets the *why*;
- **"use the `implement` skill"**, so it goes through review;
- **"when the PR is merged, ask the human to re-run `/ontherun:verify-plan <name>` from the
  workspace root"** — nothing else closes the loop.

Where the environment can start a separate session (the desktop app's session tools), propose
one per hand-off with its working directory set to that repo, a title under 60 characters
naming that repo's half, and the prompt as its brief. Otherwise print each prompt for the user
to paste. Record in the new Status that a hand-off was made and for what, so the next run
doesn't duplicate it.

Don't hand off the plan's open questions or owner calls, or work it sequences for later — those
go to the user as questions. Having handed off, don't also start implementing here unasked.

## Output

Lead with the one-line verdict from §6. Then a compact table of claim → class → evidence,
deviations called out separately, then what changed on disk (the Status rewrite, the move, any
references repointed), then the hand-offs and what each covers. Anything you couldn't verify —
an unreachable database, a suite you didn't run — said plainly rather than assumed.
