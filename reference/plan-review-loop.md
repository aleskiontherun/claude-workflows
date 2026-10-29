# The plan-review loop

**A reference file, not a skill.** Two skills run this loop and neither restates it:
`wf-plan` runs it over a plan nobody has built yet, and `wf-conduct` §4 runs it over a fold
made while the plan is half shipped. They differ on exactly one thing — where a blocking
verdict goes — and that difference is stated in step 3 below and in `wf-conduct` §4. Read it
from whichever skill sent you, and use that skill's routing rather than inventing one.

It is a loop, not a single call, for the same reason code review is one: folding a finding in
changes the plan, and the changed part is then the part nobody has read.

The plan format, its sections and its `## State` block are `plan-format.md`; paths,
the plans repo and node repos are `workspace.md`. Both sit beside this file in
`~/.claude/wf/reference/`. Scripts are in `~/.claude/wf/bin/`.

## Run the mechanical checks before every round

Cheap and deterministic, and each strips a class of finding before an expensive whole-plan
read can spend itself on it — the same trade `wf-review-loop` step 0 makes with lint and
tests.

- **`wf-plan-cite-check.sh <plan>`** — every cited file at `origin/<default>` after a fetch,
  never the checkout (which routinely sits on a feature branch), and the backticked symbol or
  quoted sentence beside each citation: `MISS` when absent, `DRIFT` when the range moved (a
  warning: ranges are hints). Its header says what it pairs, skips, and when it exits 2. Shas
  in prose, the block's `sha:` and `merged:` fields, and any claim that cites no file are
  yours to resolve by hand (`git -C <repo> rev-parse <sha>`).
- **`wf-plan-lint.sh <plan>`** — the `## State` block against `plan-format.md` (it parses,
  every `needs` names an earlier node, each node has the fields its kind needs and a known
  status, nothing nested too deep), then the Status block against the block (the ledger is
  `wf-plan-ledger.sh`'s rendering, the node counts the prose states, the round it says is in
  flight against `## Review history`, the `DRAFT` marker against what a draft must carry),
  then the prose for a count of the plan's own contents. What it can't see stays yours: no
  two nodes marked independent may touch the same files.
- **Re-run every derivation the plan states**, and check each list is still the length the
  plan says. Where the plan has a `## Derivations` section, update a row's count and date
  whenever one moves.

**`wf-plan-lint.sh` also runs before every `wf-fold-checker` spawn and before every commit of
a plan**, since a fold is where its Status checks earn their keep — it answers in under a
second, a fold-checker pass takes minutes.

Before round 1 these run over the whole plan. **Before every later round, and before a
`wf-conduct` §4 mid-flight round, they run over whatever the fold touched** — the least-checked
text in front of the next reviewer, since a validator judged the finding *before* you wrote
anything and nothing has read the sentence you then wrote.

**This is not the reviewer's passes done early, and can't be.** You wrote the plan; a sweep
you run over your own document proves you can grep. `wf-plan-reviewer` still runs all its
passes. What the sweep buys is that its mechanical passes find nothing and its time goes to
reasoning, which is where the findings that change the work come from.

## The loop

1. **Spawn `wf-plan-reviewer`** with only the plan path and the workspace root. No summary,
   no framing, no account of what an earlier round said — the whitelist `wf-review-loop`
   step 1 puts on code reviewers, for the same reason.

   **From round 2 on, add one more path: a diff of everything the plan changed since the
   commit the previous round read**, written by `wf-plan-fold-diff.sh <plan> <that commit>`.
   That commit has to exist, so **commit the plan before every spawn** (by pathspec, in the
   plans repo — `workspace.md`) and record the commit in the round's `## Review history`
   entry. The reviewer runs its citation, external and completeness passes over the sections
   that diff touches and still reads the whole plan for sequencing and reasoning. A diff is a
   location, like the sibling checkout `wf-review-loop` admits: it says where the plan moved,
   never what it now says or why. A round given no diff reads everything whole.

2. **Read the verdict from the last line.**
   - `VERDICT: sound` — clean exit; go to 5.
   - `VERDICT: corrections_only` — validate the findings (below), fold what survives, go to
     5. **No further round.** Every finding leaves the work identical once fixed; a plan
     whose findings have decayed to prose precision is finished being attacked. **This is
     the exit that makes the loop terminate** — `sound` is close to unreachable for a
     citation-dense plan read against trees that move underneath it, so on a large plan this
     is the exit to expect. A loop that won't reach it is usually filing count deltas or
     floors as `blocking`, or sending stated commands to validators instead of running them.
   - `VERDICT: not_implementable` — stop, whatever the round count. **Demote the plan**
     (below), carrying the reviewer's reasons as the open questions, and go to `wf-plan`'s
     detailing pass.
   - `VERDICT: revise` — validate the findings, fold what survives, go back to 1.

   **Every fold this step makes goes through `wf-fold-checker` before you go on** (*Check the
   fold*, below), whichever exit you are routing to. On `corrections_only` it is the last
   clean context that reads the plan.

