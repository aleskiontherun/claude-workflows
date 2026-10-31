#!/usr/bin/env bash
# Tests for ontherun-plan-fold-diff.sh. No framework: a throwaway git repo with two plans, one
# carrying the fold and the other a sibling session's uncommitted edit, and assertions on
# the path printed, the file written, and what it does and does not contain.
#
#   ontherun-plan-fold-diff.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs `git`.
#
# **The stranger's edit is present in every case that produces a diff.** Another session's
# uncommitted edit to a sibling plan is exactly what a diff of the directory would carry
# to the checker; a suite whose repo held only the plan under test could not tell this
# script from one that diffs the directory. The diff file is also compared byte-for-byte with `git diff` run
# here, so a script that re-serialised the diff would fail even with the right content.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FOLD="$SCRIPT_DIR/ontherun-plan-fold-diff.sh"

command -v git >/dev/null || { echo "git is required" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1" "expected |$2|" "actual   |$3|"; fi
}

assert_has() { # name needle haystack
  case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain |$2|" "got |$3|" ;; esac
}

assert_lacks() { # name needle haystack
  case $3 in *"$2"*) bad "$1" "expected NOT to contain |$2|" "got |$3|" ;; *) ok "$1" ;; esac
}

# stdout and stderr captured apart: the contract is that stdout is the path and nothing else.
run() { OUT=$("$FOLD" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

files_in() { find "$1" -type f | wc -l | tr -d ' '; }

# ------------------------------------------------------------------------- the repo
#
# Signing is forced off per invocation rather than configured into the repo: never
# `git config` a value into a repo to test something.
REPO="$TMP/repo"
mkdir -p "$REPO/plans"
g() { git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q
printf '# Plan A\n\nline one\n' > "$REPO/plans/a.md"
printf '# Plan B\n\nline one\n' > "$REPO/plans/b.md"
g add plans
g commit -q -m "two plans"

# The fold, and the stranger's edit beside it.
printf '# Plan A\n\nline one\nthe fold\n' > "$REPO/plans/a.md"
printf '# Plan B\n\nline one\nSTRANGER\n' > "$REPO/plans/b.md"

SCRATCH="$TMP/scratch"
export CLAUDE_SCRATCHPAD="$SCRATCH"

echo "ontherun-plan-fold-diff.sh"

# ---------------------------------------------------------- the fold against HEAD

OUT=$(cd "$REPO" && "$FOLD" plans/a.md 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
assert_eq "a relative plan from the repo root: exit 0" 0 "$RC"
assert_eq "  stdout is one line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
case $OUT in
  "$SCRATCH"/fold-a-*.diff) ok "  and it is a .diff under \$CLAUDE_SCRATCHPAD, named after the plan" ;;
  *) bad "  and it is a .diff under \$CLAUDE_SCRATCHPAD, named after the plan" "got |$OUT|" ;;
esac
if [ -f "$OUT" ]; then ok "  which exists"; else bad "  which exists" "$OUT"; fi
BODY=$(cat "$OUT" 2>/dev/null)
assert_has "  and carries the fold" "+the fold" "$BODY"
assert_lacks "  and not the stranger's edit to the sibling plan" "STRANGER" "$BODY"
assert_lacks "  nor the sibling plan's header" "plans/b.md" "$BODY"
assert_has "  stderr carries the line count" "plans/a.md against HEAD: +1 -0 lines" "$ERR"
assert_lacks "  and stdout does not" "lines" "$OUT"

if cmp -s "$OUT" <(git -C "$REPO" diff HEAD -- plans/a.md); then
  ok "  the file is byte-identical to git diff HEAD -- plans/a.md"
else
  bad "  the file is byte-identical to git diff HEAD -- plans/a.md" "$(cat "$OUT")"
fi

run "$REPO/plans/a.md"
assert_eq "an absolute plan from another cwd: exit 0" 0 "$RC"
assert_has "  same fold" "+the fold" "$(cat "$OUT")"

OUT=$(cd "$REPO/plans" && "$FOLD" a.md 2>/dev/null); RC=$?
assert_eq "a bare filename from inside plans/: exit 0" 0 "$RC"
assert_has "  same fold" "+the fold" "$(cat "$OUT")"

run "$REPO/plans/a.md" HEAD
assert_eq "HEAD spelled out is the default" 0 "$RC"

# -------------------------------------------------------- a committed fold, by ref

g add plans/a.md
g commit -q -m "the fold"

run "$REPO/plans/a.md"
assert_eq "a committed fold against the default HEAD: exit 1" 1 "$RC"
assert_has "  and says to pass the ref before it" "pass the ref before it (HEAD~1)" "$ERR"
assert_eq "  and prints no path" "" "$OUT"

run "$REPO/plans/a.md" HEAD~1
assert_eq "the same fold against HEAD~1: exit 0" 0 "$RC"
assert_has "  carries the fold" "+the fold" "$(cat "$OUT")"
assert_lacks "  and still not the stranger's edit" "STRANGER" "$(cat "$OUT")"
assert_has "  stderr names the ref" "against HEAD~1:" "$ERR"

run "$REPO/plans/a.md" "$(git -C "$REPO" rev-parse HEAD~1)"
assert_eq "a sha works as the ref" 0 "$RC"

# ----------------------------------------------------- nothing to hand over: no file

after_ok=$(files_in "$SCRATCH")
run "$REPO/plans/a.md"
assert_eq "an empty diff: exit 1" 1 "$RC"
assert_eq "  and no file left behind" "$after_ok" "$(files_in "$SCRATCH")"

run "$REPO/plans/a.md" no-such-ref
assert_eq "a ref git cannot resolve: exit 1" 1 "$RC"
assert_has "  says which" "cannot resolve no-such-ref" "$ERR"
assert_eq "  and no file left behind" "$after_ok" "$(files_in "$SCRATCH")"

printf '# New\n\nnever committed\n' > "$REPO/plans/new.md"
run "$REPO/plans/new.md"
assert_eq "an untracked plan: exit 1" 1 "$RC"
assert_has "  says it is untracked" "is not tracked" "$ERR"

run "$REPO/plans/missing.md"
assert_eq "a plan that does not exist: exit 1" 1 "$RC"
assert_has "  says so" "no such file" "$ERR"

mkdir -p "$TMP/norepo" && printf 'x\n' > "$TMP/norepo/p.md"
run "$TMP/norepo/p.md"
assert_eq "a plan outside any git repository: exit 1" 1 "$RC"
assert_has "  says so" "not inside a git repository" "$ERR"

run
assert_eq "no arguments: usage, exit 64" 64 "$RC"
run a b c
assert_eq "three arguments: usage, exit 64" 64 "$RC"

# ------------------------------------------------------------- where the file goes

printf '# Plan B\n\nline one\nthe other fold\n' > "$REPO/plans/b.md"
rm -rf "$SCRATCH"
run "$REPO/plans/b.md"
assert_eq "a scratchpad that does not exist yet is created" 0 "$RC"
case $OUT in "$SCRATCH"/fold-b-*.diff) ok "  and the file lands in it" ;; *) bad "  and the file lands in it" "$OUT" ;; esac

