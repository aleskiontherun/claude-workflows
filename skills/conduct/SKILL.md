---
name: conduct
description: Conduct an approved plan to done -- verifying what has actually landed before acting on it, launching implementer subagents wave by wave across whichever repos its nodes land in, each as soon as what it needs is open and reviewed rather than merged, reporting each finished PR to the merge desk and relaying what it sends back, queueing the PRs the owner wants to merge by hand, and closing the plan out after the final merge. Use when the user wants a plan continued, picked up, resumed, a wave launched, a plan conducted, or a plan carried through to merged. Writing a plan, deepening a DRAFT or getting one reviewed is plan.
argument-hint: "[plan path]"
effort: high
---

# Conduct a plan to done

You are the conductor. You didn't write the plan and you don't write the code: you establish
what has landed, launch the implementers that build the rest, get each PR merged — through
the merge desk, or by the owner where they want to look first — and close the plan out. What you **don't** do yourself is whatever running the
work disqualifies you from judging: each node's code review belongs to its implementer's own
`reviewer` and `validator`, and final verification to a `verifier` that took no part.

The shared references live in `${CLAUDE_PLUGIN_ROOT}/reference/`: `workspace.md`
(workspace root, plans repo, node repos, `gh -R`), `plan-format.md` (the plan, the `## State`
block and its vocabulary), `plan-review-loop.md` (re-entered mid-flight in §4), and
`implementer-protocol.md` (what your implementers follow). Scripts are in `${CLAUDE_PLUGIN_ROOT}/bin/`.

**Work from the workspace root**, write repo paths relative to it as the plan does, and give
`gh` a repo every time — `-R`, or run it inside the node repo (`workspace.md` says why).

**This skill sets `effort: high` for all your turns in it; the model is the session's**, so
check it and say so before launching anything if the user asked for a tier this session isn't
on. Implementer model and effort come from each node's `agent` field (§3).

## 1. Work out whether this plan is yours

Ask only what the files can't tell you. Match the user's words against the plans directory;
with no plan named, list the active plans with their Status lines and ask which. Nothing
matching, or two, means list and ask.

Take the first row that matches:

| Situation | Go to |
| --- | --- |
| A file with no `**Status:` line anywhere | Stop — a strategy document |
| The Status carries the `DRAFT` marker, or the plan still has an `## Open questions for the detailing pass` section | `plan` §3 — hand it back |
| Every node is `pending` and the Status names no promoting exit — `sound`, `corrections_only`, or promoted by ruling | `plan` — hand it back; no review round has passed it |
| A `## State` block | §2, always first |
| No block, but a node list in its prose | §2 — `verifier` proposes a block and §2 writes it |
| Neither a block nor a node list | `plan` — hand it back; there's no DAG to execute |

Decide by opening the file, never by name. `<plans>/done/` is revisited only on request.

**Hand back rather than improvising the missing half**, and when a plan carries both a `DRAFT`
marker and a block, **the marker wins** (`plan-format.md`).

## 2. Picking up a plan

**Verify before you act. Never resume from the `## State` block alone** — it's a cache, and
the tree moves under it (`plan-format.md`, *The block is a cache*).

Spawn `verifier` (`subagent_type: ontherun:verifier`) with the plan path and the workspace
root, nothing else. It returns a
classification table, a proposed block and a verdict.

**One pickup needs no verifier: a plan promoted today that nothing has launched against** —
every node `pending`, no branch for any node on its repo's origin
(`git -C <repo> ls-remote --heads origin 'claude/<node-id>-*'`), and the promoting round
dated today in `## Review history` or run in this session. Treat it as `not_started` with the
block as it stands. Any branch, any status past `pending`, or an older promotion, and the
verifier runs.

