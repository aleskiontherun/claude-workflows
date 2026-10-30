# The plan format

A plan is a prose document a human reads and argues with. Its load-bearing parts are
paragraphs of reasoning — owner decisions, trade-offs, rejected alternatives — not fields.

What the format adds is one machine-readable section, `## State`, so that `conduct` can
pick a plan up mid-flight without re-deriving the whole sequence from prose on every wake-up.
**This file is the only definition of the format.** `plan`, `conduct`,
`verify-plan`, the agents and the scripts reference it rather than restate it. Where plans
live, and which repos a node can land in, is `workspace.md` beside this file.

## The anatomy

````markdown
# Feature name (`acme-api` + `acme-web`)

**Status:** <one line: the verdict.>

<the ledger — one bullet per node, generated from ## State>

<prose: what verification did, deviations, what is still open.>

<any amount of further preamble: owner decisions, forensics, open calls.>

## State

```yaml
<the state block>
```

## Review history   <- optional; the round-by-round log

## <the rest of the plan, as prose>

## Verification         <- optional; omit the heading unless it has scenarios
## Externals verified   <- optional
## Derivations          <- optional
````

Three rules about the preamble — everything between the `#` title and the first `##`:

- **Only the Status block is ever rewritten** — the paragraph beginning `**Status:` and the
  ledger under it. Everything else in the preamble is preserved verbatim.
- That region is not boilerplate. Owner decisions live there, and forensics that exist
  nowhere else.
- If a rewrite of the Status would drop history the old one carried, move it down rather
  than lose it — into `## Review history` for round-by-round narrative, into the preamble's
  owner decisions for a ruling.

`## State` is deliberately the **first** `##`, so it sits outside the preserved region and
can be rewritten freely.

## The Status block: a verdict, a ledger, then prose

One line of verdict, then a bullet per node, then prose. The ledger answers "where is
this?" for a live plan and "what shipped?" for a done one at a glance.

````markdown
**Status:** Shipped 2026-08-21, both PRs on `main`.

