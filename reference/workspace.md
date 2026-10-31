# Workspace layout

Every skill, agent and script in this plugin that touches plans, or more than one repository,
resolves the terms below the same way. This file is the only definition of them; the
others point here rather than restate it, because a restated rule is a second place for
it to go stale.

## Terms

- **Repo** — a git checkout. Run every git command as `git -C <repo> …` and never rely
  on the working directory: checkouts can nest, and a bare `git` addresses whichever repo
  happens to contain the cwd.
- **Default branch** — resolved per repo, never assumed:
  `git -C <repo> rev-parse --abbrev-ref origin/HEAD` prints `origin/main` or similar. If it
  fails, the clone has no `origin/HEAD`: a skill or script runs
  `git -C <repo> remote set-head origin --auto` once and retries, while a read-only agent
  (the guard denies `git remote`) skips the repair; either then takes whichever of
  `origin/main` and `origin/master` exists (`git -C <repo> show-ref --verify -q
  refs/remotes/origin/main`). The plugin's files write `origin/main` for short — read it as
  that repo's default branch.
- **Workspace root** — the directory plans, and the repos plan nodes land in, are named
  relative to.
- **Plans directory** — `<workspace root>/plans/`, unless the instruction files at the
  workspace root (`CLAUDE.md`, `AGENTS.md`) name another. Shipped plans move to
  `<plans>/done/`.
- **Plans repo** — the git repo that tracks the plans directory.
- **Node repo** — a repo a plan node's pull request lands in.

## Finding the workspace root

1. The user named a plan by path: the workspace root is the parent of the plans
   directory that contains it (for `…/plans/done/x.md`, still the parent of `plans/`).
2. Otherwise walk up from the working directory, inclusive, and take the first directory
   that contains a `plans/` directory (or the one the instructions name). Stop at `$HOME`.
3. Nothing found means there is no plans store yet. A skill that only reads plans says so
   and stops; `plan` offers to set one up (below) and asks which layout.

The scripts under the plugin's `bin/` — the plugin root is the parent of this file's
`reference/` directory — resolve the root from the plan path they are given:
`ONTHERUN_WORKSPACE` when set, else the parent of the nearest enclosing directory named `plans` (from
a worktree of a workspace repo, in its main working tree), else the plan's git top level. **With
a plans directory named anything else, set `ONTHERUN_WORKSPACE` to the root** when running them. They
read the node checkouts under that root, so ledger links and the lint's ledger check need those
checkouts present.

## The two layouts

**Workspace repo.** The root is its own git repo, usually private, tracking `plans/` and
often its own `CLAUDE.md`. The code checkouts sit inside it as plain directories that the
root does not track — listed in its `.gitignore` or `.git/info/exclude`, so a `git add`
there can never pick one up as a gitlink. Plans repo = the root; node repos = any nested
checkout. Use it for a product spread over several repos, or when plans stay private
while the code is public.

```
~/work/acme/            workspace root, a git repo tracking plans/
  CLAUDE.md
  plans/
  acme-api/             node repo, its own origin
  acme-web/             node repo, its own origin
```

**Single repo.** The root is the code checkout itself, and `plans/` inside it is a small
git repo of its own, excluded by the code repo through `.git/info/exclude` so that nothing
in the shared `.gitignore` changes. Plans repo = `plans/`; the only node repo is the root,
written `repo: .` in a plan.

```
~/work/acme-app/        workspace root and the node repo
  .git/                 excludes plans/
  plans/                plans repo
    .git/
```

Setting either up is the user's call, made once:

- workspace repo — `git init` at the root, a `.gitignore` naming each nested checkout,
  then commit `plans/`;
- single repo — `git init plans`, append `plans/` to `.git/info/exclude`, then commit
  the first plan inside `plans/`.

**Why plans never live in a node repo's own history.** The conductor rewrites a plan's
`## State` block every time a node changes state. In a node repo those edits would either
sit uncommitted in the checkout implementers branch from, or land on the default branch
without a pull request. Keeping plans in a repo of their own makes every plan edit an
ordinary commit nobody else's branch depends on.

## Rules that follow

- **Plans are never referenced from a node repo.** No `plans/<name>.md` path in code, a
  comment, a decision record, a commit message, a PR title or a PR body: anyone else's
  clone has no plans directory, so the reference dangles the moment it is written. Where a
  plan's reasoning belongs in the repo, write the reasoning out.
- **The plans repo takes no pull requests and never hosts a `pr` node.** Plan edits are
  commits straight onto its checked-out branch, by pathspec —
  `git -C <plans repo> commit -m "…" -- <plan>` — never `git add -A` and never a bare
  `git commit`: other sessions working in the same checkout may have staged files of
  their own. Push only when it has a remote and the user or the workspace instructions
  want that.
- **Other work on a workspace repo** — its `CLAUDE.md`, tooling it tracks — is ordinary
  work for `implement` and `review-loop`, run in their no-PR mode: on a branch,
  reviewed, pushed when there is a remote, no pull request.
- **A repo can host a node** when its `origin` is on GitHub, accepts pull requests from
  this account, and has a default branch to cut from. Titles are semantic —
  `<type>[(scope)][!]: <description>`, type one of `feat`, `fix`, `refactor`, `docs`,
  `test`, `chore`, `perf`, `ci`, `build`, `revert` — unless the repo's own docs set
  another convention.
- **Node worktrees and branches.** Worktree `<repo>/.claude/worktrees/<node-id>-<slug>`,
  branch `claude/<node-id>-<slug>`, both chosen by the conductor. Before the first one,
  if `git -C <repo> check-ignore -q .claude/worktrees/x` fails, append `.claude/worktrees/`
  to `<repo>/.git/info/exclude` (local, never committed).
- **Untracked checkout entries are not dirt.** In a workspace repo, `git status` lists the
  nested checkouts as untracked unless they are ignored. A dirty-tree check disregards
  every untracked entry that is itself a git checkout, or a directory containing only
  checkouts. Decide by looking for `.git`, never from a remembered list.

## `gh` needs a repo, explicitly

`gh` has no `-C`. Run it with the node repo as the working directory, or pass
`-R <owner>/<name>`, taken from `git -C <repo> remote get-url origin`. A `gh pr` query run
at a workspace root that has its own GitHub remote resolves to the workspace repo, which
has no pull requests, and answers with an empty list and exit 0 — indistinguishable from
"no such PR". Never read a `gh` answer from there.
