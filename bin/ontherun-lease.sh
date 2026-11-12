#!/usr/bin/env bash
# Lease one slot of a fixed-size pool of a machine-wide resource that sessions on this
# machine would otherwise each create afresh and leave behind -- a device simulator, a
# local port, a scratch database. The pool's size bounds how many exist; a slot is a
# number, and what it stands for is the project's to say (slot 3 of pool `device` is the
# device named `agent-device-3`, port 8003, ...).
#
#   ontherun-lease.sh acquire <pool> <size> [--owner <dir>] [--wait <seconds>]
#   ontherun-lease.sh release <pool> [--owner <dir>]
#   ontherun-lease.sh list [<pool>]
#   ontherun-lease.sh reap [<pool>]
#
# acquire  prints the slot number, 1..<size>, on stdout and nothing else. An owner that
#          already holds a slot of the pool gets the same one back with its lease
#          renewed, so run it again before each stretch of use. With every slot held it
#          exits 1 at once, or, given --wait, retries until a slot frees or the seconds
#          run out. Stale leases count as free.
# release  gives up every slot of the pool the owner holds. Exits 0 when it held none.
# list     prints one line per lease, tab-separated: pool, slot, `held` or `stale`, age
#          in seconds, owner.
# reap     removes the stale leases and prints what list prints, with `reaped` in place
#          of `stale` on each lease it removed.
#
# The owner is a directory: --owner, else the git top level of the working directory,
# else the working directory. A session in its own worktree therefore owns its lease
# without naming itself, and two sessions sharing one checkout share one lease unless
# each passes its own --owner. A directory rather than a process, because every command
# an agent runs is a new short-lived shell: no process outlives the call to vouch for the
# lease.
#
# A lease is stale when its owner directory no longer exists, or when it has not been
# renewed for ONTHERUN_LEASE_TTL seconds. Nothing has to run for a crashed or forgotten
# session's slot to come back: the next acquire takes it. Whatever state the previous
# holder left in the resource is still there, so reset the resource after acquiring it,
# never on release.
#
# Exit codes: 0 done; 1 acquire found no free slot; 2 cannot run (no perl, state
# directory unwritable, owner is not a directory); 64 usage.
#
# Env:
#   ONTHERUN_LEASE_DIR   where leases are kept; default ~/.claude/ontherun/leases. One
#                        file per lease, <pool>/<slot>, holding the renewal time (epoch
#                        seconds) and the owner on two lines.
#   ONTHERUN_LEASE_TTL   seconds an unrenewed lease stays held; default 21600 (six
#                        hours); 0 means only a vanished owner makes a lease stale.
#   ONTHERUN_LEASE_POLL  seconds between retries under --wait; default 5.
#
# Every command runs under one flock on <ONTHERUN_LEASE_DIR>/.lock, which the kernel
# drops when the process dies, so a killed run never leaves the pool locked.
#
# Needs bash, perl (for flock) and, for the default owner, git.
# ontherun-lease.test.sh beside this file covers each command, staleness and concurrent
# acquires.

set -u

me=ontherun-lease

usage() {
  cat >&2 <<EOF
usage: ${0##*/} acquire <pool> <size> [--owner <dir>] [--wait <seconds>]
       ${0##*/} release <pool> [--owner <dir>]
       ${0##*/} list [<pool>]
       ${0##*/} reap [<pool>]
EOF
  exit 64
}
cannot() { printf '%s: %s\n' "$me" "$*" >&2; exit 2; }

is_uint() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }
is_pool() { case $1 in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

[ "$#" -ge 1 ] || usage
cmd=$1; shift

owner_arg=""
wait_s=0
args=()
while [ "$#" -gt 0 ]; do
  case $1 in
    --owner) [ "$#" -ge 2 ] || usage; owner_arg=$2; shift 2 ;;
    --wait)  if [ "$#" -lt 2 ] || ! is_uint "$2"; then usage; fi; wait_s=$2; shift 2 ;;
    -*) usage ;;
    *) args+=("$1"); shift ;;
  esac
done

pool=""
size=0
case $cmd in
  acquire)
    [ "${#args[@]}" -eq 2 ] || usage
    pool=${args[0]}; size=${args[1]}
    is_pool "$pool" || usage
    is_uint "$size" && [ "$size" -ge 1 ] || usage
    ;;
  release)
    [ "${#args[@]}" -eq 1 ] && [ "$wait_s" -eq 0 ] || usage
    pool=${args[0]}
    is_pool "$pool" || usage
    ;;
  list|reap)
    [ "${#args[@]}" -le 1 ] && [ -z "$owner_arg" ] && [ "$wait_s" -eq 0 ] || usage
    if [ "${#args[@]}" -eq 1 ]; then pool=${args[0]}; is_pool "$pool" || usage; fi
    ;;
  *) usage ;;
esac

root=${ONTHERUN_LEASE_DIR:-$HOME/.claude/ontherun/leases}
ttl=${ONTHERUN_LEASE_TTL:-21600}
poll=${ONTHERUN_LEASE_POLL:-5}
is_uint "$ttl" || cannot "ONTHERUN_LEASE_TTL is not a number of seconds: $ttl"
is_uint "$poll" && [ "$poll" -ge 1 ] || cannot "ONTHERUN_LEASE_POLL is not a positive number of seconds: $poll"

