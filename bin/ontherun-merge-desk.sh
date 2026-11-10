#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs and GraphQL documents carry their own $names
# The merge desk: take reports of pull requests that are ready to merge, and add them to
# GitHub's merge queue in the order they were reported.
#
#   ontherun-merge-desk.sh submit <pr> [--from <name>] [--sha <oid>]
#   ontherun-merge-desk.sh run [--once]
#   ontherun-merge-desk.sh watch
#   ontherun-merge-desk.sh status
#   ontherun-merge-desk.sh outbox
#   ontherun-merge-desk.sh told <seq> [<seq> ...]
#
# <pr> is a pull request URL or `owner/name#number`.
#
# Adding a PR to the merge queue is the only thing this script changes on GitHub. It never
# merges, pushes, rebases, re-runs a check, marks a draft ready, approves or dequeues, and
# a repo without a merge queue gets no direct merge instead: GitHub refuses, and the PR is
# sent back. Everything else it does is read a PR's state and write its own ledger.
#
# submit   Report one PR as ready, for the commit it stands at (or `--sha`, when the
#          reporter vouches for a particular one). `--from` is the name the desk's session
#          can message the reporter under. A PR the desk could only send straight back --
#          closed, merged, a draft, conflicting, failing checks, a head that is not
#          `--sha` -- is refused here, with the reason, and never enters the line. A PR
#          already in the line at the same commit is not added twice; reported again at a
#          new commit, it leaves its place and joins the back.
# run      Every poll, for each repo with PRs in the line: look at the PRs already in
#          GitHub's queue, then walk the waiting ones in report order and enqueue each.
#          One line is printed per thing that happened, and appended to run.log beside
#          the ledger. `--once` makes one pass, prints its lines and exits. One `run` loop
#          per ledger: a second exits 1 while the first is alive.
# watch    Follow run.log from now on, printing each new line: the loop's lines without
#          the loop's lifetime, for a watcher that expires and is armed again.
# status   The line as it stands, one row per PR still waiting, in GitHub's queue, or
#          finished with nobody told, then whether a `run` loop is alive.
# outbox   The outcomes nobody has been told about, one row each: a PR that merged, or one
#          sent back with its reason. A row stays until `told` names it.
# told     Mark those outcomes as delivered to whoever reported the PR.
#
# The line is strict per repo. A waiting PR is one of:
#   enqueued   its head is the reported commit and GitHub says it can merge
#   held       GitHub has not finished its checks or its mergeability; everything behind
#              it in that repo waits, for at most $ONTHERUN_MERGE_DESK_HOLD_MINUTES
#   sent back  it cannot be enqueued, with one of the reasons below
# and a PR in GitHub's queue stays the desk's until it merges or GitHub takes it out,
# which sends it back too. A PR that is sent back has left the line: reported again, it
# joins the back. A pass that gets no answer from GitHub about a PR learns nothing, so it
# records nothing and that repo's line holds until the next pass.
#
# Reasons a PR is sent back: closed, head_moved, draft, conflict, checks_failed,
# review_required, timed_out (held too long), refused (GitHub would not enqueue it; its
# message is the detail), dequeued (someone took it out of the queue by hand), removed
# (GitHub took it out for a reason this script has no word for; the detail carries it).
#
# What `run` prints, one line each:
#   enqueued <repo>#<n> position=<p> from="<name>"
#   enqueued <repo>#<n> by=other from="<name>"     it was already in GitHub's queue
#   holding <repo>#<n> for=checks|mergeability
#   merged <repo>#<n> tell="<name>"
#   sent-back <repo>#<n> reason=<reason> tell="<name>"
#   broken: <why>                                  the loop then exits 1
#
# Environment:
#   ONTHERUN_MERGE_DESK_DIR            the ledger's directory; default
#                                      ${XDG_STATE_HOME:-$HOME/.local/state}/ontherun/merge-desk
#   ONTHERUN_MERGE_DESK_HOLD_MINUTES   how long a held PR keeps the line; default 30
#
# Exit status: 0 done; 1 a submit that was refused, a GitHub call that failed, a second
# `run`, a ledger that does not parse, an unknown <seq>; 64 on usage.
#
# Needs bash, gh and jq. ontherun-merge-desk.test.sh beside this file covers every state
# above against a stubbed `gh`.

set -u

