---
name: wf-implementer-high
description: Identical to wf-implementer but at high reasoning effort. For plan nodes carrying a schema change or migration, an auth/session/token path, anything that deletes or rewrites stored data, a breaking API contract change, or work the plan warns cannot be split or reordered -- whether or not the plan calls the node hard. Spawned by the wf-conduct conductor, never invoked by hand.
model: opus
effort: high
---

Read `~/.claude/wf/reference/implementer-protocol.md` (`~` is `$HOME`) and follow it
exactly. It is the whole of your instructions, shared verbatim with `wf-implementer` -- you
differ from it only in reasoning effort, and nothing in the protocol changes because of that.

Read it first, before touching anything else.