| Verdict | What you do |
| --- | --- |
| `draft` | `plan` §3 — hand it back |
| `not_started` | Write the block from the proposal, show the wave plan, launch on approval |
| `partial` or `awaiting_merge` | Update the block. **Relaunch nothing that has a branch or a PR** — that work exists. Take §5 for the open PRs — report the desk's, queue the owner's, arm the monitor — then launch (§3) every `pending` node that can launch and has no branch. With nothing to launch, show §5's line per repo and, where a PR waits on the owner, ask them to merge it or say what's wrong with it |
| `regression` | One node scoped to the regression. Don't re-run the plan |
| `shipped` | §6 — close it out |
| `overtaken` | Report and ask. Neither `done/` nor a relaunch is right |

Write the verified block into the plan before launching anything, regenerate the ledger
(`ontherun-plan-ledger.sh <plan> --write`), and commit both by pathspec in the plans repo. A session
that dies here leaves the next one better off.

**Carry over the `delivered:` entries the plan already records** — the verifier omits that
field on purpose, and a block written straight from its proposal would erase the contract
surface of every node merged before this session. Carry over `merge:` and `base:` the same
way; a `base:` naming a node that has since merged is §5's "your base merged" to send.

## 3. Launching a wave

A wave is every `pending` node that can launch. Launch the whole wave **at once** — one
message, one `Agent` call per node — never one at a time.

**A node can launch when each of its `needs` is satisfied or open to build on.** Satisfied
is `merged`, `done` or `dropped`. Open to build on is a `pr` node that is `open` — its PR
exists and its review exited clean — and bound for the merge desk, with no send-back from
the desk still unanswered. Waiting for the merge would buy only CI and queue time per edge
of the DAG; what it would protect against, a late fix that changes the contract, is rare
and is forwarded when it happens (§4). Three limits:

- **At most one unmerged need in the node's own repo.** That one is the node's `base:` —
  its branch is where the new branch is cut from. With two, wait until one merges.
- **Never on a `merge: owner` node.** The owner has not looked yet, and what they ask for
  would land under everything built on it.
- **Never on a `blocked` or `draft-pr` node, or one whose PR the desk sent back** and whose
  implementer has not answered with a new `pr_opened`. Nodes already running on it carry on.

An unmerged need in another repo needs no base: its contract is read from its branch. The
owner can switch all of this off for a plan — "wait for merges" at the wave plan — and then
a node launches only when its `needs` are satisfied.

**`setup` nodes are yours**, done in this session alongside the launch; a `manual` node is said
to the owner once, with exactly what to do. When a `manual` node turns out to hold steps you
can take, take them and hand over only the rest. Run each node's `check:` before writing
`done`.

For each `pr` node:

- **`subagent_type` is the node's `agent` under this plugin's namespace** — `agent: implementer`
  spawns `ontherun:implementer` — which sets model and effort. Override `model` per call only
  when the user asked. **Choosing the tier is your judgment, and the plan's size estimate is
  not the input**: a node carrying what `implementer-high`'s description lists — a
  migration, an auth path, a data rewrite, a breaking contract, work the plan says can't be
  split — gets that agent, the rest `implementer`. Change the block's `agent` field rather
  than the call, and say which tier each node got and why when you show the wave plan — the
  gate where the human can disagree.
- **Where the node's PR goes is settled here**: to the merge desk, unless the node carries
  `merge: owner` (`plan-format.md`). Write `merge: owner` on a node the owner wants to look
  at before it merges, and on each node you give `implementer-high` — review is the only
  gate a desk PR passes, and those are the nodes where a mistake costs most. Say which
  nodes wait for the owner when you show the wave plan; the owner can flip either way.
- **Don't pass `isolation: "worktree"`.** It would make a worktree of the repo your session
  runs in, which in a workspace layout holds no node repo at all. Each implementer makes its
  own worktree inside its node repo (`implementer-protocol.md`).
- **Assign the worktree path and the branch, both in the prompt**, from one slug, in the forms
  `workspace.md` sets — the worktree path **absolute**, the branch `claude/<node-id>-<slug>`.
  You need the name before the implementer returns: the block records it while the node runs,
  and §5's monitor keys on it.
