# claude-workflows

A Claude Code plugin, `ontherun`, holding skills, agents, shared references, scripts and a hook. Skills and agents
are namespaced `ontherun:<name>`; the scripts keep a `wf-` prefix because `bin/` is on the Bash
`PATH`. `README.md` says what each piece is. This file is for working on the repo; it
sits under `.claude/` because a `CLAUDE.md` at a plugin's root is not loaded and the validator
warns about it.

- **One home per rule.** A rule shared by several skills or agents lives in exactly one file
  under `reference/`, and every other file points at it by path. In a skill or agent body the
  path is `${CLAUDE_PLUGIN_ROOT}/reference/…`, which Claude Code substitutes when it loads the
  file; a reference file is read raw, so it says "the plugin root, the parent of this file's
  `reference/` directory" instead. A restatement is a second place for the rule to go stale;
  delete it rather than keep it in step.
- **Generic only.** Nothing that gets installed — `skills/`, `agents/`, `reference/`, `bin/`,
  `hooks/` — names a particular project, repo, stack, or incident; example values in samples
  are fine. `README.md`'s migration table is the one place an earlier project is named.
  Project specifics come from the project's own `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md`
  / `DECISIONS.md` at run time (`reference/project-docs.md`).
- **Prose says what and why, in the present tense** — never what a file used to say.
- **Agents' criteria stay in the agent files**, outside the control of the party they review;
  skills never pass review criteria in a prompt. Agents are spawned by their namespaced name,
  `ontherun:<agent>`, and the skills say so at each spawn site.
- **The read-only agents are enforced by `hooks/wf-readonly-guard.sh`**, not by their `tools:`
  line — a `Bash(pattern)` entry there is undocumented and unenforced. Adding a command one of
  those agents needs means extending the guard's allowlist and its test together.
- **Scripts**: every `bin/*.sh` and `hooks/*.sh` has a `.test.sh` beside it; run
  `bin/run-tests.sh` and `shellcheck bin/*.sh hooks/*.sh install.sh` after any change. Keep
  the header comment (usage, exit codes, env) current.
- **Checks for this repo**: the two commands above, `claude plugin validate --strict .` and
  `claude plugin validate --strict .claude-plugin/plugin.json`, `./install.sh --dry-run`, and
  `claude --plugin-dir "$PWD" plugin details ontherun` for the component inventory and token cost.
  CI runs the first four. `claude plugin eval .` runs the trigger evals in `evals/`; it costs
  model calls, so run it on purpose. Never run `./install.sh` for real as a check — it
  registers a marketplace and installs the plugin in `~/.claude`.
- **Releases**: bump `version` in `.claude-plugin/plugin.json` — users who installed from
  GitHub stay on the old version until it changes — and tag with `claude plugin tag`.
- Renaming or adding a skill or agent: update `README.md`'s tables and every `ontherun:<name>` or
  `${CLAUDE_PLUGIN_ROOT}/…` path that names it; the guard's agent list if it is read-only.
