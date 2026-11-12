#!/usr/bin/env bash
# Tests for ontherun-lease.sh. No framework: a throwaway lease directory, throwaway owner
# directories, and assertions on the slot printed, the exit status and the lease files.
#
#   ontherun-lease.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs `git` and `perl`.
#
# **Staleness is tested by what makes a lease stale, not by waiting**: an owner directory
# is removed, or a lease file's renewal time is rewritten into the past. The --wait cases
# and the concurrent ones do run real processes against each other, with the poll
# shortened to a second.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LEASE="$SCRIPT_DIR/ontherun-lease.sh"

command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v perl >/dev/null || { echo "perl is required" >&2; exit 2; }

TMP=$(mktemp -d)
TMP=$(cd -- "$TMP" && pwd -P)
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

check() { # name command...
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name" "false: $*"; fi
}

export ONTHERUN_LEASE_DIR="$TMP/leases"
export ONTHERUN_LEASE_POLL=1
unset ONTHERUN_LEASE_TTL

# stdout and stderr captured apart: acquire's contract is that stdout is the slot alone.
run() { OUT=$("$LEASE" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

fresh() { rm -rf "$ONTHERUN_LEASE_DIR"; }
owner() { mkdir -p "$TMP/owners/$1"; printf '%s\n' "$TMP/owners/$1"; }
age() { # pool slot seconds -- rewrite a lease's renewal time into the past
  local f=$ONTHERUN_LEASE_DIR/$1/$2 o
  o=$(sed -n 2p "$f")
  printf '%s\n%s\n' "$(($(date +%s) - $3))" "$o" >"$f"
}

A=$(owner a); B=$(owner b); C=$(owner c)

echo "ontherun-lease.sh"

# ---------------------------------------------------------------------------- acquire
echo "acquire"
fresh
run acquire dev 2 --owner "$A"
assert_eq "first owner gets slot 1" "0:1" "$RC:$OUT"
assert_eq "  and stderr is empty" "" "$ERR"
run acquire dev 2 --owner "$B"
assert_eq "second owner gets slot 2" "0:2" "$RC:$OUT"
run acquire dev 2 --owner "$C"
assert_eq "third owner of a pool of two is refused" "1:" "$RC:$OUT"
assert_has "  and is told who holds the slots" "$A" "$ERR"
assert_has "  both of them" "$B" "$ERR"

age dev 2 100
run acquire dev 2 --owner "$B"
assert_eq "the same owner gets the same slot back" "0:2" "$RC:$OUT"
stamp=$(sed -n 1p "$ONTHERUN_LEASE_DIR/dev/2")
check "  with the lease renewed" [ $(($(date +%s) - stamp)) -lt 50 ]

run acquire other 1 --owner "$C"
assert_eq "pools are independent" "0:1" "$RC:$OUT"

# ---------------------------------------------------------------------------- release
echo "release"
run release dev --owner "$A"
assert_eq "release exits 0" 0 "$RC"
assert_has "  and says which slot" "released dev slot 1" "$ERR"
check "  and the lease file is gone" [ ! -e "$ONTHERUN_LEASE_DIR/dev/1" ]
check "  and another owner's lease stays" [ -e "$ONTHERUN_LEASE_DIR/dev/2" ]
run release dev --owner "$A"
assert_eq "releasing nothing exits 0" 0 "$RC"
assert_has "  and says so" "holds no slot" "$ERR"
run acquire dev 2 --owner "$C"
assert_eq "the freed slot is the next one handed out" "0:1" "$RC:$OUT"

# -------------------------------------------------------------------------- staleness
echo "staleness"
fresh
G=$(owner gone)
run acquire dev 1 --owner "$G"
run acquire dev 1 --owner "$A"
assert_eq "a live lease is not taken" 1 "$RC"
rm -rf "$G"
run acquire dev 1 --owner "$A"
assert_eq "a lease whose owner directory is gone is taken" "0:1" "$RC:$OUT"

age dev 1 21000
run acquire dev 1 --owner "$B"
assert_eq "a lease younger than the TTL is not taken" 1 "$RC"
age dev 1 22000
run acquire dev 1 --owner "$B"
assert_eq "a lease older than the TTL is taken" "0:1" "$RC:$OUT"

age dev 1 999999
ONTHERUN_LEASE_TTL=0 run acquire dev 1 --owner "$A"
assert_eq "TTL 0 never expires a lease whose owner exists" 1 "$RC"
ONTHERUN_LEASE_TTL=10 run acquire dev 1 --owner "$A"
assert_eq "a shorter TTL from the environment applies" "0:1" "$RC:$OUT"

printf 'garbage\n' >"$ONTHERUN_LEASE_DIR/dev/1"
run acquire dev 1 --owner "$B"
assert_eq "a lease file that does not parse is taken" "0:1" "$RC:$OUT"

# ----------------------------------------------------------------------- default owner
echo "default owner"
fresh
REPO="$TMP/repo"
mkdir -p "$REPO/sub/dir"
git -C "$REPO" init -q
OUT=$(cd "$REPO/sub/dir" && "$LEASE" acquire dev 3 2>/dev/null)
assert_eq "from inside a checkout, acquire succeeds" 1 "$OUT"
assert_eq "  owned by the git top level" "$REPO" "$(sed -n 2p "$ONTHERUN_LEASE_DIR/dev/1")"
PLAIN="$TMP/plain"
mkdir -p "$PLAIN"
OUT=$(cd "$PLAIN" && GIT_CEILING_DIRECTORIES="$TMP" "$LEASE" acquire dev 3 2>/dev/null)
assert_eq "outside any checkout, acquire succeeds" 2 "$OUT"
assert_eq "  owned by the working directory" "$PLAIN" "$(sed -n 2p "$ONTHERUN_LEASE_DIR/dev/2")"
(cd "$REPO" && "$LEASE" release dev 2>/dev/null)
check "release finds the same default owner" [ ! -e "$ONTHERUN_LEASE_DIR/dev/1" ]

# ------------------------------------------------------------------------ list and reap
echo "list and reap"
fresh
G=$(owner gone)
run acquire dev 3 --owner "$A"
run acquire dev 3 --owner "$G"
run acquire other 1 --owner "$B"
rm -rf "$G"
age dev 1 40
run list
assert_eq "list exits 0" 0 "$RC"
assert_eq "  one line per lease, in every pool" 3 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_has "  a held lease, with its age and owner" "dev	1	held	4" "$OUT"
assert_has "  a stale one" "dev	2	stale	" "$OUT"
assert_has "  the other pool" "other	1	held	" "$OUT"
check "  and list removes nothing" [ -e "$ONTHERUN_LEASE_DIR/dev/2" ]
run list other
assert_eq "list <pool> prints that pool only" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
run reap
assert_has "reap reports the stale lease" "dev	2	reaped	" "$OUT"
check "  and removes it" [ ! -e "$ONTHERUN_LEASE_DIR/dev/2" ]
check "  and keeps the held one" [ -e "$ONTHERUN_LEASE_DIR/dev/1" ]
fresh
run list
assert_eq "list with no leases at all prints nothing and exits 0" "0:" "$RC:$OUT"

# --------------------------------------------------------------------------------- wait
echo "wait"
fresh
run acquire dev 1 --owner "$A"
( sleep 2; "$LEASE" release dev --owner "$A" 2>/dev/null ) &
run acquire dev 1 --owner "$B" --wait 20
assert_eq "--wait gets the slot once it is released" "0:1" "$RC:$OUT"
wait
start=$(date +%s)
run acquire dev 1 --owner "$C" --wait 2
assert_eq "--wait gives up when nothing frees" 1 "$RC"
check "  after waiting" [ $(($(date +%s) - start)) -ge 2 ]

# -------------------------------------------------------------------------- concurrency
echo "concurrency"
fresh
mkdir -p "$TMP/par"
for i in $(seq 1 12); do
  o=$(owner "p$i")
  ( "$LEASE" acquire dev 5 --owner "$o" >"$TMP/par/$i" 2>/dev/null ) &
done
wait
got=$(cat "$TMP/par"/* | sort -n | tr '\n' ' ')
assert_eq "twelve owners racing for five slots get five distinct ones" "1 2 3 4 5 " "$got"
assert_eq "  and five lease files" 5 "$(find "$ONTHERUN_LEASE_DIR/dev" -type f | wc -l | tr -d ' ')"

# -------------------------------------------------------------------------------- usage
echo "usage"
fresh
for case in "" "frobnicate" "acquire" "acquire dev" "acquire dev 0" "acquire dev x" \
  "acquire ../up 2" "acquire .hidden 2" "acquire dev 2 extra" "acquire dev 2 --wait" \
  "acquire dev 2 --wait soon" "acquire dev 2 --bogus" "release" "release dev --wait 3" \
  "list a b" "list dev --owner $A" "reap a b"; do
  # shellcheck disable=SC2086  # each case is a word list
  run $case
  assert_eq "usage: |$case| exits 64" 64 "$RC"
done
check "a usage error creates nothing" [ ! -e "$ONTHERUN_LEASE_DIR" ]
run acquire dev 2 --owner "$TMP/nowhere"
assert_eq "an owner that is not a directory exits 2" 2 "$RC"
ONTHERUN_LEASE_TTL=soon run acquire dev 2 --owner "$A"
assert_eq "a TTL that is not a number exits 2" 2 "$RC"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
