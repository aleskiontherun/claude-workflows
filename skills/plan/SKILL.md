---
name: plan
description: Write a feature plan and get it attacked -- researching it, putting the product calls to the owner, splitting the work into PR-sized nodes with a `## State` DAG, and running clean-context plan-reviewer rounds until one exits clean -- then present it and stop. Also deepens a DRAFT plan into a detailed one, and re-attacks a plan on request. Use when the user wants a feature planned, a plan written, a draft deepened, or a plan reviewed. Conducting an approved plan -- launching implementers, the merge queue, closing out -- is conduct.
argument-hint: "[plan path, or a feature to plan]"
effort: xhigh
---

# Plan a feature

You are the planner. You research and write the plan and hold the human's questions;
`conduct` runs the implementers that build it afterwards. The one thing you don't do
yourself is the thing that having written the document disqualifies you from: judging it. Plan
review goes to clean-context subagents, as code review and final verification do later.

The shared references live in `${CLAUDE_PLUGIN_ROOT}/reference/`: `workspace.md`
(where plans live, which repos host nodes), `plan-format.md` (the only definition of a plan's
shape, `## State` included), `plan-review-loop.md` (the loop this skill ends in), and
`project-docs.md` (where each repo's rules live). Scripts are in `${CLAUDE_PLUGIN_ROOT}/bin/`. Read
`plan-format.md` before writing a plan; this file doesn't restate it.

**This skill sets `effort: xhigh`, and that holds for all your turns in it; the model is still
the session's.** You are the planner, so the session's model is the planning model — if the
user asked for a specific one and the session isn't on it, say so now. Implementer tiers are
chosen per node by `conduct`, not by the tier the plan was written at.

## 1. Work out which entry path you're on

**Find the workspace root first** (`workspace.md`). With no plans directory anywhere up the
tree and a feature to plan, offer to set one up: ask with `AskUserQuestion` which layout —
*workspace repo* (plans in a repo that contains the code checkouts) or *single repo* (`plans/`
as its own git repo nested in, and excluded by, the code checkout) — then do the setup steps
`workspace.md` lists. Don't pick for them.

Ask the user only what the files can't tell you. Match their words against the plans
directory; with no plan named, list the active plans with their Status lines and ask which.
Nothing matching, or two, means list the candidates and ask — don't guess.

| Situation | Go to |
| --- | --- |
| A feature with no plan yet | §2 |
| A plan whose Status carries the `DRAFT` marker | §3 |
| A plan whose nodes are all `pending` and whose Status names no promoting exit (`sound`, `corrections_only`, promoted by ruling) | `plan-review-loop.md` — no round has passed it; run the loop to an exit |
| A promoted plan the user wants attacked again, nothing launched | `plan-review-loop.md`; its step 5 governs what the exit lets you write |
| A plan with no `## State` block and no node list in its prose | §2, from *Write the plan* — the prose is there, the shape isn't |
| Any other plan with a `## State` block and no marker | `conduct` — hand it over |
| A file with no `**Status:` line anywhere | Stop: a strategy document, not a plan (`plan-format.md`) |

Take the first row that matches, and decide by opening the file, never from its name or subject. Files in `<plans>/done/` are
revisited only when the user explicitly asks.

## 2. Planning a new feature

**Research first, and fan it out.** Spawn research subagents concurrently — one message, one
per independent question — and keep the heavy reading in their contexts: what the tree does
today, what sibling repos already expose, what the external landscape is. Spawn them with
`effort: "high"`, and as `Explore` where the question is a census of a tree; left alone they
inherit this skill's `xhigh`, which a read-and-report task doesn't need. Shipped plans in
`<plans>/done/` are the model for depth: cite named code and carry URLs for external claims.

**Record the externals as you research**, in an `## Externals verified` appendix
(`plan-format.md`) — claim, URL, date, the tool that worked. The reviewer takes a fresh row as
read instead of re-fetching; without it every round re-fetches everything.

**Ask the human directly.** You have `AskUserQuestion` and your subagents don't. Product
calls, scope boundaries, anything with a cost the user should choose to pay. Record the
answers as **owner decisions** in the plan's preamble, with the reasoning — they survive every
later rewrite and are read as specification.

**Ask the review loop's two questions here too**, beside the product calls, and record both
as owner decisions: whether a cap whose open findings all have a single evident resolution is
folded and the loop re-entered without stopping, and after how many rounds the plan is
promoted by ruling with its open findings recorded as open. `plan-review-loop.md` step 4
routes every cap by them; a plan that arrives without them is asked at its first cap — one
more owner gate for the same answer.

**Write the plan** in the plans directory following `plan-format.md`: prose, a `**Status:`
paragraph, and a `## State` block carrying the DAG. Split the work into PR-sized nodes, one
repo each, and write every dependency edge in *both* the prose and the block — the prose says
why, the block is what gets executed. Work no PR carries is a `setup` node by default; a
`manual` node holds only the step the owner must take.

**At creation the Status says the plan is _not_ promoted and the first round is in flight.**
Nothing has attacked it yet, so any readiness-shaped sentence would be one you invented about
your own document. Write what is true — when it was written, what research and which owner
decisions went in, that the mechanical checks pass — and then that none of that is a review and
nothing launches until a round exits `sound` or `corrections_only` and this paragraph says
which. Open it: **Status: not yet promoted — the first `plan-reviewer` round is in
flight.** The loop's step 5 is the only thing that may later rewrite this into a readiness
claim, and only on a clean exit; writing one now makes that decision before its evidence
exists, and the human reading the Status can no longer tell the two apart.

**Split for concurrency, not for review surface.** Two nodes forced through the same files in
series are usually worse than one: the second reads the plan *after* the first merged,
inherits every citation the merge moved, and the corrections that folds in trigger a mid-flight
review the combined node never needed. Serial same-repo nodes don't conflict — the later one
just pays the drift. Split for different repos, for two independent nodes that can run in one
wave, or for an ordering constraint one PR can't express. Review doesn't read whole diffs here
— each node gets its own reviewer and validators however the work is cut — so PR size is not
the saving it looks like. Where you split a serial chain anyway, say what the second node will
inherit.

**Specify each node as an invariant, not an implementation.** An invariant is a falsifiable
claim the reviewer and implementer can both check; prescribed code arrives with the authority
of a decision, so every reader implements it instead of testing it, and no number of review
rounds will find it wrong. "A label row with a control shares the baseline of one without" is
checkable; a pasted `<div className=…>` is not. State the property, say how to verify it, and
**say when the suite can't** — a DOM test environment without layout passes any geometry
assertion. A node whose invariant the suite can't verify owes a scenario in `## Verification`.

**Write a derivation rule wherever you would write a list.** Review is good at checking that
each listed item is right and bad at noticing the list is short, and a short list reaches the
implementer as an anchor. So write *"sweep for this sentence"* rather than *"it appears in
these two files"*, *"read every `send_*` call site"* rather than naming the two you found.
Marking a list as a floor is not enough on its own: where you can't avoid one, mark it a floor
**and** name the command that regenerates it.

**Point sweeps at the whole repository, and name the files to read whole where a probe can't
anchor.** A pathspec like `-- src ':!*.test.*'` never reaches the `README.md`, docs and
scripts where the same sentence lives as prose. Squeeze each file to one line before matching
(`tr '\n' ' '`) so a formatter's wrap can't split a sentence; and a prediction ("X is next")
names one thing and no neighbour, so no keyword window anchors on it — name the files a reader
reads whole beside the command.

**Record what each command returned, once, in `## Derivations`** (`plan-format.md`): command,
count or hash, date, ref. The command stays beside the list it backs, where the implementer
reads it; the table is for the reviewer, who re-runs rows instead of re-deriving in prose.

**Hold every hedge to a named consumer.** Compatibility work, shims and migration paths are
requirements when they protect someone's data or upgrade path that the project's docs describe
— and a finding when they protect nobody. A node that changes stored or cached data shapes, or
a public contract, against a deployment the docs describe owes a stated call: migrate, version,
flush, or why stale is acceptable.

**Then have it attacked.** Follow `plan-review-loop.md` — a loop, not a round. Commit the plan
(by pathspec, in the plans repo) before every reviewer spawn. `VERDICT: not_implementable`
makes the plan a DRAFT: demote it as that file says and go to §3 rather than arguing.

**Then present it to the human and stop.** Show the shape, the wave structure, what the
reviewer found and what you did about it. Launch nothing until they approve — and launching is
`conduct`'s anyway. The Status records which exit promoted the plan, in one sentence, only
on a clean exit (the loop's step 5); the rounds themselves go in `## Review history`. A
capped-out exit writes what the loop's step 4 says instead.

## 3. Deepening a DRAFT

A DRAFT is a recorded shape, not a design. **Never let an implementer launch against one** —
it produces a PR built from a document that says it isn't ready.

The work list is the plan's `## Open questions for the detailing pass`. Take it in order:
research each question as §2 does, bring the ones that are the owner's call to them with
`AskUserQuestion`, and fold the answers in as resolved prose rather than leaving them as
questions. When the section is empty, build the `## State` block and run `plan-review-loop.md`
over the whole plan. **A shallow-parked plan arrives with its block already there**: check it
still matches the node list and leave it standing rather than rebuilding an identical one.
Replace the `DRAFT` marker only when the loop exits clean — never after the first round, and
never while one is outstanding.

Promoting a plan out of DRAFT is a change the human should see before anything acts on it.
Show it and stop.

## Things that are not this skill's job

- **Conducting the plan you just wrote.** `conduct` verifies what landed, launches
  implementers wave by wave, runs each repo's merge queue and closes the plan out. Hand over
  rather than carrying on: the two halves want different effort tiers, and the session that
  just wrote a plan is the worst-placed to start acting on it.
- **Implementing anything.** Out-of-scope work you notice goes to the human as a suggestion,
  or to a separate session where the environment offers one — never into a node.