3. **Every round reads the whole plan for sequencing and reasoning.** The diff narrows only
   the mechanical passes. Code review scopes by range because a regression lives in the fix
   that introduced it; a plan's defects are relational — a node whose `needs` contradicts the
   prose — and live between the changed part and everything else, where no range reaches.
   That is also why this loop's cap can be 2 where `wf-review-loop`'s is 6: every round here
   already reads the whole document.

   **Step 2's routing is `wf-plan`'s only.** A mid-flight round from `wf-conduct` §4 must not
   follow it: demotion strips the `## State` block, which by then records merged nodes and
   their shas. Its routing is written in that skill's §4.

4. **Cap at 2 rounds.** If round 2 still comes back `revise`, stop and take the findings to
   the human. Don't fold them in and promote anyway: two rounds each finding something
   **blocking** says the design isn't settled, and that is their call. The cap bounds one
   segment between human touchpoints, never the plan's total review. Raising it is not the
   fix.

   **Before treating a cap as terminal, read the plan's preamble for a recorded exit policy
   and a recorded round budget** — the two questions `wf-plan` asks the owner when it writes
   the plan:
   - the **exit policy**, standing form: *a cap whose open findings all carry a single
     evident resolution is folded and the loop re-entered, without stopping*;
   - the **round budget**: after how many rounds the plan is promoted by ruling, with
     whatever findings are still open recorded as open.

   A plan carrying a policy routes its caps by it. **A budget that runs out returns the plan
   to the owner; it does not promote it** — unless the decision that set the budget ruled
   ahead ("after two more rounds, promote"). Then promote on that ruling, record the open
   findings as open, and say in the Status paragraph that the plan was promoted *by ruling*,
   so no later session reads it as `sound`.

   **The fork rule beats any policy.** A cap containing a genuine design fork — the plan
   states two incompatible answers, or the answer changes what gets built — stops and goes to
   the human whatever the preamble says. Sort the open findings into single-resolution and
   forks, and route on whether the second bucket is empty. A policy licenses continuing,
   never skipping the validators.

   **Read the policy from the plan, not from memory**, so two sessions reach the same outcome
   at the same cap. A plan that reaches its first cap without the answers recorded is asked
   them there, both at once, and the answers go into the preamble as owner decisions, each
   with its rejected alternative. The conductor is the party that benefits from not stopping,
   which is why both answers have to be the owner's.

   **Write the cap into `## Review history`** — which round, which findings were open, how you
   routed it.

   **When the cap does stop the loop, demote the plan** (below) with the open findings, before
   you stop. The Status paragraph is what the next session reads, and a plan that failed two
   rounds and one that passed must not read the same. **How deep depends on what is open**:
   findings that reopen the design get full demotion; when every open finding has a single
   evident resolution and none is a fork, **park shallow** — marker and open questions, and
   *keep* the `## State` block, so the detailing pass doesn't rebuild an identical one.

5. **Only a clean exit promotes the plan.** Rewriting the Status — dropping a `DRAFT` marker,
   or saying it is ready to implement — is the plan's version of opening a PR. Make that claim
   on `VERDICT: sound`, or on `corrections_only` once the corrections are folded, and at no
   other time (an owner's ruling under step 4 is the owner's claim, not yours, and is labelled
   as such). A plan whose `DRAFT` marker has gone routes to `wf-conduct`, which launches
   implementers; promoting mid-review removes the one marker standing between an unfinished
   design and a wave of agents building it.

   **This step is the only thing that writes that claim**, which is why `wf-plan` tells you
   what to write at creation instead. A plan picked up with a readiness claim and no exit
   named is treated as if the claim were absent.

   **Say which exit promoted it, in the Status paragraph** — `sound` or `corrections_only`,
   and the round. Without that sentence, a plan promoted on a clean verdict and one promoted
   because its author ran out of patience read identically. **That sentence is all that goes
   there**; everything else about the rounds goes to `## Review history`, an entry per round
   as you go.

## Validate a finding before you fold it

`citation`, `external` and `completeness` findings go to a `wf-plan-validator` — one per
finding, all in a single message — and anything that comes back `RESULT: not confirmed` is
dropped rather than folded. You are the plan's author and, until the human sees it, its only
reader; folding a finding unchecked is the author acting on an unexamined claim about their
own document. Give each validator only its own finding, the plan path and the workspace root
— never the full list, never your view of it.

**Only those three classes.** `sequencing`, `reasoning` and `scope` findings are judgments
with nothing in the tree to check them against; a validator handed one would agree, at a
cost. Fold those yourself, or take them to the human when they reopen the design.

