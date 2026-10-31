---
name: product-analysis
description: Run a fresh-eyes product analysis of the current project -- market size, competitors, user demand, an inventory of what the product actually does today taken from the code, gap analysis with prioritized next moves, and a conditional README refresh. Use when the user asks how the product stacks up against the market, what to build next for adoption, or to redo the analysis after a major milestone. Challenges earlier conclusions instead of assuming them.
---

# Product analysis

A full fresh-eyes pass. Earlier analyses — in the plans directory (`${CLAUDE_PLUGIN_ROOT}/reference/workspace.md`),
in a strategy document, in the README — reached conclusions. Treat each as a
hypothesis to re-test, not a fact; when one no longer holds, say so plainly.

**Establish what the product is first**: the repos it spans, who it's for, how it's
distributed and priced, from the READMEs and instruction files (`${CLAUDE_PLUGIN_ROOT}/reference/project-docs.md`).
Where that leaves the product's category or audience genuinely unclear, ask the user one
question before researching the wrong market.

Fan the research in §1–§3 out to subagents in a single message, at `effort: "high"`, and keep
the reading in their contexts. Every external claim carries a source link and a date.

## 1. Market

Current market reports and usage estimates for the category. Distinguish the headline number
(registered, certified, downloaded) from the active one, and report the honest active range
with sources. Note anything recent that changes the picture.

## 2. Competitors

Discover them rather than assuming the list a previous analysis used: incumbents, platform or
vendor offerings, and the indie and open-source field, plus anything new. For each: pricing,
platform reach, integrations, lock-in and data portability, and what users complain about.

## 3. Demand signals

Where the audience actually talks — forums, subreddits, issue trackers, reviews. What they
choose and why, willingness to pay (shutdowns for lack of paying users are the canonical
datum; look for newer ones), and whether the pains this product addresses are still live.

## 4. What the product does today

Don't trust past write-ups, including the READMEs — they go stale. Inventory from the code:
recent `git log` across every repo, the API's routes, the app's screens or pages, the CLI's
commands, the LICENSE file of each repo. Then verify live where the project documents how to
run it — through a demo or seeded account if one exists, and **never through the owner's real
account for anything that may become public material.**

## 5. Gap analysis and next moves

Score the current feature set against what §1–§3 say wins adoption in this category. Deliver
the top ~5 next moves, each with the audience it unlocks and an honest effort estimate. Flag
every README-versus-reality mismatch found along the way.

## 6. READMEs (conditional)

Only if positioning shifted or claims went stale: update the READMEs. Claims stay limited to
what is implemented, with a *Planned* section for the rest. Retake stale screenshots the way
the project documents. Each repo's README change is its own `implement` run, in a session
started in that repo — offer them as separate sessions where the environment can start one,
otherwise give the user one prompt per repo. Never a commit to the default branch.

## Output

A single report — market → competitors → demand → inventory → gaps → moves — leading with a
one-paragraph verdict, with sources as markdown links. If the user wants it kept, save it to
the plans directory as a dated strategy document (no `**Status:` line, so nothing treats it as
a plan). README edits, if any, are listed at the end with their PRs.
