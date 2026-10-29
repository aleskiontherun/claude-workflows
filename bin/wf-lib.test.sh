#!/usr/bin/env bash
# Tests for wf-lib.sh, the functions the other wf- scripts source. No framework: throwaway
# repos with local bare origins, each function called directly, assertions on what it
# prints and returns.
#
#   wf-lib.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs git. git runs with per-command
# overrides only, never `git config` into a repo, and with signing off.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/wf-lib.sh
. "$SCRIPT_DIR/wf-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
T=$(cd "$TMP" && pwd -P)

pass=0
fail=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1" "expected |$2|" "actual   |$3|"; fi
}

g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

echo "wf-lib.sh"
unset WF_WORKSPACE

# ------------------------------------------------------------------------ wf_root

# A workspace repo: plans/ tracked at the root, a nested checkout beside it.
mkdir -p "$TMP/ws/plans/done" "$TMP/ws/app"
g init -q "$TMP/ws/app"
echo 'app/' > "$TMP/ws/.gitignore"
: > "$TMP/ws/plans/a.md"; : > "$TMP/ws/plans/done/b.md"
g init -q "$TMP/ws" && g -C "$TMP/ws" add -A && g -C "$TMP/ws" commit -q -m ws

assert_eq "wf_root: a plan in plans/ -> the parent of plans/" "$T/ws" "$(wf_root "$TMP/ws/plans/a.md")"
assert_eq "wf_root: a plan in plans/done/ -> the same root" "$T/ws" "$(wf_root "$TMP/ws/plans/done/b.md")"
assert_eq "wf_root: a relative path" "$T/ws" "$(cd "$TMP/ws/plans" && wf_root a.md)"
assert_eq "wf_root: \$WF_WORKSPACE wins" "$T/ws/app" "$(WF_WORKSPACE="$TMP/ws/app" wf_root "$TMP/ws/plans/a.md")"
if WF_WORKSPACE="$TMP/nowhere" wf_root "$TMP/ws/plans/a.md" >/dev/null 2>&1; then
  bad "wf_root: a \$WF_WORKSPACE that is not there fails"
else
  ok "wf_root: a \$WF_WORKSPACE that is not there fails"
fi

g -C "$TMP/ws" worktree add -q "$TMP/wt" -b wt
assert_eq "wf_root: a plan in a worktree of the workspace repo -> its main working tree" \
  "$T/ws" "$(wf_root "$TMP/wt/plans/a.md")"
assert_eq "wf_main_tree: a linked worktree -> the main checkout" "$T/ws" "$(wf_main_tree "$TMP/wt/plans")"
assert_eq "wf_main_tree: a main checkout -> itself" "$T/ws" "$(wf_main_tree "$TMP/ws/plans")"

# No plans/ ancestor: the git toplevel, else the plan's own directory.
mkdir -p "$TMP/repo/docs" "$TMP/bare/dir"
g init -q "$TMP/repo"; : > "$TMP/repo/docs/p.md"; : > "$TMP/bare/dir/p.md"
assert_eq "wf_root: no plans/ ancestor -> the git toplevel" "$T/repo" "$(wf_root "$TMP/repo/docs/p.md")"
assert_eq "wf_root: no git either -> the plan's directory" "$T/bare/dir" "$(wf_root "$TMP/bare/dir/p.md")"

# The single-repo layout: plans/ is a git repo nested in the code checkout.
mkdir -p "$TMP/solo/plans"
g init -q "$TMP/solo" && g init -q "$TMP/solo/plans"; : > "$TMP/solo/plans/s.md"
assert_eq "wf_root: a nested plans repo -> the code checkout around it" "$T/solo" "$(wf_root "$TMP/solo/plans/s.md")"
assert_eq "wf_plans_dir: the plans directory" "$T/solo/plans" "$(wf_plans_dir "$TMP/solo/plans/s.md")"
assert_eq "wf_plans_dir: from done/" "$T/ws/plans" "$(wf_plans_dir "$TMP/ws/plans/done/b.md")"
assert_eq "wf_plans_dir: no plans/ ancestor -> the plan's directory" "$T/repo/docs" "$(wf_plans_dir "$TMP/repo/docs/p.md")"

# ----------------------------------------------------------------- wf_default_ref

origin() { # name branch -> a bare origin whose HEAD is that branch, with one commit on it
  g init -q --bare -b "$2" "$TMP/$1.git"
  g clone -q "$TMP/$1.git" "$TMP/$1-seed" 2>/dev/null
  g -C "$TMP/$1-seed" commit -q --allow-empty -m one
  g -C "$TMP/$1-seed" push -q origin "HEAD:$2"
}
origin trunk trunk
g clone -q "$TMP/trunk.git" "$TMP/c1" 2>/dev/null
assert_eq "wf_default_ref: origin/HEAD, whatever the branch is called" origin/trunk "$(wf_default_ref "$TMP/c1")"

g -C "$TMP/c1" remote set-head origin --delete
assert_eq "  with origin/HEAD unset, set-head --auto restores it" origin/trunk "$(wf_default_ref "$TMP/c1")"

# A remote that cannot answer: no origin/HEAD and no set-head, so the fallbacks decide.
g init -q "$TMP/c2" && g -C "$TMP/c2" commit -q --allow-empty -m one
g -C "$TMP/c2" remote add origin "$TMP/gone.git"
g -C "$TMP/c2" update-ref refs/remotes/origin/master HEAD
assert_eq "  else origin/master when only it exists" origin/master "$(wf_default_ref "$TMP/c2" 2>/dev/null)"
g -C "$TMP/c2" update-ref refs/remotes/origin/main HEAD
assert_eq "  and origin/main ahead of origin/master" origin/main "$(wf_default_ref "$TMP/c2" 2>/dev/null)"
g init -q "$TMP/c3"
if wf_default_ref "$TMP/c3" >/dev/null 2>&1; then bad "  and nothing at all fails"; else ok "  and nothing at all fails"; fi

# ------------------------------------------------------------------------ wf_slug

g init -q "$TMP/s"
slug_of() { g -C "$TMP/s" remote remove origin 2>/dev/null; g -C "$TMP/s" remote add origin "$1"; wf_slug "$TMP/s" || echo -; }
for spec in "git@github.com:acme/a.git acme/a" "git@github.com:acme/a acme/a" \
            "ssh://git@github.com/acme/b.git acme/b" "ssh://git@github.com:22/acme/c.git acme/c" \
            "https://github.com/acme/d.git acme/d" "https://github.com/acme/e/ acme/e" \
            "http://github.com/acme/f acme/f" "https://tok@github.com/acme/h acme/h" \
            "git@gitlab.com:acme/w.git -" "https://github.com/acme -" "https://github.com/acme/x/y -" \
            "/srv/git/local.git -"; do
  url=${spec% *}; want=${spec##* }
  assert_eq "wf_slug: $url" "$want" "$(slug_of "$url")"
done
g -C "$TMP/s" remote remove origin
if wf_slug "$TMP/s" >/dev/null 2>&1; then bad "wf_slug: no origin fails"; else ok "wf_slug: no origin fails"; fi

# ------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