**Within those three, run a stated command yourself instead of spawning a validator.** A
`completeness` or `citation` finding whose check is a deterministic command the reviewer
stated — a `git grep`, a count, a `git show` — you run, and its output goes into the
`## Review history` entry beside the fold, so the next round audits the tree's number rather
than your account of it. Running someone else's command isn't a judgment; the output is the
tree's. What this doesn't cover is substituting your own command, or concluding from the
output that the finding was really about something else. When the stated command looks wrong
— too narrow a pathspec, a pattern that can't match a wrapped sentence — that *is* judgment:
say so in the entry and let a validator run a better one. Validators are for what needs
judgment: which bucket a hit belongs in, whether a sentence is rationale that was true or an
instruction now wrong, an external claim to re-fetch.

**A verdict the validators empty out routes as the weaker one**: a `revise` whose blocking
findings were all refuted routes like `corrections_only`; one where nothing survived routes
like `sound`.

## Check the fold before the next round

Validation happens *before* you write anything; then nothing reads the sentence you wrote.
That gap is where expensive defects live — two rounds can each "fix" the same bullet wrongly
and the real defect underneath survive many more whole-plan reads.

**Write the fold so the checker holds on its first pass:**

- replace the sentence the finding quotes, and assert no more than the report established —
  a figure it didn't give is a command to run and paste; a list is a pointer at the section
  that holds it;
- widen a mechanism the plan already has rather than adding one — a new flag or state
  ripples into every sentence that counts, lists or scopes the same thing;
- for every absolute you add — *always*, *never*, *every*, *only*, a duration — check it
  against the tree or drop the word; for a file in a repo other than the finding's, read it at
  `origin/<default>` before the sentence stands;
- re-read the Status paragraph against any owner ruling the fold records, and restate nothing
  in `## Review history` that the body already says.

**Then sweep it: `wf-plan-fold-diff.sh <plan> [<base-ref>]`** writes `git diff <base> --
<plan>` — `HEAD` by default; the commit before the fold once it's committed — to the scratchpad
and prints the path. Diff the one file, never the whole plans directory: other sessions share
the working tree, and their uncommitted edits would ride along as if they were your fold.
**`wf-plan-fold-sweep.sh <plan> <diff>`** takes every value the fold's removed lines carried —
numbers, number words with their noun, backticked names, quoted sentences, rare words — and
lists where each still stands in the plan outside the fold's own lines, with the heading it
sits under (hits in `## Review history` listed apart); last, it lists the fold's new lines that
carry an absolute or name a file. Read the list whole, fix what is stale, write a fresh diff.
Its exit 1 is a list to read, not a verdict. What it can't see is a rule added beside a
sentence it contradicts, with nothing removed — that stays the checker's.

**Then spawn `wf-fold-checker`** with three paths and nothing else: the plan, the diff file,
and the workspace root. It answers two questions — is what the fold asserts true against the
trees, and did the fold leave a claim standing elsewhere that it just made wrong — and ends
`VERDICT: fold_holds` or `VERDICT: fold_defective`. On `fold_defective`, fix what it names and
run it again over a fresh diff. Its findings are grounded in the trees and the document, so
they don't go to a validator.

**A fix after `fold_defective` changes the sentences the checker quoted and asserts nothing
its report didn't establish.** The fix is unread text like the fold before it. Where it needs
a figure the report didn't give, run a command and put the output in `## Review history`;
where it needs a list, point at the section that holds it. A figure the checker itself offers
is a claim, not a finding.

**It is cheap because of what it reads** — a diff and the sections it touches, at medium
effort, against a whole-plan round at extra-high. It neither buys nor spends a round: run it
after *every* fold, and the whole-plan rounds still happen exactly where this loop and
`wf-conduct` §4 put them. The sweep scripts and the checker miss in opposite directions — a
grep can't tell that a true sentence contradicts a paragraph four sections away, and a reader
won't re-run your derivations — so run both.

**When you fold in a design change, write the rejected alternative beside it**, in the plan,
with what it would have cost. Every round arrives with no memory of the last, so a decision
that lives only in the conversation gets relitigated by the next reviewer, and you fold its
reversal back in. Written into the document, it's read like everything else, and the
reviewer's own rule against flagging named owner calls does the suppressing.

## Demoting a plan

Both non-clean exits send the plan back to `wf-plan`'s detailing pass, and must leave it in
the shape that pass expects. **Never demote a plan with a launched node** — anything past
`pending`. That is `wf-conduct` §4's case, routed there.

Full demotion is three things together:

- put `DRAFT` in the Status paragraph;
- **remove the `## State` block** — drafts don't have one;
- write what is unresolved under `## Open questions for the detailing pass`.

The marker without the questions is worse than nothing: the detailing pass takes its work list
from that heading, finds it empty, and re-runs this loop against an unchanged plan. The block
may stay when step 4's shallow-park test holds. `not_implementable` never parks shallow — it
says the shape itself is wrong, so caching the shape is exactly what not to do.
