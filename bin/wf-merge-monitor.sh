#!/usr/bin/env bash
# Watch one repo's plan-node merge queue and emit a line only when something changes.
#
#   wf-merge-monitor.sh [--once] <repo> <branch> [<branch> ...]
#
# <repo> is a checkout: an absolute path, or one relative to $WF_WORKSPACE when that is
# set, else to the current directory. Pass an absolute path when arming a session-length
# monitor -- a cwd that drifts must not point it at another checkout. The branches are
# the plan's still-eligible branches in that repo, IN QUEUE ORDER -- the order the
# conduct skill's merge queue derives, which is not PR order. Every `gh` call names
# the repo with `-R <owner>/<name>`, read from the checkout's `origin`; a checkout whose
# origin is not on github.com is queried from its own directory instead.
#
# One `gh pr list --state all --limit 100` per poll covers every PR in the repo, and the
# snapshot is its rows for the given branches, in the order given, matched by full branch
# name (never a prefix: node ids repeat across plans), then one line for the head: the
# first branch whose row is `OPEN draft=false`, with its checks rolled up to
# pass | pending | fail (a cancelled check is a fail; skipping counts as pass), `none`
# while no check has registered yet, or `query-failed: <reason>`.
#
# --once prints one snapshot and exits with its status instead of polling. Run it before
# arming, to check the half no test can: the repo, the branch names and their order.
#
# Exit status of a snapshot, which the poll loop reads:
#   0  good
#   1  no rows -- `gh pr list` failed, nothing was learned
#   2  rows good, the head's check state unknown
# 64 on usage; 1 when <repo> cannot be entered.
#
# The poll loop prints the baseline once, then only what changed: the rows as a block (a
# row that disappears is a change), the head line on its own. A failing pass is counted,
# not reported: nothing is said until four consecutive polls fail, then one
# `query-failed for 4 polls` line, and one `query-recovered` line when it ends. While
# only `gh pr checks` fails, row changes and a head that moved are still emitted and the
# head's check state holds its last known value -- unknown is not changed.
#
# Each `gh` call is bounded at 30s and retried three times with 5s backoff; a hang is a
# failed attempt, `no checks reported` is an expected state and is not retried. Why the
# queue works this way -- only the head is prepared for merge, `tip` shows pushes the
# other fields cannot -- is the conduct skill's to say and is not repeated here.
#
# Needs bash, gh and jq. wf-merge-monitor.test.sh beside this file covers every state
# above against a stubbed `gh` that runs this script's own --jq expressions.

set -u

# Testing knobs, all three: the conduct skill specifies a 60s poll, and the 5s backoff
# and 30s bound are what absorb a flapping network. The test turns them down.
interval=${WF_MERGE_MONITOR_INTERVAL:-60}
backoff=${WF_MERGE_MONITOR_BACKOFF:-5}
call_timeout=${WF_MERGE_MONITOR_TIMEOUT:-30}

wf_here() { # this script's directory, symlinks resolved
  local s=${BASH_SOURCE[0]} d
  while [ -L "$s" ]; do
    d=$(cd -P -- "$(dirname -- "$s")" && pwd)
    s=$(readlink -- "$s"); case $s in /*) ;; *) s=$d/$s ;; esac
  done
  cd -P -- "$(dirname -- "$s")" && pwd
}
# shellcheck source=SCRIPTDIR/wf-lib.sh
. "$(wf_here)/wf-lib.sh" || exit 1

once=false
[ "${1:-}" = "--once" ] && { once=true; shift; }

if [ "$#" -lt 2 ]; then
  printf 'usage: %s [--once] <repo> <branch> [<branch> ...]\n' "${0##*/}" >&2
  exit 64
fi

repo=$1; shift
BRANCHES=("$@")

