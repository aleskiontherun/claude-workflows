---
description: Natural phrasing that should route to the merge-desk skill.
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
expected_outcome: Claude invokes the merge-desk skill before doing anything else.
---

Be the merge desk for this machine: my other sessions will report PRs that are ready, and you add them to GitHub's merge queue in the order they come in.