# Testing knobs: the poll and the bound on one `gh` call.
interval=${WF_MERGE_DESK_INTERVAL:-60}
call_timeout=${WF_MERGE_DESK_TIMEOUT:-30}

hold_minutes=${ONTHERUN_MERGE_DESK_HOLD_MINUTES:-30}
dir=${ONTHERUN_MERGE_DESK_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ontherun/merge-desk}
ledger=$dir/ledger.jsonl

wf_here() { # this script's directory, symlinks resolved
  local s=${BASH_SOURCE[0]} d
  while [ -L "$s" ]; do
    d=$(cd -P -- "$(dirname -- "$s")" && pwd)
    s=$(readlink -- "$s"); case $s in /*) ;; *) s=$d/$s ;; esac
  done
  cd -P -- "$(dirname -- "$s")" && pwd
}
# shellcheck source=SCRIPTDIR/ontherun-lib.sh
. "$(wf_here)/ontherun-lib.sh" || exit 1

usage() {
  printf 'usage: %s submit <pr> [--from <name>] [--sha <oid>]\n' "${0##*/}" >&2
  printf '       %s run [--once] | watch | status | outbox | told <seq> [<seq> ...]\n' "${0##*/}" >&2
  exit 64
}
die() { printf 'merge-desk: %s\n' "$*" >&2; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ------------------------------------------------------------------------- the ledger
#
# One JSON record per line, appended and never rewritten: `reported` opens an entry under
# a new seq, and `held`, `enqueued`, `merged`, `sent_back` and `told` each name the seq
# they are about. The state of the line is the fold of those records, so a `run` loop
# that dies loses nothing and a second reader never sees a half-written state.

# A directory is the lock, because mkdir is atomic everywhere and flock is not everywhere.
# A lock whose holder is gone is taken over: its pid is dead, or it never wrote one and the
# lock is over a minute old.
lock() { # name tries -> 0 when taken
  local l=$dir/$1.lock i=0 pid
  while ! mkdir "$l" 2>/dev/null; do
    pid=$(cat "$l/pid" 2>/dev/null) || pid=""
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$l"; continue; fi
    if [ -z "$pid" ] && [ -n "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$l"; continue
    fi
    i=$((i + 1))
    [ "$i" -ge "$2" ] && return 1
    sleep 0.2
  done
  printf '%s\n' "$$" > "$l/pid"
}
unlock() { rm -rf "${dir:?}/$1.lock"; }

record() { # jq arguments building one record -> appended
  local line
  line=$(jq -nc --arg at "$(now_iso)" "$@") || return 1
  lock ledger 100 || { printf 'merge-desk: the ledger is locked\n' >&2; return 1; }
  printf '%s\n' "$line" >> "$ledger"
  unlock ledger
}

FOLD='
  reduce .[] as $r ({};
    ($r.seq | tostring) as $k
    | if $r.type == "reported" then .[$k] = ($r | del(.type) | .status = "waiting")
      elif .[$k] == null then .
      elif $r.type == "held" then .[$k].held_at //= $r.at
      elif $r.type == "enqueued" then .[$k] += {status: "enqueued", enqueued_at: $r.enqueued_at}
      elif $r.type == "merged" then .[$k] += {status: "merged"}
      elif $r.type == "sent_back" then
        .[$k] += {status: "sent_back", reason: $r.reason, detail: $r.detail}
      elif $r.type == "told" then .[$k].told = true
      else . end)
  | [.[]] | sort_by(.seq)'

fold() { # -> every entry, oldest first, as one JSON array; the caller holds the lock
  if [ -s "$ledger" ]; then jq -sc "$FOLD" "$ledger"; else printf '[]\n'; fi
}

# The same, for a reader: under the lock, so a record being appended is never read in half.
entries() {
  local rc
  lock ledger 100 || { printf 'merge-desk: the ledger is locked\n' >&2; return 1; }
  fold; rc=$?
  unlock ledger
  return $rc
}

# ----------------------------------------------------------------------------- GitHub
#
# GraphQL throughout: `gh pr merge` on a queue repo turns auto-merge on when the PR is not
# yet mergeable, and auto-merge enters the queue whenever GitHub next finds the PR ready --
# out of report order. `enqueuePullRequest` either adds the PR now or refuses.

PR_QUERY='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id number url state isDraft mergeable mergeStateStatus reviewDecision isInMergeQueue headRefOid baseRefName mergeQueueEntry{position enqueuedAt} commits(last:1){nodes{commit{statusCheckRollup{state}}}} timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{createdAt reason}}}}}}'

ENQUEUE='mutation($id:ID!,$sha:GitObjectID!){enqueuePullRequest(input:{pullRequestId:$id,expectedHeadOid:$sha}){mergeQueueEntry{position enqueuedAt}}}'

# One bounded `gh` call. Sets GH_JSON to the response and GH_ERR to why there is none.
#   0  GitHub answered
#   1  no answer: the network, a hang, an expired token
#   2  GitHub answered with errors; GH_ERR is its messages
gh_call() {
  local out rc
  GH_JSON=""; GH_ERR=""
  out=$(wf_gh_bounded "$call_timeout" gh "$@"); rc=$?
  # gh prints the response body and then, on a GraphQL error, its own one-line message.
  GH_JSON=$(printf '%s\n' "$out" | jq -c . 2>/dev/null | head -n 1)
  [ -n "$GH_JSON" ] || GH_JSON=$(printf '%s\n' "$out" | grep -m 1 '^{')
  if [ -z "$GH_JSON" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$GH_JSON"; then
    GH_JSON=""; GH_ERR=${out%%$'\n'*}; return 1
  fi
  if jq -e '(.errors // []) | length > 0' >/dev/null <<<"$GH_JSON"; then
    GH_ERR=$(jq -r '[.errors[].message] | join("; ")' <<<"$GH_JSON"); return 2
  fi
  [ $rc -eq 0 ] || { GH_ERR=${out%%$'\n'*}; return 1; }
}

# Sets PR to one pull request, flattened; the status is gh_call's.
pr_fetch() { # owner/name number
  local rc
  PR=""
  gh_call api graphql -f query="$PR_QUERY" \
    -F owner="${1%%/*}" -F name="${1#*/}" -F number="$2"; rc=$?
  [ $rc -eq 0 ] || return $rc
  PR=$(jq -c '.data.repository.pullRequest | select(. != null) | {
      id, number, url, state, isDraft, mergeable, mergeStateStatus, reviewDecision,
      isInMergeQueue, headRefOid, baseRefName,
      position: .mergeQueueEntry.position,
      queued_at: .mergeQueueEntry.enqueuedAt,
      rollup: .commits.nodes[0].commit.statusCheckRollup.state,
      removed_at: .timelineItems.nodes[0].createdAt,
      removed_reason: .timelineItems.nodes[0].reason
    }' <<<"$GH_JSON")
  [ -n "$PR" ] || { GH_ERR="no such pull request"; return 2; }
}

# What to do with a PR, as `action<TAB>reason<TAB>detail`.
#
# waiting: a reported PR not yet in GitHub's queue. Whether it can merge is GitHub's own
# mergeStateStatus, never a roll-up of the checks that happen to have reported: a required
# check that has not registered leaves the roll-up green and the status BLOCKED.
#
# queued: a PR this ledger saw enter GitHub's queue. Out of the queue and still open, it
# was removed -- but only a removal no older than the entry counts, because the timeline
# keeps the removals of every earlier round.
VERDICTS='
  def short: .[0:7];
  def waiting($sha):
    if .state == "MERGED" then ["merged", "-", "-"]
    elif .state != "OPEN" then ["back", "closed", "the pull request is closed"]
    elif .isInMergeQueue then ["adopt", "-", "-"]
    elif .headRefOid != $sha then
      ["back", "head_moved", "its head is \(.headRefOid | short), not the \($sha | short) that was reported"]
    elif .isDraft then ["back", "draft", "the pull request is a draft"]
    elif .mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY" then
      ["back", "conflict", "it conflicts with \(.baseRefName)"]
    elif .mergeable == "UNKNOWN" or .mergeStateStatus == "UNKNOWN" then
      ["hold", "mergeability", "GitHub has not worked out whether it can merge"]
    elif (.mergeStateStatus | IN("CLEAN", "UNSTABLE", "HAS_HOOKS")) then ["enqueue", "-", "-"]
    elif (.rollup | IN("FAILURE", "ERROR")) then
      ["back", "checks_failed", "its checks failed on \(.headRefOid | short)"]
    elif (.rollup | IN("PENDING", "EXPECTED", null)) then
      ["hold", "checks", "its checks have not finished on \(.headRefOid | short)"]
    elif (.reviewDecision | IN("REVIEW_REQUIRED", "CHANGES_REQUESTED")) then
      ["back", "review_required", "GitHub wants a review first (\(.reviewDecision))"]
    else ["enqueue", "-", "-"] end;
  def queued($since):
    if .state == "MERGED" then ["merged", "-", "-"]
    elif .state != "OPEN" then ["back", "closed", "the pull request is closed"]
    elif .isInMergeQueue then ["wait", "-", "-"]
    elif .removed_at != null and .removed_at >= $since and .removed_reason != "merged" then
      ["back",
       ({merge_conflict: "conflict", failed_checks: "checks_failed", manual: "dequeued"}[.removed_reason]
        // "removed"),
       "GitHub took it out of the merge queue (\(.removed_reason))"]
    else ["wait", "-", "-"] end;'

verdict() { # jq-call -> sets V_ACTION V_REASON V_DETAIL from $PR
  local sha_or_since=$2
  IFS=$'\t' read -r V_ACTION V_REASON V_DETAIL < <(
    jq -r --arg x "$sha_or_since" "$VERDICTS $1(\$x) | @tsv" <<<"$PR")
}

# ------------------------------------------------------------------------- the pass

sent_back() { # seq ref from reason detail
  record --argjson seq "$1" --arg reason "$4" --arg detail "$5" \
    '{at: $at, type: "sent_back", seq: $seq, reason: $reason, detail: $detail}' || return 1
  printf 'sent-back %s reason=%s tell="%s"\n' "$2" "$4" "$3"
}

merged() { # seq ref from
  record --argjson seq "$1" '{at: $at, type: "merged", seq: $seq}' || return 1
  printf 'merged %s tell="%s"\n' "$2" "$3"
}

# An entry with no time from GitHub is dated now: an empty one would let every removal the
# timeline has ever kept count as this entry's.
in_queue() { # seq ref from enqueued-at how
  record --argjson seq "$1" --arg q "${4:-$(now_iso)}" \
    '{at: $at, type: "enqueued", seq: $seq, enqueued_at: $q}' || return 1
  printf 'enqueued %s %s from="%s"\n' "$2" "$5" "$3"
}

held_too_long() { # held-at -> 0 when past the limit
  jq -en --arg h "$1" --argjson m "$hold_minutes" \
    '(now - ($h | fromdateiso8601)) / 60 >= $m' >/dev/null
}

pass_repo() { # owner/name entries
  local repo=$1 all=$2 seq number sha from held since ref rc

  # The PRs already in GitHub's queue: merged, taken out, or still there.
  while IFS=$'\t' read -r -u 3 seq number from since; do
    [ -n "$seq" ] || continue
    ref="$repo#$number"
    pr_fetch "$repo" "$number" || continue
    verdict queued "$since"
    case $V_ACTION in
      merged) merged "$seq" "$ref" "$from" ;;
      back)   sent_back "$seq" "$ref" "$from" "$V_REASON" "$V_DETAIL" ;;
    esac
  done 3< <(jq -r --arg r "$repo" '.[] | select(.repo == $r and .status == "enqueued")
      | [.seq, .pr, .from, .enqueued_at] | @tsv' <<<"$all")

  # The waiting ones, in report order. `break` is the line holding: nothing behind a PR
  # that is neither enqueued nor sent back is looked at in this pass.
  while IFS=$'\t' read -r -u 3 seq number from sha held; do
    [ -n "$seq" ] || continue
    ref="$repo#$number"
    pr_fetch "$repo" "$number" || break
    verdict waiting "$sha"
    case $V_ACTION in
      merged) merged "$seq" "$ref" "$from" || break ;;
      back)   sent_back "$seq" "$ref" "$from" "$V_REASON" "$V_DETAIL" || break ;;
      adopt)  in_queue "$seq" "$ref" "$from" "$(jq -r '.queued_at // empty' <<<"$PR")" by=other \
                || break ;;
      hold)
        if [ "$held" = - ]; then
          record --argjson seq "$seq" '{at: $at, type: "held", seq: $seq}' || break
          printf 'holding %s for=%s\n' "$ref" "$V_REASON"
        elif held_too_long "$held"; then
          sent_back "$seq" "$ref" "$from" timed_out \
            "$V_DETAIL after $hold_minutes minutes" || break
          continue
        fi
        break ;;
      enqueue)
        gh_call api graphql -f query="$ENQUEUE" \
          -f id="$(jq -r .id <<<"$PR")" -f sha="$sha"; rc=$?
        case $rc in
          0) in_queue "$seq" "$ref" "$from" \
               "$(jq -r '.data.enqueuePullRequest.mergeQueueEntry.enqueuedAt // empty' <<<"$GH_JSON")" \
               "position=$(jq -r '.data.enqueuePullRequest.mergeQueueEntry.position // "?"' <<<"$GH_JSON")" \
               || break ;;
          2) # Refused -- unless something else enqueued it between the look and the call.
             V_DETAIL=$GH_ERR
             pr_fetch "$repo" "$number" || break
             if [ "$(jq -r .isInMergeQueue <<<"$PR")" = true ]; then
               in_queue "$seq" "$ref" "$from" "$(jq -r '.queued_at // empty' <<<"$PR")" by=other \
                 || break
             else
               sent_back "$seq" "$ref" "$from" refused "GitHub would not enqueue it: $V_DETAIL" \
                 || break
             fi ;;
          *) break ;;   # no answer: it may have gone through; the next pass looks
        esac ;;
      *) break ;;
    esac
  done 3< <(jq -r --arg r "$repo" '.[] | select(.repo == $r and .status == "waiting")
      | [.seq, .pr, .from, .sha, (.held_at // "-")] | @tsv' <<<"$all")
}

pass() {
  local all repo
  lock pass 1 || return 0          # another pass is at work; it sees the same ledger
  all=$(entries) || {
    unlock pass
    printf 'broken: the ledger does not parse: %s\n' "$ledger"
    return 1
  }
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    pass_repo "$repo" "$all"
  done < <(jq -r '[.[] | select(.status == "waiting" or .status == "enqueued") | .repo]
      | unique | .[]' <<<"$all")
  unlock pass
}

runner_pid() { # -> the pid of a live `run` loop
  local pid
  pid=$(cat "$dir/run.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
}

# --------------------------------------------------------------------------- commands

cmd_submit() {
  local target="" from="-" sha="" repo number all dup dup_status dup_sha seq ahead
  while [ $# -gt 0 ]; do
    case $1 in
      --from) [ $# -ge 2 ] || usage; from=$2; shift 2 ;;
      --sha)  [ $# -ge 2 ] || usage; sha=$2; shift 2 ;;
      -*)     usage ;;
      *)      [ -z "$target" ] || usage; target=$1; shift ;;
    esac
  done
  [ -n "$from" ] || from=-
  case $target in
    https://github.com/*/*/pull/*)
      repo=${target#https://github.com/}; number=${repo#*/pull/}; repo=${repo%%/pull/*}
      number=${number%%[!0-9]*} ;;
    */*'#'*) repo=${target%%#*}; number=${target#*#} ;;
    *) usage ;;
  esac
  case $number in ''|*[!0-9]*) usage ;; esac
  case $repo in */*/*|/*|*/|'') usage ;; esac

  pr_fetch "$repo" "$number" || die "cannot read $repo#$number: $GH_ERR"
  [ -n "$sha" ] || sha=$(jq -r .headRefOid <<<"$PR")
  verdict waiting "$sha"
  case $V_ACTION in
    merged) die "$repo#$number is already merged" ;;
    back)   die "$repo#$number is not taken ($V_REASON): $V_DETAIL" ;;
  esac

  lock ledger 100 || die "the ledger is locked"
  all=$(fold) || { unlock ledger; die "the ledger does not parse: $ledger"; }
  dup=$(jq -r --arg r "$repo" --argjson n "$number" '.[]
      | select(.repo == $r and .pr == $n and (.status == "waiting" or .status == "enqueued"))
      | [.seq, .status, .sha] | @tsv' <<<"$all" | tail -n 1)
  if [ -n "$dup" ]; then
    IFS=$'\t' read -r seq dup_status dup_sha <<<"$dup"
    if [ "$dup_status" = enqueued ] || [ "$dup_sha" = "$sha" ]; then
      unlock ledger
      printf '%s#%s is already in the line as %s (%s)\n' "$repo" "$number" "$seq" "$dup_status"
      return 0
    fi
    # The same PR at a new commit: the old report leaves, with nobody to tell.
    jq -nc --arg at "$(now_iso)" --argjson seq "$seq" --arg sha "$sha" \
      '{at: $at, type: "sent_back", seq: $seq, reason: "superseded",
        detail: "reported again at \($sha[0:7])"}, {at: $at, type: "told", seq: $seq}' >> "$ledger"
    all=$(fold)
  fi
  seq=$(jq '([.[].seq] | max // 0) + 1' <<<"$all")
  ahead=$(jq --arg r "$repo" '[.[] | select(.repo == $r and .status == "waiting")] | length' <<<"$all")
  jq -nc --arg at "$(now_iso)" --argjson seq "$seq" --arg repo "$repo" --argjson pr "$number" \
    --arg sha "$sha" --arg from "$from" --arg url "$(jq -r .url <<<"$PR")" \
    '{at: $at, type: "reported", seq: $seq, repo: $repo, pr: $pr, sha: $sha, from: $from, url: $url}' \
    >> "$ledger"
  unlock ledger

  printf 'reported %s#%s at %s as %s; %s waiting ahead of it in %s\n' \
    "$repo" "$number" "${sha:0:7}" "$seq" "$ahead" "$repo"
  runner_pid >/dev/null || printf 'no merge desk is running: nothing is enqueued until one is\n'
}

cmd_run() {
  local once=false
  case ${1:-} in
    '') ;;
    --once) once=true ;;
    *) usage ;;
  esac
  if $once; then pass; return; fi
  lock run 1 || die "a merge desk is already running (pid $(runner_pid))"
  trap 'unlock run' EXIT
  trap 'exit 0' INT TERM
  while true; do
    pass | tee -a "$dir/run.log"
    [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
    sleep "$interval" & wait $!
  done
}

