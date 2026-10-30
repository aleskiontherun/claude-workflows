# shellcheck shell=bash
# Shared by the ontherun- scripts beside this file; sourced, never run. It resolves the terms
# reference/workspace.md defines, so every script answers "which directory is
# the workspace root", "which ref is this repo's default branch" and "which GitHub repo is
# this checkout" the same way.
#
#   . "$(wf_here)/ontherun-lib.sh"      -- see any ontherun- script for the two-line preamble
#
# Every function prints its answer and returns non-zero when it has none; none of them
# exits, so a caller decides what a missing answer means.

# The main working tree of the repo containing a directory: itself for a main checkout,
# the checkout its linked worktree belongs to otherwise.
wf_main_tree() { # dir -> main working tree
  local top common main
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd -- "$top" && pwd -P) || return 1
  common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -n "$common" ]; then
    main=$(cd -- "$(dirname -- "$common")" 2>/dev/null && pwd -P) || main=""
    if [ -n "$main" ] && [ "$main" != "$top" ] && [ -e "$main/.git" ]; then
      printf '%s\n' "$main"; return 0
    fi
  fi
  printf '%s\n' "$top"
}

# The workspace root for a plan file, as an absolute physical path:
#   1. $ONTHERUN_WORKSPACE, when set;
#   2. else the parent of the nearest ancestor directory named `plans` (a plan in
#      `plans/done/` resolves the same as one in `plans/`);
#   3. else the plan's git toplevel;
#   4. else the plan's own directory.
# A root that is the toplevel of a linked worktree of the workspace repo resolves to that
# repo's main working tree: the nested checkouts are untracked, so a worktree has none.
wf_root() { # plan -> root
  local d root up top
  if [ -n "${ONTHERUN_WORKSPACE:-}" ]; then
    (cd -- "$ONTHERUN_WORKSPACE" 2>/dev/null && pwd -P) || return 1
    return 0
  fi
  d=$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  root=""
  up=$d
  while [ "$up" != / ] && [ -n "$up" ]; do
    if [ "$(basename -- "$up")" = plans ]; then root=$(dirname -- "$up"); break; fi
    up=$(dirname -- "$up")
  done
  [ -n "$root" ] || root=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || root=$d
  [ -n "$root" ] || root=$d
  root=$(cd -- "$root" && pwd -P) || return 1
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$top" ] && [ "$(cd -- "$top" && pwd -P)" = "$root" ]; then
    root=$(wf_main_tree "$root") || return 1
  fi
  printf '%s\n' "$root"
}

# The plans directory a plan sits in: the nearest ancestor named `plans`, else the plan's
# own directory.
wf_plans_dir() { # plan -> dir
  local d up
  d=$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  up=$d
  while [ "$up" != / ] && [ -n "$up" ]; do
    [ "$(basename -- "$up")" = plans ] && { printf '%s\n' "$up"; return 0; }
    up=$(dirname -- "$up")
  done
  printf '%s\n' "$d"
}

# A repo's default branch as a remote-tracking ref, `origin/main` or the like: origin/HEAD;
# failing that, origin/HEAD after one `git remote set-head origin --auto`; failing that,
# whichever of origin/main and origin/master exists.
wf_default_ref() { # repo-dir -> origin/<default>
  local r b
  r=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && [ -n "$r" ] \
    && { printf '%s\n' "$r"; return 0; }
  if git -C "$1" remote set-head origin --auto >/dev/null 2>&1; then
    r=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && [ -n "$r" ] \
      && { printf '%s\n' "$r"; return 0; }
  fi
  for b in origin/main origin/master; do
    git -C "$1" rev-parse -q --verify "refs/remotes/$b" >/dev/null 2>&1 && { printf '%s\n' "$b"; return 0; }
  done
  return 1
}

# `owner/name` for a checkout whose origin is on github.com. Handles
# git@github.com:o/n.git, ssh://git@github.com[:port]/o/n.git and https://[user@]github.com/o/n[.git].
wf_slug() { # repo-dir -> owner/name
  local u s
  u=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  case $u in
    git@github.com:*)                     s=${u#git@github.com:} ;;
    ssh://git@github.com/*)               s=${u#ssh://git@github.com/} ;;
    ssh://git@github.com:[0-9]*/*)        s=${u#ssh://git@github.com:}; s=${s#*/} ;;
    https://github.com/*|http://github.com/*) s=${u#*://github.com/} ;;
    https://*@github.com/*)               s=${u#https://*@github.com/} ;;
    *) return 1 ;;
  esac
  s=${s%/}; s=${s%.git}
  case $s in
    */*/*|/*|*/|'') return 1 ;;
    */*) printf '%s\n' "$s" ;;
    *) return 1 ;;
  esac
}