- **api-1** `feat!: user avatars on the files volume` — [#108](https://github.com/acme/acme-api/pull/108) merged 2026-08-21, squash [`d444fd4`](https://github.com/acme/acme-api/commit/d444fd4)
- **web-1** `feat!: avatar management` — [#96](https://github.com/acme/acme-web/pull/96) merged 2026-08-21, squash [`1ab2b13`](https://github.com/acme/acme-web/commit/1ab2b13)

**Verified 2026-08-21 by a clean-context agent** at those two refs: …
````

A live plan has the same shape with each node's actual state:

````markdown
- **api-1** `chore: scope commit signing` — [#111](https://github.com/acme/acme-api/pull/111) open, awaiting review
- **web-1** `chore: scope commit signing` — in progress on `claude/web-1-signing`
- **web-2** `docs: contributor guide` — not started, needs `web-1`
````

**The ledger of a plan with a `## State` block is generated, never written.**
`bin/wf-plan-ledger.sh <plan> --write` under the plugin root — the parent of this file's
`reference/` directory — renders it from the block — one line
per node, in block order, with the wording above and `blocked: <reason>`,
`draft, waiting on the human`, `dropped` and `done` for the other statuses — and replaces
whatever bullets sit between the Status paragraph and `## State`. Links come from each node
repo's `origin` remote. A block that groups nodes under `# ---- Phase N: name ----` comments
gets a bold heading line per phase, and an existing heading keeps its text by position, so a
parenthetical a human added survives regeneration.

**A plan with no nodes** — one written before it needed a DAG, or a draft — keys its
bullets by repo and PR instead, same shape and same links. Don't retrofit a `## State` block
onto a plan that already shipped just to get node ids: the ledger is for the reader, the
block is for the conductor, and a shipped plan has nothing left to conduct.

After the prose, a **short evidence list** — one bullet per repo citing `file:LINE` for
what was checked. It is a different list from the ledger: the ledger says where the work is,
the evidence says what was read to believe it.

**The prose after the ledger carries only what a list can't** — what verification did, the
deviations and whether each was better or worse, caveats, open questions — and never
restates PR numbers or shas, which live in the bullets and in `## State`. **It carries the
current state of the plan, never the story of how it got there**; that goes to
`## Review history`.

**Once a plan is promoted, its Status carries one sentence naming the exit that promoted it** —
`sound` or `corrections_only` and the round, or *promoted by ruling* (`plan-review-loop.md`,
step 5). Every rewrite keeps that sentence: `plan` and `conduct` send a plan whose nodes
are all `pending` and whose Status names no such exit back to review.

**Who writes which.**

- `conduct` owns **both** the block and the ledger, and writes only the block: it edits
  the block, then regenerates the ledger. `plan` authors the block when it writes or
  deepens the plan; from the first launch on, every change to it is the conductor's. A
  ledger bullet is never hand-edited — the next regeneration overwrites it — so whatever a
  bullet should say goes into the block (`reason`, `merged`) or into the prose.
- `verify-plan` rewrites **the Status verdict and prose**, by hand, from the tree, and
  leaves `## State` alone: its job is to establish what landed independently of the block.
  It regenerates the ledger only when the block matches the tree. Where they disagree, the
  disagreement is its finding — reported, then reconciled by `conduct` §2, or, for a plan
  closing out as shipped, corrected by `verify-plan` itself once the user has seen it.

**A block that disagrees with the tree is a finding, not corruption** — the block is a cache,
the tree is the truth. A ledger that differs from `wf-plan-ledger.sh`'s rendering of its own
block was hand-edited or left behind: correct the block, then regenerate.

## The state block

```yaml
repos: [acme-api, acme-web]
nodes:
  # ---- Phase 1: backend ----
  - id: api-1
    repo: acme-api
    title: "fix(auth): sweep expired authentication requests"
    needs: []
    agent: implementer
    status: merged
    branch: claude/api-1-sweep-expired
    pr: 102
    sha: e59a947
    merged: 2026-08-20
    delivered:
      - src/app/crud/auth_requests.py:88 — sweep_expired(), called hourly
  - id: api-2
    repo: acme-api
    title: "feat(users)!: account deletion with a grace period"
    needs: [api-1]
    agent: implementer-high
    status: pending
  # ---- Phase 2: frontend ----
  - id: web-1
    repo: acme-web
    title: "feat(settings): delete your account"
    needs: [api-2]
    agent: implementer
    status: pending
```

In the single-repo layout every node has `repo: .` and `repos: [.]`.

| Field | Meaning |
| --- | --- |
| `id` | Stable handle, prefixed by repo — `api-`, `web-`, `lib-`. A repo's prefix is the one its earlier nodes in this plans directory already use; a repo's first node gets a short one named after what it holds. Match the numbering the prose build order uses. |
| `repo` | The checkout the node's PR lands in, as a path relative to the workspace root, or `.` for the root itself (`workspace.md`). Never the plans repo. |
| `title` | The PR title, so the conductor and the verifier search for the same string. |
| `needs` | DAG edges — ids that must be *satisfied* first: `merged`, `done` or `dropped`. `[]` means it can start now. |
| `agent` | Which agent definition implements it: `implementer` or `implementer-high`. Sets model and effort. The conductor spawns it under the plugin's namespace, `ontherun:<agent>`. |
| `status` | See *Statuses*. |
| `branch`, `pr`, `sha` | Filled in as they become known. `sha` is the squash commit on the default branch. |
| `merged` | `YYYY-MM-DD` the PR merged, written with `sha`; the ledger prints it. |
| `reason` | Why a `blocked` node is blocked, one line — what it waits on; the ruling itself lives in the prose. |
| `delivered` | The contract surface the node actually built, from its implementer's own report — a few `path:line — what` bullets. Filled in with `pr`. |
| `kind`, `check` | Non-PR nodes; see *Node kinds*. |

**`delivered` is the one field the conductor doesn't author**, and it is what makes the next
node's prompt possible. The conductor has to tell each implementer what already exists, and
the only other source is the plan's prose — which says what was *meant* to land, and is the
very text that implementer is about to read as its specification. So the implementer that
built a node reports its surface (`implementer-protocol.md`, step 5) and the conductor copies
it here verbatim. It is a cache like `sha`: a `delivered` line says where to go read, never
that the code is there. Its line numbers drift by construction — review rounds and the squash
keep editing after the report — so hand on the named symbol, with the range as a hint.

A `verifier` proposing a block for a half-finished plan has no implementer report to copy,
and **leaves the field out rather than reconstructing one**: the field means *the implementer
said so*. Its evidence list does that job instead. So a conductor writing a block from a
verifier's proposal **carries over the `delivered` entries the plan already records** — a
silent proposal is not an empty field.

**List `nodes` in DAG order** — every node after the ones its `needs` name, and in the same
order as the ledger. The conductor's merge queue breaks ties on this order, because its
monitor is armed before any of the wave's PRs exist, so a PR number can't be the tiebreak.

**Which repos can host a node** — `workspace.md`, *Rules that follow*. A node takes its
conventions from its repo (`project-docs.md`), and runs whatever that repo names as its check
where it has no test suite. Where a repo lacks something a node needs — a default branch, PR
title linting the plan relies on — the plan closes the gap with a `setup` or `manual` node
before that repo's first node launches.

**The plans repo never hosts a `pr` node.** It takes no PRs (`workspace.md`), so the node
would sit waiting for a merge that never comes. The conductor edits plans itself; any other
plans-repo work is a `setup` node.

### Node kinds: `pr`, `setup`, `manual`

| `kind` | Who does it | `repo` / `agent` | `id` prefix | Terminal status |
| --- | --- | --- | --- | --- |
| `pr` (default; omit the field) | an implementer, ending at `gh pr create` | required | by repo | `merged` |
| `setup` | the conductor, in its own session — `gh api`, a hosting connector, `curl`, a file written into the plans or workspace repo | neither; `agent: conductor` | `setup-` | `done` |
| `manual` | the owner — only a step the conductor cannot take: a secret it must never hold, a new account or a sign-in, a message in the owner's name, a click no API reaches | neither; `agent: owner` | `manual-` | `done` |

**Non-PR work is `setup` unless a step in it needs the owner, and then only that step is
`manual`.** Cut the node at the step, not at the sitting: a node that is all conductor work
apart from one secret pasted into a repository setting is two nodes, the small one `manual`.
A step that spends money stays `setup` when the plan states the cost; the conductor names it
to the owner in the session before applying it — a plan approved in an earlier session is not
consent to spend in this one.

Two rules make non-PR nodes safe in a DAG:

- **Every `setup` and `manual` node carries a `check:` line** — a command or observation that
  proves it done. The conductor runs it before writing `done`, and `verifier` re-runs it on
  a pickup. A node whose completion nothing can observe is not a node; write it as prose.
- **`needs` treats `done` exactly as `merged`**, and `dropped` as satisfied. A `pr` node may
  need a `manual` node and the reverse.

A `manual` node the owner hasn't done leaves its dependents `pending`; the conductor says
once which node is waiting and on what, and doesn't nag.

### Statuses

| Status | Means | What the conductor does |
| --- | --- | --- |
| `pending` | Not started | Launch when every `needs` id is satisfied — `merged`, `done` or `dropped` |
| `running` | An implementer is working on it | Nothing — wait for it to return |
| `open` | PR opened, awaiting review | Nothing — it waits its turn in that repo's merge queue |
| `draft-pr` | PR exists but is marked draft | **Stop and ask** — a draft never fires a merge |
| `merged` | On the default branch, verified against the tree | Unblocks its dependents |
| `done` | A `setup`/`manual` node's `check:` passed | Unblocks its dependents; never used for a `pr` node |
| `blocked` | Needs a human decision recorded in the prose | Stop and ask |
| `dropped` | No longer applicable | Treated as satisfied for `needs` |

## The block is a cache, never the truth

**The tree decides; the block only decides what to re-check.** `conduct` re-verifies
before it acts, and the block narrows that pass to the nodes plausibly in flight. A node the
block calls `merged` still gets confirmed against `origin/<default>` before its dependents
launch, because:

- **the plan file moves under you** — another session can move it to `done/` while yours is
  still running;
- **squash merges make branches lie** — `git branch --merged` reports a squash-merged branch
  as unmerged while its work is on the default branch; trusting the branch re-implements a
  shipped PR;
- **stale branches outnumber live ones** — leftovers zero commits ahead sit beside branches
  whose relationship to what shipped only a content read can settle.

`status: merged` is a claim, and `sha` is where to go check it. Neither is evidence.

## Drafts don't get a state block

A plan whose Status paragraph carries the `DRAFT` marker has nothing to sequence yet and gets
no `## State`. It carries instead:

```markdown
## Open questions for the detailing pass
```

— one bullet per decision that must close before any of it is implementable. `plan`
reads it as the work list for a detailing pass, and `conduct` refuses to launch against a
plan that still has one.

**One sanctioned exception while a plan is mid-review.** A detailing pass builds the
`## State` block *before* it drops the marker, then runs the review loop over the whole plan
with the marker still standing. A plan carrying both is mid-review, not corrupt, and **the
marker wins** — nothing launches against a `DRAFT`, whatever its State says. A clean verdict
drops the marker and keeps the block; a capped-out loop parks it (`plan-review-loop.md`,
step 4), keeping the block unless the open questions reopen the design.

## The Review history section

Earned the moment a plan's first review round returns — every round gets an entry, because
the next round's diff starts from the commit this one read. It holds the
round-by-round narrative — what each round found, what was folded, what an owner ruled at a
gate, what was overridden and by whom — so the Status block stays the size of what it
describes. Every reviewer reads the whole plan every round, so narrative accumulated in the
Status makes round N pay for rounds 1 to N−1, and hands the reviewer exactly the account of
earlier conclusions its prompt whitelist withholds.

- **Put it immediately after `## State`**, which must stay the first `##`.
- **Append; never rewrite.** One dated entry per round or segment, oldest first, naming its
  verdict and the plan commit it read. An entry that turned out wrong gets a later entry
  saying so.
- **What belongs**: a round's verdict, the commit it read, what it found, what was folded and
  what dropped as unconfirmed, a cap and how it was routed, an override and its reasoning, a
  `fold-checker` verdict that sent a fold back, the output of a command run instead of a
  validator. **What doesn't**: an owner *decision* — a ruling that settles what gets built
  lives in the preamble, preserved verbatim and read as specification; this section records
  that the gate happened, with a pointer.
- On close-out this section stays, and the Status collapses.

## The Verification section

Optional, and earned only when a node claims something its own tests cannot settle — what has
to be observed in a running app, a browser, or on the wire. Write each as a scenario with the
expected value in it ("set the currency to EUR, enter 12.50 → the request body carries
`amount_cents: 1250, currency: "EUR"`"), never "check that it works".

**A node whose invariant the suite can't verify owes an entry.** Layout is the standing
example: a DOM test environment without layout returns zero-sized rects, so a geometry
assertion passes against any markup. `conduct` walks these once, after the plan's last PR
merges — the first moment the app can do what the plan describes.

**Omit the heading rather than leaving it empty**; an absent section means "nothing to walk".
This section says what verification **must do** and is written before the work; what it
**did** goes in the Status prose at close-out.

## The Externals verified appendix

Optional, earned the moment a plan carries external claims. One row per source: the claim,
the URL, the date it last reproduced, and the tool that worked — some hosts refuse `WebFetch`
and serve `curl`, and a round that doesn't know that reports the source unverified.
`plan-reviewer` takes a dated row under about a week old as read instead of re-fetching.
Write it during research while the fetches are fresh; update a row's date when a later round
re-verifies it.

## Derivations

Optional: one row per derivation the plan relies on — the command, the count or hash it
returned, the date, the ref it ran at. The prose states each derivation beside the list it
backs, where the implementer reads it; this table is for the reviewer who has to check them,
so a round re-runs the rows instead of re-finding them. **A reproducing row buys the
arithmetic and nothing else** — a too-narrow command reproduces perfectly every time — so the
reviewer still judges whether the command asks the right question.

**Record the ref and the number**: a later round can compare against them even where it
can't re-run the command. **State the command's limits beside it**: a pathspec excludes
silently (`-- src` never scans the `README.md` and docs that carry the same sentence), a
line-oriented grep misses a sentence a formatter wrapped across two lines (squeeze each file
first: `git show <ref>:<file> | tr '\n' ' ' | grep -oE …`), and an empty table cell matches no
pattern. Prefer `git grep` and `/usr/bin/grep` in a stated command over a bare `grep` that may
be a shell alias. Rows go stale on purpose: update them when a round re-derives.

## Counts

**A plan never counts its own contents.** "Five rules", "the six owner decisions", "three
phases": each goes stale the moment a fold adds one, and adds nothing the noun didn't say —
write *the rules below*, *the owner decisions*. `wf-plan-lint.sh`'s `self-count` check fails a
plan on the pattern outside `## Review history`. Exempt: the Status roster ("of its N nodes, P
are PRs"), which the lint verifies against the block; a numbered item and its continuation
lines (an owner decision is preserved verbatim and may count what it ruled on); `delivered:`
items; and a number that belongs to the word before it — *Phase 3*, *wave 2*, *PR 2*.

**A count of the tree is a claim, and those stay** — "384 rows", "22 files". State it once,
beside the command that derives it, and point at it from everywhere else.

## How a plan cites the tree

**Cite the named thing; treat the line number as a hint.** A heading, an exported symbol, a
quoted sentence survive edits to the file; a line range doesn't, and a plan is read over days
while the default branch moves underneath it. When an earlier node's merge shifts a file by
different amounts in different regions, no single offset is safe, and arithmetic on drift
introduces fresh wrong numbers. So write `restoreSession()`, `the "Retention" section`, and
give a range only where it helps find something long — saying once, in the plan, that ranges
are hints. **Where a citation and a name disagree, the name wins.**

`bin/wf-plan-cite-check.sh <plan>` under the plugin root sweeps every citation against
`origin/<default>` — the file, the symbol or quoted sentence beside it, how far the range
drifted — and can't see a claim that cites no file.

## Strategy documents are not plans

A file in the plans directory with no `**Status:` line anywhere describes the world rather
than a change to make. It never ships, never moves to `done/`, and gets no state block.
Detect it by that shape, never by filename or subject matter.