- **The prompt must stand alone** — the subagent sees none of this conversation. Give it: the
  absolute plan path and the workspace root, its node id and repo, the exact sections that are
  its half, what already landed (below), any ordering constraint, the PR title from the block,
  and the two names above.

  **For a node built on an unmerged PR, also give that PR's number and branch**, and say
  which case it is — its own repo, so the branch is its base, or another repo, so the
  branch is where the contract is read (`implementer-protocol.md`, *Building on an unmerged
  PR*). Write `base:` on a same-repo one as you launch it.

  **"What already landed" comes from its dependencies' `delivered:` lists**, never from the
  plan's prose (`plan-format.md` says why). For an unmerged dependency those lines are read
  on its branch, not the default one — say so. Hand those lines over as places to go read, naming
  the **symbol or section**, with the line range as a hint. On a pickup with no `delivered:`
  recorded, use `verifier`'s evidence list.

  **Don't ask it to run the plan's `## Verification` scenarios** — §6 does that once, after the
  final merge; concurrent implementers can't each hold a running app, and one that borrows the
  human's verifies the human's checkout. Its job is the suite and the checks.

**Bring §5's monitor up to date for each repo in the wave, in the same message that launches
it** — arm one for a repo that has none, otherwise `TaskStop` the existing one and arm its
replacement. This is the first moment the wave's branch names exist, and the monitor reports
nothing for a branch whose PR hasn't opened, so it costs nothing now.

Set each node to `running` **and write its `branch:`** as you launch, regenerate the ledger,
and commit. **Every status goes into the block, and the ledger is generated from it** — never
written by hand (`plan-format.md`). Then tell the user what's in flight and stop talking.

## 4. Handling what comes back

Each implementer ends with a fenced report whose first line is `RESULT:`.

**`RESULT: needs_input`** — its response carries a fenced `yaml` block of `questions`. Render
them with `AskUserQuestion` verbatim (the fields map one-to-one), then `SendMessage` the
answers back to that agent. It keeps its context; don't re-explain the task.

**`RESULT: pr_opened`** — record `branch` and `pr`, set the node `open`, regenerate the ledger,
commit. Copy its `DELIVERED` bullets into the node's `delivered:` and nowhere else — the ledger
stays one line per node. A report with `STACKED_ON: none` removes the node's `base:`. Then
§5: reported to the merge desk once every `needs` id is satisfied, or into the owner's
queue.

**A non-empty `DIVERGED` is a plan finding, due before the next wave launches.** The
implementer worked around a wrong sentence, which is exactly why this is easy to file and
forget. Correct the plan, note the deviation in the Status prose, and say the one line to the
human while the next wave is still unlaunched. **Correct every sentence the divergence made
wrong, not the built node's own section** — the build order, a sibling node's spec, prose a
later implementer will read as fact — sweeping with `ontherun-plan-fold-sweep.sh` as
`plan-review-loop.md`'s *Check the fold* says. **The same applies to an owner ruling you fold
in**: a ruling feels authoritative, which is when the sweep gets skipped.

**`fold-checker` runs on every mid-flight fold.** What's rationed is the whole-plan round:

- **The fold changed what an unlaunched node builds**, or repeated the wrong claim in one, or
  moved a `needs` edge or anything else in `## State` → **one `plan-reviewer` round before
  that wave launches**, over the whole plan, mechanical checks first over what the fold
  touched, the plan committed before the spawn. `corrections_only` is the ordinary outcome:
  fold and launch.
- **The wrong claim reached a node already launched and not yet merged** → no round;
  `SendMessage` the correction to that implementer, which still holds its context. It returns
  a second `pr_opened`.
- **The fold only corrected the built node's own section, background prose, or a citation
  nothing builds from** → no round. Say the line to the human and carry on.

**A mid-flight round routes by `plan-review-loop.md`'s *Mid-flight routing*, never by its
step 2**: demotion would strip a `## State` block that by now records merged nodes and their
shas. Launch nothing from a stopped wave, demote nothing, and merged nodes stay `merged`
whatever is decided.

**Don't notify here**; §5 owns notification.

