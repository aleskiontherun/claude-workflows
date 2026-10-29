# claude-workflows

User-scope Claude Code skills, agents, shared references and scripts, all prefixed `wf-`.
`README.md` says what each piece is; `install.sh` symlinks them into `~/.claude`.

- **One home per rule.** A rule shared by several skills or agents lives in exactly one file
  under `reference/`, and every other file points at it by path (`~/.claude/wf/reference/…`).
  A restatement is a second place for the rule to go stale; delete it rather than keep it in
  step.
- **Generic only.** Nothing that gets installed — `skills/`, `agents/`, `reference/`, `bin/` —
  names a particular project, repo, stack, or incident; example values in samples are fine.
  `README.md`'s migration table is the one place an earlier project is named.
  Project specifics come from the project's own `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md`
  / `DECISIONS.md` at run time (`reference/project-docs.md`).
- **Prose says what and why, in the present tense** — never what a file used to say.
- **Agents' criteria stay in the agent files**, outside the control of the party they review;
  skills never pass review criteria in a prompt.
- **Scripts**: every `bin/*.sh` has a `.test.sh` beside it; run `bin/run-tests.sh` and
  `shellcheck bin/*.sh install.sh` after any change. Keep the header comment (usage, exit
  codes, env) current.
- **Checks for this repo**: the two commands above, `./install.sh --dry-run`, and a
  frontmatter parse of every `skills/*/SKILL.md` and `agents/*.md`. Never run `./install.sh`
  for real as a check — it rewrites `~/.claude`.
- Renaming or adding a skill or agent: update `README.md`'s tables and any `~/.claude/...`
  path that names it; the installer picks up `wf-*` by glob and prunes stale links.
