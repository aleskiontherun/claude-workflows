#!/usr/bin/env bash
# Write the diff of ONE plan -- the fold just made to it -- to a file a fold-checker or a
# plan reviewer can be handed, and print that file's path.
#
#   wf-plan-fold-diff.sh <plan.md> [<base-ref>]
#
# The file holds `git diff <base-ref> -- <plan.md>`, run in the plan's own repository --
# the plans repo (reference/workspace.md), whichever layout -- against
# <base-ref>, which defaults to HEAD; and nothing else. It lands under
# $CLAUDE_SCRATCHPAD, or /tmp when that is unset, as fold-<plan>-<timestamp>.diff. Only
# the path goes to stdout, so `$(...)` captures it; a one-line count of what the diff
# carries goes to stderr, for the eye that has to judge whether it is the fold.
#
# One file and never the plans directory: other sessions may share the plans repo's
# working tree, and their uncommitted edits to other plans are not this fold.
#
# Exits 1 and writes nothing when there is nothing to hand over: an empty diff (the fold
# is not there -- or it is already committed and <base-ref> should be the commit before
# it), an untracked plan (a whole new file is a plan review, not a fold), a plan outside
# any git repository, or a ref git cannot resolve. 64 on usage.
# reference/plan-review-loop.md says what to do with the path.
#
# Needs bash and git. wf-plan-fold-diff.test.sh beside this file covers each case in both
# layouts.

set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf 'usage: %s <plan.md> [<base-ref>]\n' "${0##*/}" >&2
  exit 64
fi
plan=$1
base=${2:-HEAD}

if [ ! -f "$plan" ]; then
  printf 'wf-plan-fold-diff: no such file: %s\n' "$plan" >&2
  exit 1
fi
# Resolve the plan to an absolute path once, then run every git command in its own
# directory: the caller may sit anywhere, and a worktree's plan must diff against that
# worktree, not the checkout the script happens to live in.
dir=$(cd -- "$(dirname -- "$plan")" && pwd) || exit 1
abs=$dir/$(basename -- "$plan")

git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 \
  || { printf 'wf-plan-fold-diff: %s is not inside a git repository\n' "$plan" >&2; exit 1; }
git -C "$dir" ls-files --error-unmatch -- "$abs" >/dev/null 2>&1 \
  || { printf 'wf-plan-fold-diff: %s is not tracked; a fold needs a committed plan to diff against\n' "$plan" >&2; exit 1; }
git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
  || { printf 'wf-plan-fold-diff: cannot resolve %s in %s\n' "$base" "$dir" >&2; exit 1; }

out_dir=${CLAUDE_SCRATCHPAD:-/tmp}
mkdir -p -- "$out_dir" || exit 1
name=$(basename -- "$plan" .md)
tmp=$(mktemp "$out_dir/fold-$name.XXXXXX") || exit 1

if ! git -C "$dir" diff "$base" -- "$abs" > "$tmp"; then
  rm -f -- "$tmp"
  exit 1
fi
if [ ! -s "$tmp" ]; then
  rm -f -- "$tmp"
  printf 'wf-plan-fold-diff: no changes to %s against %s; if the fold is already committed, pass the ref before it (HEAD~1)\n' \
    "$plan" "$base" >&2
  exit 1
fi

out=$out_dir/fold-$name-$(date +%Y%m%dT%H%M%S).diff
[ -e "$out" ] && out=${out%.diff}-$$.diff
mv -- "$tmp" "$out" || exit 1

read -r added deleted _ < <(git -C "$dir" diff --numstat "$base" -- "$abs")
printf 'wf-plan-fold-diff: %s against %s: +%s -%s lines\n' "$plan" "$base" "$added" "$deleted" >&2
printf '%s\n' "$out"