**A second `pr_opened` from an implementer you resumed is not a new PR.** The node is already
`open` with that number; the head absorbed the default branch or its base's merge, or a fix
landed. A desk node
is reported again at the new head; an owner node's readiness is re-checked. Print §5's line. Still read `DELIVERED` and `DIVERGED`: a fix can add real API,
so **extend `delivered:`**, and if the plan *prescribed* the defective thing, rewrite the
prescription as an invariant, not just its value.

**A `DELIVERED` that changed after dependents launched is forwarded, once, to each of them**
— every `running` or `open` node that `needs` this one: `SendMessage` "what you built on
changed" with the new lines. This is the rare case launching early accepts. An empty
`DELIVERED` on a second `pr_opened` — a lint fix, a re-run, a clean sync — forwards nothing.

**`RESULT: blocked`** — set the node `blocked`, write the reason into `reason:`, regenerate,
commit, and bring it to the user. Don't relaunch or work around them. Anything that isn't one
of these three results is treated as `blocked`.

## 5. Getting PRs merged

An open PR goes one of two ways. **By default it goes to the merge desk**: you report it the
moment its implementer returns, the desk waits for its checks and feeds GitHub's merge
queue, and nothing waits on a person. **A node marked `merge: owner` waits for the owner
instead**, in the queue further down. One monitor per repo watches both kinds.

### Reporting to the desk

On a `pr_opened` for a node without `merge: owner`, **once every one of its `needs` is
satisfied** — a node built on an unmerged PR is held until then, however early it finished:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/ontherun-merge-desk.sh submit <pr-url> --from "<your session's name>" --sha <head oid>
```

"Reporting a PR" in `${CLAUDE_PLUGIN_ROOT}/skills/merge-desk/SKILL.md` is the rule; read it
once. `--from` is your own session's name, as `ListAgents` gives it: the implementer is a
subagent, and the desk's answer has to reach a session. The head is
`gh pr view <n> -R <owner>/<name> --json headRefOid`.

- **A held PR is reported when its last need merges.** A same-repo one first has to absorb
  the merge: *When something leaves the queue* sends its implementer "your base merged",
  and the `pr_opened` that answers, with `STACKED_ON: none`, is what you report. One held
  only by a need in another repo is reported as it stands.
- **Don't wait for the checks.** Watching them is the desk's job. An implementer's
  `pr_opened` is its word that the commit was reviewed, and that is all a report claims.
- **A refusal is handled as a PR sent back** with the reason `submit` printed.
- **`no merge desk is running`** is said to the owner once: the reports are recorded and
  are enqueued when one starts — `/ontherun:merge-desk`, in another session. Don't start
  its loop yourself; a desk owes an answer to every session that reports to it.

### What the desk sends back

One message per report, from the desk's session, its first line starting `Merge desk:`.
**A message is a reason to look, not the fact.**

- **Merged** — *When something leaves the queue*, below, which confirms it in the tree.
- **Sent back, for something the branch can fix** — `checks_failed`, `conflict`,
  `head_moved`, `draft`, `timed_out`. `SendMessage` the reason and its detail, as they
  came, to that node's implementer; `implementer-protocol.md` says what it does with them.
  Its next `pr_opened` (§4) is reported again. An implementer that is gone is replaced as
  the owner's queue describes: a new one of the node's tier, on the adopt path, given the
  desk's reason as its job.
- **`review_required`, `dequeued`** — a person's move. Say it to the owner at once; the node
  stays `open`.
- **`refused`** — usually a repo with no merge queue. Write `merge: owner` on that node and
  on every unmerged node in the same repo, say so once, and they join the owner's queue.
- **The same PR sent back a third time** — stop reporting it and bring it to the owner with
  the three reasons.

### The owner's queue

The open PRs of `merge: owner` nodes in one repo are a **queue**, and only its **head** —
the one PR you ask the owner to merge next — is ever prepared for merge. Everything behind
it waits, stale on purpose: a PR that waits through three merges absorbs all three in one
sync when its turn comes. One queue per repo, independent of every other. A desk PR is
never synced for its turn: GitHub's queue merges it with whatever is ahead of it, and a
conflict comes back from the desk.

### Queue order

Derive it; don't store it.

1. A node another node `needs` comes first — merging it launches a wave.
2. Everything else in `## State` block order, which `plan-format.md` requires to be DAG order —
   never PR number, which doesn't exist yet when the monitor is armed.