owner=""
case $cmd in
  acquire|release)
    if [ -n "$owner_arg" ]; then
      owner=$(cd -- "$owner_arg" 2>/dev/null && pwd -P) || cannot "owner is not a directory: $owner_arg"
    else
      owner=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$owner" ] || owner=$PWD
      owner=$(cd -- "$owner" 2>/dev/null && pwd -P) || cannot "cannot resolve the working directory"
    fi
    case $owner in *$'\n'*) cannot "owner path contains a newline" ;; esac
    ;;
esac

command -v perl >/dev/null 2>&1 || cannot "perl is required (for flock)"
mkdir -p -- "$root" 2>/dev/null || cannot "cannot create $root"

# The lock lives on fd 9's open file description, which this shell keeps after perl
# exits; closing the fd, or dying, releases it.
lock() {
  exec 9>>"$root/.lock" || cannot "cannot open $root/.lock"
  perl -e 'use Fcntl qw(:flock); open(my $fh, ">&=", 9) or exit 1; flock($fh, LOCK_EX) or exit 1' \
    || cannot "cannot lock $root/.lock"
}
unlock() { exec 9>&-; }

# A lease file -> S_STAMP and S_OWNER; non-zero when there is no such lease.
read_slot() {
  S_STAMP=""; S_OWNER=""
  [ -f "$1" ] || return 1
  { IFS= read -r S_STAMP; IFS= read -r S_OWNER; } <"$1" 2>/dev/null
  return 0
}

# Whether the lease last read is stale. A file that does not parse is stale too: nobody
# can be shown to hold it.
stale() {
  is_uint "$S_STAMP" || return 0
  [ -n "$S_OWNER" ] && [ -d "$S_OWNER" ] || return 0
  [ "$ttl" -gt 0 ] && [ $((now - S_STAMP)) -gt "$ttl" ] && return 0
  return 1
}

write_slot() { # file
  printf '%s\n%s\n' "$now" "$owner" >"$1.tmp" && mv -f -- "$1.tmp" "$1"
}

# The slot numbers that have a lease file in a pool, ascending.
slots_of() { # pool
  local f n
  for f in "$root/$1"/*; do
    n=${f##*/}
    is_uint "$n" && [ -f "$f" ] && printf '%s\n' "$n"
  done | sort -n
}

pools() {
  local d
  if [ -n "$pool" ]; then printf '%s\n' "$pool"; return; fi
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    printf '%s\n' "${d##*/}"
  done
}

line() { # pool slot state
  local age=0
  is_uint "$S_STAMP" && age=$((now - S_STAMP))
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$age" "$S_OWNER"
}

try_acquire() {
  local n f
  mkdir -p -- "$root/$pool" 2>/dev/null || cannot "cannot create $root/$pool"
  for ((n = 1; n <= size; n++)); do
    f=$root/$pool/$n
    if read_slot "$f" && [ "$S_OWNER" = "$owner" ]; then
      write_slot "$f" || cannot "cannot write $f"
      printf '%s\n' "$n"; return 0
    fi
  done
  for ((n = 1; n <= size; n++)); do
    f=$root/$pool/$n
    if ! read_slot "$f" || stale; then
      write_slot "$f" || cannot "cannot write $f"
      printf '%s\n' "$n"; return 0
    fi
  done
  return 1
}

case $cmd in
  acquire)
    deadline=$(($(date +%s) + wait_s))
    while :; do
      lock; now=$(date +%s)
      if try_acquire; then unlock; exit 0; fi
      unlock
      [ "$now" -lt "$deadline" ] || break
      sleep "$poll"
    done
    printf '%s: no free slot in pool %s (size %s); held by:\n' "$me" "$pool" "$size" >&2
    for n in $(slots_of "$pool"); do
      read_slot "$root/$pool/$n" && printf '  %s\t%s\n' "$n" "$S_OWNER" >&2
    done
    exit 1
    ;;
  release)
    lock; now=$(date +%s)
    freed=""
    for n in $(slots_of "$pool"); do
      if read_slot "$root/$pool/$n" && [ "$S_OWNER" = "$owner" ]; then
        rm -f -- "$root/$pool/$n" && freed="$freed $n"
      fi
    done
    unlock
    if [ -n "$freed" ]; then printf '%s: released %s slot%s\n' "$me" "$pool" "$freed" >&2
    else printf '%s: %s holds no slot of pool %s\n' "$me" "$owner" "$pool" >&2; fi
    ;;
  list|reap)
    lock; now=$(date +%s)
    for p in $(pools); do
      for n in $(slots_of "$p"); do
        read_slot "$root/$p/$n" || continue
        if ! stale; then line "$p" "$n" held
        elif [ "$cmd" = list ]; then line "$p" "$n" stale
        else rm -f -- "$root/$p/$n" && line "$p" "$n" reaped
        fi
      done
    done
    unlock
    ;;
esac
exit 0