case $repo in
  /*) repo_path=$repo ;;
  *)  repo_path=${WF_WORKSPACE:+$WF_WORKSPACE/}$repo ;;
esac
cd -- "$repo_path" || exit 1

# `-R` rather than the cwd alone: gh resolves a repo from the directory, and a checkout
# nested in a workspace repo with its own GitHub remote is one wrong directory away from
# a repo with no PRs, which answers an empty list and exit 0.
R=()
if slug=$(wf_slug .); then R=(-R "$slug"); fi

# One call, bounded: a hang is a failed attempt. TERM rather than an alarm, because gh
# is a Go binary and Go ignores SIGALRM. Output goes to a file rather than a pipe so
# that a child surviving the kill cannot hold the caller's $(...) open.
gh_bounded() {
  local f pid wd rc
  f=$(mktemp "${TMPDIR:-/tmp}/wf-merge-monitor.XXXXXX") || return 1
  "$@" >"$f" 2>&1 &
  pid=$!
  (
    sleep "$call_timeout" & s=$!
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    wait "$s"
    : >"$f.timeout"
    kill -TERM "$pid" 2>/dev/null
    sleep 2 & s=$!
    wait "$s"
    kill -KILL "$pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [ $rc -ne 0 ] && [ -e "$f.timeout" ]; then
    printf 'gh: no response after %ss\n' "$call_timeout"
  else
    cat "$f"
  fi
  rm -f "$f" "$f.timeout"
  return $rc
}

# gh's API bursts-fail on some networks while git and curl over the same link are fine.
# Reported straight through, one flap costs two events -- the failure and the recovery.
# `no checks reported` is an expected state rather than a failure, so it breaks out
# rather than burning three attempts and ten seconds of backoff. gh_bounded's 2>&1 is
# what puts gh's message where the callers' `case` arms can match it.
gh_retry() {
  local out rc i
  for i in 1 2 3; do
    out=$(gh_bounded "$@"); rc=$?
    [ $rc -eq 0 ] && { printf '%s' "$out"; return 0; }
    case $out in *'no checks reported'*) printf '%s' "$out"; return 1 ;; esac
    [ $i -lt 3 ] && sleep "$backoff"
  done
  printf '%s' "$out"; return 1
}

# One `gh pr list` covers every PR in the repo; the snapshot must show only this plan's
# branches, so the call captures into $rows and the walk below is what prints.
snapshot() {
  local rows head row out rc b line
  rows=$(gh_retry gh pr list ${R[@]+"${R[@]}"} --state all --limit 100 \
    --json number,headRefName,state,isDraft,headRefOid \
    --jq '.[] | "\(.headRefName) pr=\(.number) \(.state) draft=\(.isDraft) tip=\(.headRefOid[0:7])"') \
    || { printf 'query-failed: gh pr list\n'; return 1; }

  head=""
  rc=0
  for b in "${BRANCHES[@]}"; do
    [ -n "$b" ] || continue
    row=""
    while IFS= read -r line; do
      case $line in "$b "*) row=$line; break ;; esac
    done <<<"$rows"
    [ -n "$row" ] || continue
    printf '%s\n' "$row"
    if [ -z "$head" ]; then
      case $row in *" OPEN draft=false "*) head=$b ;; esac
    fi
  done

  # Guard the empty head before calling: `gh pr checks ""` falls back to the current
  # branch, which in a checkout sitting on main is a human-facing failure for the
  # ordinary state of a monitor armed alongside its wave.
  if [ -z "$head" ]; then
    printf 'head: none eligible\n'
  else
    out=$(gh_retry gh pr checks "$head" ${R[@]+"${R[@]}"} --json bucket --jq '[.[].bucket]
      | if any(. == "fail" or . == "cancel") then "fail"
        elif any(. == "pending") then "pending"
        else "pass" end') \
      || case $out in
           *'no checks reported'*) out=none ;;
           *) out="query-failed: ${out%%$'\n'*}"; rc=2 ;;
         esac
    printf 'head %s: checks=%s\n' "$head" "$out"
  fi
  return $rc
}

if $once; then
  snapshot
  exit $?
fi

split_snapshot() {            # $1 -> s_rows (all but the last line), s_head (the last)
  s_head=${1##*$'\n'}
  case $1 in
    *$'\n'*) s_rows=${1%$'\n'*} ;;
    *)       s_rows="" ;;
  esac
}

fails=0
prev_rows=""; prev_head=""
base=$(snapshot); st=$?
printf '%s\n' "$base"         # the baseline, printed once - a failed one included
if [ $st -ne 1 ]; then
  split_snapshot "$base"
  prev_rows=$s_rows
  [ $st -eq 0 ] && prev_head=$s_head
fi
[ $st -eq 0 ] || fails=1

while true; do
  sleep "$interval"
  cur=$(snapshot); st=$?

  if [ $st -eq 1 ]; then      # no rows: nothing was learned, so say nothing yet
    fails=$((fails + 1))
    [ $fails -eq 4 ] && printf 'query-failed for 4 polls: %s\n' "${cur#query-failed: }"
    continue                  # prev_* untouched: a burst moves no baseline
  fi

  split_snapshot "$cur"

  if [ $st -eq 2 ]; then      # rows are good; only the head's checks are unknown
    fails=$((fails + 1))
    [ $fails -eq 4 ] && printf 'query-failed for 4 polls: gh pr checks: %s\n' \
      "${s_head##*checks=query-failed: }"
    [ "$s_rows" = "$prev_rows" ] || { printf '%s\n' "$s_rows"; prev_rows=$s_rows; }
    # WHICH branch is head is derived from the rows and is known; only its checks
    # are not. A head that moved is queue news and cannot flap on the network.
    [ "${s_head%%: checks=*}" = "${prev_head%%: checks=*}" ] \
      || { printf '%s\n' "$s_head"; prev_head=$s_head; }
    continue                  # otherwise prev_head stands: unknown is not changed
  fi

  [ $fails -ge 4 ] && printf 'query-recovered after %d polls\n' "$fails"
  fails=0
  [ "$s_rows" = "$prev_rows" ] || { printf '%s\n' "$s_rows"; prev_rows=$s_rows; }
  [ "$s_head" = "$prev_head" ] || { printf '%s\n' "$s_head"; prev_head=$s_head; }
done
