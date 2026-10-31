# Reading a project's own rules

Every skill and agent in this plugin takes a project's conventions from the project — not from
memory, and not from whoever invoked it. This file says where they live and how to treat
each one. It is the only copy; the others point here.

## Where to look

For the repo you were given, then for each ancestor directory up to the workspace root
(`workspace.md`), or up to `$HOME` when there is none:

| File, any case | Holds | Use it |
|---|---|---|
| `AGENTS.md` | the conventions, written for every coding agent | read whole; its rules bind |
| `CLAUDE.md`, `.claude/CLAUDE.md` | Claude-specific rules — often an `@AGENTS.md` import and a few lines | read whole; follow every `@path` import |
| `CONTRIBUTING.md`, also under `docs/` or `.github/` | build, lint, format, type-check and test commands, and the environment they need | the single source of truth for checks |
| `DECISIONS.md`, `docs/decisions*`, `docs/adr/`, `adr/` | non-obvious choices and the pitfalls behind them | grep it; never read a large one whole |
| `README.md` | setup and usage, sometimes conventions | conventions and commands when the files above are silent |

List each directory case-insensitively rather than guessing a spelling:

```bash
ls -a <dir> | grep -i -E '^(agents|claude|contributing|decisions|readme)\.md$'
```

and find the nested ones with `Glob` — `**/decisions*`, `**/adr`, `**/contributing.md`
under the repo, skipping `node_modules`.

An `AGENTS.md` or `CLAUDE.md` in a subdirectory governs the files beneath it, so check the
directories of the files a change touches as well.

**Nothing here is loaded for you.** A session started outside a repo does not get that
repo's `CLAUDE.md`, a worktree of a workspace repo contains none of the nested checkouts,
and a subagent starts with no project context at all. Read the files.

## How to treat each

- **Instruction files bind, and a rule is only a rule if you can quote it.** A finding or
  a decision that rests on a project rule names the file and quotes the rule.
- **A missing file is not a gap to fill.** A repo without `AGENTS.md` or `CLAUDE.md` may
  be that way by decision, and the tree cannot tell you which. Never add one on your own
  initiative — ask — and never report the absence as a finding. Take the conventions
  from what the repo does ship.
- **Checks come from `CONTRIBUTING.md`, then `README.md`.** Failing both, infer them from
  the build manifest — `package.json` scripts, `Makefile`, `justfile`, `pyproject.toml`,
  `Cargo.toml`, `go.mod` — and from the CI workflows under `.github/workflows/`, and say
  that you inferred them. Honour every environment caveat those files state: a suite
  that skips itself without a variable is green and proves nothing.
- **Grep the decision record before calling anything odd.** Search it for the symbol,
  table or concept involved; if the choice is explained there, it is not a finding.
  Append to it only where the instruction files say entries belong, and keep an entry
  short and in the present tense — the code cannot carry the reason, and the entry says
  what and why, never what the code used to do.
- **Prose says what and why, in the present tense.** Comments, decision entries, commit
  messages and PR bodies; never a history of the change, which git holds. A PR body is a
  paragraph on what changed and why plus one line on how it was verified.
- **Project rules beat these defaults** wherever the two disagree: PR title format, base
  branch, PR body shape, where decisions are recorded, which checks gate a change.