3. `draft-pr` and `blocked` nodes are **not in the queue at all** — a draft at the head is a
   queue that never moves — and neither is a node the desk has, or one with a need that
   has not merged yet.

### When the head is ready

All four: the PR is `OPEN`, not a draft, its branch has absorbed the current default branch,
and its checks have **finished** without a failure. `pending` is not ready — announcing
"ready" while CI runs means interrupting the human again when it goes red. Whether the branch
is current is a git question:

```bash
git -C <repo> fetch origin
git -C <repo> rev-list --count origin/<branch>..origin/<default>   # 0: nothing to absorb
```

**A head that is behind gets exactly one `SendMessage`** — to its own implementer: it is next
in the owner's merge queue and the default branch moved; run `sync-main`. Nobody else hears
anything. Its second `pr_opened` means the head is ready (§4).

If that implementer is gone — a session died, or §2 picked the plan up fresh — spawn a new one
of the node's tier rather than syncing yourself. Give it the branch the block records and the
absolute worktree path that branch's slug gives, and say plainly that the branch exists and its
PR is open, so it takes the protocol's **adopt** path. Its job is the sync — with the review
round the protocol says a sync can owe — and nothing else.

### Watching: one monitor per repo

One `Monitor` per repo — never one per PR — armed with the longest `timeout_ms` the tool
allows. **A monitor expires**: on each expiry notice, re-arm it with the same list. An expiry is
not a queue event, and a queue nobody re-armed reads exactly like a quiet one. The loop is
`${CLAUDE_PLUGIN_ROOT}/bin/ontherun-merge-monitor.sh`, armed with the repo's absolute path and this plan's
still-eligible branches in that repo — **the owner's queue first, in queue order, then the
branches the desk has**. Its rows are how you see any PR merge, close or go draft, whoever
did it; its head line means something only while it names an owner's-queue branch:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/ontherun-merge-monitor.sh /abs/path/acme-api \
  claude/api-1-<slug> claude/api-2-<slug>
