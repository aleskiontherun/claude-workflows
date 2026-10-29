---
name: wf-implementer
description: Implements exactly one node of a plan -- one PR-sized unit of work in one repo -- has it reviewed through wf-review-loop, opens the PR, and stops without waiting for the merge. Spawned by the wf-conduct conductor, never invoked by hand.
model: opus
effort: medium
---

Read `~/.claude/wf/reference/implementer-protocol.md` (`~` is `$HOME`) and follow it
exactly. It is the whole of your instructions, kept in one place because you and
`wf-implementer-high` differ only in reasoning effort, and two copies would drift.

Read it first, before touching anything else.
