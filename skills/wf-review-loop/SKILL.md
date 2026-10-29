---
name: wf-review-loop
description: Iterate a branch's already-implemented changes against an independent wf-reviewer subagent -- every flagged issue independently checked by a wf-validator before you act on it -- until they're clean, then open or update the PR and stop for the human's review and merge. Use whenever the user asks to review a branch, get feedback before opening a PR, iterate against review, or get changes ready for a PR, whether Claude or the human wrote them. Also entered by wf-implement once it finishes implementing.
---

# Review loop

Takes changes that already exist on a branch — however they got there — and iterates them
against `wf-reviewer`, a separate context with no memory of how or why the change was made,
until they're clean; then opens or updates a PR and stops. Every issue the reviewer raises
is checked by a separate `wf-validator` before you act on it, so one reviewer's false
positive can't send you chasing a fix for something that was never wrong. This skill never
merges, and never decides on its own that review is unnecessary.

It doesn't implement anything. With nothing to review yet, use `wf-implement`, or just do
what the human asked first.

Two shared references define what this file relies on: `~/.claude/wf/reference/workspace.md`
(repos, nesting, the default branch, `gh -R`) and `~/.claude/wf/reference/project-docs.md`
(where a project's rules and check commands live). `~` is `$HOME`.

## Step 0: establish the ground truth

Four checks, all cheap and deterministic. Each exists because skipping it wastes a review
round on a question a shell command answers for free.

1. **Pick the repo, and the working tree.** The repo is the one containing the changed
   files; repos can nest, so resolve it rather than trusting the working directory, and run
   `git -C <path> …` throughout. If the branch is checked out in a worktree, `<path>` is
   **that worktree**, not the main checkout — `git -C <repo> worktree list` shows where, and
   the branch name in its brackets is the one to trust, not the directory name. Pass the
   same path to both subagents: given the main checkout, they read the default branch's
   files while you ask about yours, and answer fluently and wrongly. A change spanning two
   repos is two runs of this skill, in two sessions.

   **No-PR mode.** A repo whose instruction files say it takes no pull requests — a plans
   repo or a workspace repo always qualifies (`workspace.md`) — or that has no GitHub
   remote, runs everything below except the PR itself:
   - the work still goes on a branch, cut from the default branch (`origin/<default>`, or
     the local default branch when there is no remote), so unreviewed commits stay off it
     while the loop runs; with no remote, step 0.3 fetches nothing and the base is that local
     branch;
   - step 0.2 disregards untracked nested checkouts (`workspace.md`, *Untracked checkout
     entries*);
   - step 0.4 runs whatever the repo or the change itself admits when no check commands
     are documented — `bash -n` and `shellcheck` on a script, a frontmatter parse on a
     skill, a test file beside what changed — and never a command that writes outside the
     repo as a side effect, such as an installer run for real;
   - step 5 pushes when there is a remote, and opens no PR. Merging stays the human's.

2. **Refuse to review an uncommitted tree.** `git -C <path> status --porcelain` must be
   empty. If it isn't, stop and tell the human — don't commit on their behalf. The reviewer
   diffs committed history, so working-tree changes are invisible to it and it will approve
   a diff that's missing them. If you do stage something here, stage explicit paths: a
   `git add -A` in a directory with nested checkouts can pick one up as a stray gitlink.

3. **Refresh the base ref.** `git -C <path> fetch origin <default>` before diffing. A
   stale base puts already-merged commits in the range — a round spent on other people's
   code. The base is `origin/<default>` unless you were told otherwise.

4. **Run the repo's own checks and get them green.** `project-docs.md` says where the
   commands come from and which caveats to honour — above all, a suite that skips itself
   silently without some environment is green and proves nothing. Fix and commit before
   going on. The reviewer is told not to flag anything a linter or the suite would catch,
   so if you skip this nobody checks that class at all.

## The loop

1. **Invoke `wf-reviewer`.** Its prompt is a whitelist, not a budget: exactly three facts —
   the **path**, the **base ref** and the **range for this round** — plus, when the diff
   has to be judged against another checkout, that sibling's **path and ref**. Nothing
   else, in any round. If a sentence you're about to write isn't one of those, it doesn't
   go in. Specifically out:

   - **What the change does.** No account of the feature, the files, the approach or the
     fix, and no evaluation of it. A reviewer told what the code is meant to do reads for
     agreement with that story instead of asking what it does. You wrote this code, or are
     relaying someone who did; you are the last party who should narrate it.
   - **What to look for.** No priorities, no "focus on", no "report correctness bugs". The
     criteria live in `wf-reviewer.md`, outside the control of whoever is being reviewed;
     a scope line in the prompt is an edit to that file made at runtime by the wrong party,
     and it subtracts — `needs_discussion`, the only route a design question has to the
     human, goes with it.
   - **Anything about earlier rounds.** No findings, verdicts, or validator outcomes, no
     "raised in round 1 and refuted, don't raise it again". Step 4 says what you do instead.
   - **Orientation and project rules.** The reviewer reads them itself from
     `project-docs.md` and the files it names. A rule restated by the party under review is
     a rule quoted selectively. If the reviewer needs something on every run, it belongs in
     `wf-reviewer.md`.

   **The one addition: a checkout the reviewer cannot discover.** When the diff is judged
   against another repo — a frontend calling an endpoint whose contract landed elsewhere —
   give that repo's path and the ref to read it at. That is a location, not a claim. Don't
   say what this diff does with it and don't widen the range.

   **Scope the range by round, and alternate.** Round 1 gets the whole branch:
   `<base>...HEAD`. A round after a full-range round gets only what was added since the
   commit that round reviewed: `<that sha>..HEAD`. A round after a narrow round is full-range
   again, whatever the narrow round's verdict — never two narrow rounds in a row. A
   regression a fix introduced lives in that fix, so the narrow round asks the expensive
   question exactly where the answer can be; but its verdict is about the fix, so the whole
   change is read again before anyone acts on it. The loop therefore ends clean only on a
   full-range verdict.

   Three exceptions turn a round that would be narrow into a full one: (1) a fix touched a
   file that wasn't in the original diff; (2) the previous round came back
   `needs_discussion` and the human has since redirected the work; (3) the default branch
   was merged into the branch mid-loop (`wf-sync-main`). The third isn't an optimization: a
   merge commit pulls everything the default branch added into `<that sha>..HEAD`. Use
   three dots — after a merge they are what excludes what the merge brought in.

   **Record `git -C <path> rev-parse HEAD` before you invoke the reviewer.** That sha is
   what this round reviews through and the left side of the next round's range. Captured
   after the fixes land, it is the fix commit, `HEAD..HEAD` is empty, and a reviewer shown
   an empty diff returns `VERDICT: approved` — the fix goes in unreviewed and nothing looks
   wrong.

2. **Read the verdict from the last line.**
   - `VERDICT: approved` → step 4b, then step 5.
   - `VERDICT: corrections_only` → step 3, then apply what survives validation, **commit it
     and re-run the step 0.4 checks**, then step 4b and step 5. **No further fix round**:
     the verdict saves the reviewer call, not the local gate — a correction can't regress
     the change, but the patch implementing it can still break the build. If a finding here
     looks `blocking` to you, that is a reviewer error to report in step 6, not a verdict to
     overrule by looping.
   - `VERDICT: needs_discussion` → stop looping, whatever the round count. Step 5.
   - `VERDICT: changes_requested` → step 3, before touching any code.

3. **Validate every finding before acting on it, in parallel.** One `wf-validator` per
   finding, **all in a single message**. Give each only its own finding's description and
   location, the path from step 0.1, the round's base ref and range, and the sibling's path and
   ref when the reviewer had one — locations, like the reviewer's prompt; never the reviewer's
   full list, and never your opinion of it. Drop anything that comes back `RESULT: not confirmed`.
   - Nothing left confirmed: route as `approved` — step 4b, then step 5.
   - Confirmed findings left, every one a `correction`: route as `corrections_only`.
   - Otherwise fix only the confirmed ones. Never fix an unconfirmed finding because it
     seemed plausible.

4. **Fix, re-gate, loop.** Commit the fixes, re-run the step 0.4 checks, and go back to
   step 1, carrying the sha you recorded there.

   **Cap at 6 rounds**, a round being a reviewer call that came back `changes_requested`
   with at least one *confirmed* finding. If the sixth still requests changes, fix its
   confirmed findings and **stop** — step 5's unclean exit hands it over. A change that
   can't converge across six reviewed rounds needs a human's judgment, not more rounds; the
   number is a budget, not a convergence claim. Never conclude the reviewer is being
   unreasonable and proceed without it.

   **Carry every `not confirmed` verdict forward**, so a stateless reviewer re-raising a
   refuted finding doesn't buy a second validator. Reuse a verdict only while **nothing it
   rested on has changed** — the function, its callers, the types, the decision-record
   section or rule the validator cited, not just the flagged line. When you can't tell what
   a refutation rested on, re-validate; one cheap call is the better side of that trade.

   The carry-forward is **yours, never the reviewer's**: it decides whether you spawn a
   validator and never goes in the reviewer's prompt (step 1).

   **A finding refuted twice for the same reason belongs beside the code.** Your
   carry-forward dies with this session, and the next branch to touch the code buys the
   same refutation again. A one-line comment at the site stops it; a decision-record entry
   only where a comment can't carry the reason and the project's docs say entries belong.
   Same commit as the change.

4b. **Confirm the whole diff before you exit.** When the round that produced your clean
    verdict was *narrow*, the next round is full-range by step 1's alternation, and it is
    the read that lets the loop stop: run it over `<base>...HEAD`, recording `HEAD` first,
    before step 5. A clean narrow verdict is about the last fix, not the change.

    **Skip it in exactly two cases**, and say which in step 6: a single-round loop (round 1
    *was* `<base>...HEAD`), or a clean verdict that arrived on a full-range round. Never
    because the last fix was small — small is what a sliver always looks like.

    Its verdict routes through step 2 like any other, counts toward the cap on the same
    terms, and uses the same carry-forward. **An unclean exit is never owed one.**

5. **Push, and open or update the PR.** In no-PR mode, push when there is a remote, open
   nothing, and say so in step 6.

   **Clean exit** — `approved`; `corrections_only` with its confirmed findings applied; or
   a round where nothing survived validation. All three reach here through step 4b, run or
   skipped. Those three are the whole list: fixing a `changes_requested` round's findings
   returns you to step 1 however small the fix, and `corrections_only` is a verdict the
   reviewer issues, never a judgment you make about how minor a round looked.

   Push, then `gh pr list --head <branch>` (from the repo, or with `-R` — `workspace.md`).
   - **No PR yet**: `gh pr create --title … --body …`. For a plan node, use the title you
     were given, verbatim. Otherwise write it yourself in the repo's convention — semantic `<type>[(scope)][!]: <description>` unless its docs say
     otherwise. **Never `gh pr create --fill`**: it titles the PR from commit messages,
     which repos that lint PR titles reject on open.
   - **PR exists**: `gh pr edit --body …` so the body describes the change as it now
     stands, as if just written. No review-fixes section, no comment on the PR.

   The body is a paragraph on what changed and why plus one line on how it was verified,
   unless the repo's docs ask for more. **Keep plan paths out of the title and body**
   (`workspace.md`) — the reviewer never sees the body, so nobody else will catch it.

   **Unclean exit** — the cap hit with its last fixes unreviewed, or `needs_discussion`:
   push the branch, open **no** PR. If one exists, push, update the body as above, and mark
   it draft (`gh pr ready --undo`). An open PR is a claim the change is ready; don't make
   it on the human's behalf when review didn't finish.

6. **Stop, and tell the human where it landed.** The PR link if any; what was fixed; what
   the reviewer flagged that didn't survive validation; on an unclean exit the unresolved
   findings or the open question in full, since the chat is the only place they exist.

   **Relay what the reviewer checked** — its `Checked` list, in a line or two. On a clean
   exit it is the only evidence the review was more than a glance.

   **Name the exit**: `approved at <sha>`, `corrections_only at <sha>`, or `nothing survived
   validation at <sha>`, or say plainly that none happened. When step 4b ran, the sha is its
   round's; when skipped, name which case applied. A loop that stopped after fixing a
   round's findings has no sha to put here, and writing the sentence is where you find out.
   If this session runs below the strongest model tier, say which tier the review ran at:
   the reviewer inherits the session model, so `approved` from a cheap session is a weaker
   claim than the same word from an expensive one.

   Do not merge. Do not start on anything else unasked.

## Setup

Depends on `wf-reviewer` and `wf-validator`, installed with this skill by the repo's
`install.sh`. Their criteria live in those files, outside both the implementer's and this
skill's control.

Both are meant to be read-only, and their `tools:` frontmatter says so — but treat that as
an instruction they follow, **not an enforced sandbox**. Claude Code resolves the
parenthetical Bash patterns there by tool name only, so they get unrestricted `Bash`. If you
want the guarantee rather than the intent, add `deny` rules in `settings.json`.

## Where the cost goes

`wf-reviewer` runs once per round and is both the cost centre and the value — an open-ended
hunt across a whole diff is the expensive thing being bought. Everything else exists to make
that call count: the step 0 gate strips mechanical findings first, range scoping stops every
second round re-reading a diff already judged, and the decision-record grep heads off the
largest source of confident, wrong findings.

**The alternation is where cost is deliberately spent**: every round after a narrow one reads
the whole diff, and step 4b is that rule at the exit. Findings a narrow chain misses sit in
the original diff, outside any fix's range, and only a full read reaches them.

**The cap bounds blocking rounds, not reviewer calls**: a clean narrow round between two
blocking full ones isn't counted. Six is where a human's judgment becomes the cheaper input.

**`corrections_only` is the cheapest thing here**: without it, one surviving nitpick buys a
full reviewer call to establish that fixing a comment broke nothing.

**`wf-validator` is pinned to `sonnet`** because it is the fan-out — five findings, five
agents — and confirming one claim against visible code doesn't need a frontier model. Don't
trade it for the main agent judging findings against code it may have just written: that
substitution would hollow out the whole loop.

**`wf-reviewer` deliberately inherits the session model.** Pinning it caps it below the
human's tier when they run higher, and overrides a deliberate choice to run cheap; step 6
names the tier instead. If you pin either agent, use a family alias (`opus`, `sonnet`,
`haiku`), never a full model ID, which quietly stops meaning "the current one".

## What this skill is not for

- Implementing the work — that's `wf-implement`, or doing what the human asked directly.
- Merging — always the human, on their own schedule.
- Reviewing uncommitted changes — see step 0.2.
- Spanning two repos in one run — see step 0.1.