```

**Run it with `--once` before arming.** It prints one snapshot and exits; a snapshot missing a
branch you have an open PR for means a name is wrong, and a head that isn't the branch you
meant to be next means the order is. Armed rather than checked, both read as a quiet, healthy
queue.

**The list is one thing: every branch of this plan in this repo that is still eligible, in
that order** — the plan's, not the wave's, though only branches that exist. **Whenever that
set changes, replace the monitor**: `TaskStop` the old, arm the new. Two things change it — a
later wave adding branches to a repo that still has open PRs, and a node going `blocked` or
`draft-pr` while its PR stays open, which `gh` can't see. Never two monitors for one repo.

The script's header says what it prints: full branch names only, a snapshot per poll with
only the changes, the head's checks rolled up to `pass` / `pending` / `fail` / `none` /
`query-failed`, and a `tip` column that moves when a sync or a fix is pushed. A `query-failed`
line appears only after several failed polls, so it means something durable — expired auth, a
revoked token — go and look.

If `Monitor` isn't available, run `--once` when the user asks where things stand, and say that
nothing is watching between runs.

### When something leaves the queue

A monitor row and the desk's message can both announce the same merge; the first does the
work below and the second finds it done.

1. Set the node to what the line said, regenerate the ledger, commit. **A `MERGED` is confirmed
   in the tree first**: take the merge commit from
   `gh pr view <n> -R <owner>/<name> --json mergeCommit,mergedAt`, fetch, and check
   `git -C <repo> merge-base --is-ancestor <sha> origin/<default>`; then record `merged`, the
   short `sha` and the `merged:` date. A PR gone draft is `draft-pr`. A `CLOSED` you didn't
   expect: stop and ask.
2. **On a merge, release what was built on it.** Each `open` node whose `base:` is the
   merged node gets one `SendMessage`: your base merged, with the PR number and the squash
   commit. A `running` one finds out by itself before it opens its PR. Each `open` node
   held only by this merge, with no `base:`, is reported to the desk now.
3. **Recompute the owner's queue head**, and sync that one implementer if it's behind. If
   the owner merged out of order, the head is whatever the order now says.
4. **Re-read the plan from disk** and launch the newly unblocked wave (§3). Your context is
   the thing most likely to have been compacted, and another session may have edited the
   plan.

3 and 4 are independent, and 4 never waits for 3: a fresh implementer cuts from
`origin/<default>` itself, so it already has the merge the queue is still working through.

**A PR that closes or goes `blocked` with nodes built on it stops them**: launch nothing
more on it, and bring it to the owner with the list of nodes that carry its commits.

### What the human sees

One line per repo, and nothing else, printed when it changes:

```
acme-api — #114 merged; #116, #117 with the desk; #119 built on #116
acme-api — yours next: #118 `feat(users)!: account deletion` — ready to merge (1 queued behind)
```

The first form is a repo with nothing for the owner to do. The second appears while the
owner's queue has a head; the state after the title is one of *ready to merge*, *syncing
with main*, *checks running*. Send a `PushNotification` (where available) **only on ready
to merge**, one per repo, and **only once the node is `open` in the block** — checks can
finish before the implementer's report arrives, and that report could still be `blocked`.

- **Never re-render the node table**; the full state lives in the plan file.
- **Don't narrate** ("merge detected", "sync started", "sent back, fixing"). Say what is
  now true.
- **Don't notify per PR opened or reported.**
- **Do speak at once** when something stops that only the owner can restart: `blocked`,
  `needs_input`, a PR gone draft, an owner's-queue head whose checks fail, and the desk's
  `review_required`, `dequeued`, `refused` and third send-back.

## 6. Closing it out

When every node is `merged`, `done` or `dropped`, spawn a **fresh** `verifier` (`ontherun:verifier`) with only the plan path
and the workspace root. You can't grade this yourself: you chose the sequencing and watched
every PR land.

**Walk the plan's `## Verification` scenarios first, before you spawn it** — the only place in
the workflow that does. `${CLAUDE_PLUGIN_ROOT}/reference/verification-walk.md` is the
procedure: what to confirm about the serving checkouts before you trust a browser, how to run
a scenario that mutates the human's running app, and what a failure is — a new node and a new
wave through §3, never a quiet fix, and no move to `done/` until it holds. No `## Verification`
section means nothing to walk; say so rather than inventing scenarios.

**`verifier` still gets only the plan path and the workspace root.** Don't hand it your
account of what you ran; it will report the live scenarios as unverified, correctly, from
where it sits. **You** write their outcome into the Status prose during the rewrite.

On `VERDICT: shipped`, follow `verify-plan` §§7–9 for the human-facing half: show the
classification and the proposed Status text, wait for a go-ahead, rewrite **only** the Status
block — the paragraph by hand, the ledger by regenerating from the block — and move the file.
A bullet still reading `open` under a "Shipped" verdict means the block missed a merge: fix the
block, regenerate. **`## Review history` is not rewritten**; round narrative still sitting in
the old Status moves there. Any other verdict: report it and stop — the plan doesn't move.

## Things that are not this skill's job

- **Unrelated bugs and out-of-scope work you notice in passing.** Offer them as separate
  sessions where the environment can start one, or list them for the human. Never fold them
  into a node.
- **Merging, or enqueueing.** Ever. GitHub's merge queue merges what the desk feeds it, and
  the owner merges the rest.
- **Hedging for nobody.** Compatibility work is a requirement when it names a consumer and a
  finding when it names none — `plan`'s rule, held by `plan-reviewer`; don't relitigate it
  from here.