cmd_watch() {
  [ $# -eq 0 ] || usage
  : >> "$dir/run.log"
  exec tail -n 0 -F "$dir/run.log"
}

cmd_status() {
  local all pid
  all=$(entries) || die "the ledger does not parse: $ledger"
  jq -r '.[]
    | select(.status == "waiting" or .status == "enqueued" or (.told | not))
    | [ (.seq | tostring), "\(.repo)#\(.pr)",
        (if .status == "waiting" and .held_at then "held since \(.held_at)"
         elif .status == "sent_back" then "sent back: \(.reason)"
         elif .status == "enqueued" then "in the merge queue"
         else .status end),
        "from: \(.from)" ] | join("  ")' <<<"$all"
  if pid=$(runner_pid); then printf 'merge desk running (pid %s)\n' "$pid"
  else printf 'no merge desk is running\n'; fi
}

cmd_outbox() {
  local all
  all=$(entries) || die "the ledger does not parse: $ledger"
  jq -r '.[]
    | select((.status == "merged" or .status == "sent_back") and (.told | not))
    | [ (.seq | tostring),
        (if .status == "merged" then "merged" else "sent-back" end),
        "\(.repo)#\(.pr)", "to: \(.from)",
        (if .status == "merged" then "-" else "\(.reason): \(.detail)" end),
        .url ] | @tsv' <<<"$all"
}

cmd_told() {
  local all seq
  [ $# -ge 1 ] || usage
  all=$(entries) || die "the ledger does not parse: $ledger"
  for seq in "$@"; do
    case $seq in ''|*[!0-9]*) usage ;; esac
    jq -e --argjson s "$seq" 'any(.[]; .seq == $s and (.status == "merged" or .status == "sent_back"))' \
      >/dev/null <<<"$all" || die "$seq is not a finished entry"
  done
  for seq in "$@"; do
    record --argjson seq "$seq" '{at: $at, type: "told", seq: $seq}' || exit 1
  done
}

[ $# -ge 1 ] || usage
cmd=$1; shift
case $cmd in
  submit|run|watch|status|outbox|told) ;;
  *) usage ;;
esac
mkdir -p "$dir" || die "cannot create $dir"
case $hold_minutes in
  ''|*[!0-9]*) die "ONTHERUN_MERGE_DESK_HOLD_MINUTES must be a whole number of minutes" ;;
esac
"cmd_$cmd" "$@"