OUT=$(env -u CLAUDE_SCRATCHPAD "$FOLD" "$REPO/plans/b.md" 2>/dev/null); RC=$?
assert_eq "with CLAUDE_SCRATCHPAD unset: exit 0" 0 "$RC"
case $OUT in /tmp/fold-b-*.diff) ok "  and the file lands in /tmp" ;; *) bad "  and the file lands in /tmp" "$OUT" ;; esac
[ -n "$OUT" ] && rm -f "$OUT"

# Two folds of one plan inside a second do not overwrite each other.
run "$REPO/plans/b.md"; first_path=$OUT
run "$REPO/plans/b.md"; second_path=$OUT
if [ "$first_path" != "$second_path" ]; then
  ok "two runs in quick succession write two files"
else
  bad "two runs in quick succession write two files" "$first_path" "$second_path"
fi

# ----------------------------------------------------------- the single-repo layout
#
# plans/ is a git repo of its own inside a code checkout that excludes it. The diff is the
# plans repo's, and the code checkout's own uncommitted change is nowhere in it.

SOLO="$TMP/solo"
mkdir -p "$SOLO/plans"
s() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
s init -q "$SOLO"
echo 'plans/' >> "$SOLO/.git/info/exclude"
printf 'code\n' > "$SOLO/app.txt"
s -C "$SOLO" add app.txt && s -C "$SOLO" commit -q -m code
s init -q "$SOLO/plans"
printf '# Solo\n\nline one\n' > "$SOLO/plans/solo.md"
s -C "$SOLO/plans" add solo.md && s -C "$SOLO/plans" commit -q -m plan
printf '# Solo\n\nline one\nthe solo fold\n' > "$SOLO/plans/solo.md"
printf 'CODE EDIT\n' > "$SOLO/app.txt"

OUT=$(cd "$SOLO" && "$FOLD" plans/solo.md 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
assert_eq "single repo: a plan in the nested plans repo: exit 0" 0 "$RC"
assert_has "  carries the fold" "+the solo fold" "$(cat "$OUT" 2>/dev/null)"
assert_lacks "  and not the code checkout's own edit" "CODE EDIT" "$(cat "$OUT" 2>/dev/null)"
if cmp -s "$OUT" <(git -C "$SOLO/plans" diff HEAD -- solo.md); then
  ok "  byte-identical to the plans repo's git diff"
else
  bad "  byte-identical to the plans repo's git diff" "$(cat "$OUT")"
fi

# ------------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
