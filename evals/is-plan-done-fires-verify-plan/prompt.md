---
description: Natural phrasing that should route to the verify-plan skill.
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
expected_outcome: Claude invokes the verify-plan skill before doing anything else.
---

Is the account-deletion plan actually done? Check what landed on main and file it under done if it shipped.
