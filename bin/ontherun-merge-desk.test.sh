#!/usr/bin/env bash
# shellcheck disable=SC2016
# Tests for ontherun-merge-desk.sh. No framework: a stub `gh` on PATH, one canned GraphQL
# response per pull request, and assertions on stdout, exit status and the calls the stub
# saw.
#
#   ontherun-merge-desk.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs `jq`.
#
# **The stub answers with whole GraphQL responses**, so the script's own jq -- the
# flattening of a pull request, both verdict tables, the fold of the ledger -- is what
# turns them into decisions; nothing here hands the script a finished verdict.
#
# **The stub logs every call, and the last case reads the log of the whole run.** The
# script's one promise is that adding a PR to the merge queue is the only thing it changes
# on GitHub; a `gh pr merge`, a `gh pr ready` or a second mutation would show there and
# nowhere in the script's output.
#
# **Order is asserted on the mutations, not on the printed lines.** Reports are filed in an
# order that is neither PR-number order nor the order the fixtures were written, so a walk
# over anything but the ledger's sequence enqueues them wrong.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DESK="$SCRIPT_DIR/ontherun-merge-desk.sh"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

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

# ---------------------------------------------------------------- the stub `gh`
#
# A query reads $STUB/<owner>.<name>.<number>.json, the whole response; with no such file
# it fails the way a dead network does. A mutation succeeds unless $STUB/enqueue-<id>
# says otherwise:
#   DOWN          no answer at all
#   REFUSE:<msg>  GitHub's errors body, gh's own line on stderr, exit 1
#   RACE:<msg>    the same refusal, and the PR is in the queue by the time it is read again
# Every call is one line in $STUB/calls and in $ALL_CALLS; anything that is not
# `api graphql` is logged as `unexpected` and exits 2.

STUB="$TMP/stub"
ALL_CALLS="$TMP/all-calls"
export STUB ALL_CALLS
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
log() { echo "$*" >> "$STUB/calls"; echo "$*" >> "$ALL_CALLS"; }
[ "${1:-} ${2:-}" = "api graphql" ] || { log "unexpected $*"; exit 2; }
q=""; owner=""; name=""; number=""; id=""; sha=""
for a in "$@"; do
  case $a in
    query=*) q=${a#query=} ;;
    owner=*) owner=${a#owner=} ;;
    name=*) name=${a#name=} ;;
    number=*) number=${a#number=} ;;
    id=*) id=${a#id=} ;;
    sha=*) sha=${a#sha=} ;;
  esac
done
case $q in
  mutation*enqueuePullRequest*)
    log "enqueue $id $sha"
    mode=$(cat "$STUB/enqueue-$id" 2>/dev/null)
    case $mode in
      DOWN) echo "HTTP 502 Bad Gateway" >&2; exit 1 ;;
      REFUSE:*|RACE:*)
        if [ "${mode%%:*}" = RACE ]; then
          f=$(grep -l "\"id\":\"$id\"" "$STUB"/*.json)
          jq -c '.data.repository.pullRequest |= (.isInMergeQueue = true
            | .mergeQueueEntry = {position: 1, enqueuedAt: "2026-01-01T00:00:00Z"})' "$f" > "$f.new"
          mv "$f.new" "$f"
        fi
        jq -nc --arg m "${mode#*:}" '{data: {enqueuePullRequest: null}, errors: [{message: $m}]}'
        echo "gh: ${mode#*:}" >&2
        exit 1 ;;
      *)
        n=$(grep -c '^enqueue ' "$STUB/calls")
        jq -nc --argjson n "$n" '{data: {enqueuePullRequest: {mergeQueueEntry:
          {position: $n, enqueuedAt: "2026-01-01T00:00:00Z"}}}}' ;;
    esac ;;
  query*pullRequest*)
    log "query $owner/$name#$number"
    f="$STUB/$owner.$name.$number.json"
    [ -f "$f" ] || { echo "HTTP 502 Bad Gateway" >&2; exit 1; }
    cat "$f" ;;
  *) log "unexpected $*"; exit 2 ;;
esac
GH
chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"
export PATH

export ONTHERUN_MERGE_DESK_DIR="$TMP/desk"
export WF_MERGE_DESK_INTERVAL=0.3 WF_MERGE_DESK_TIMEOUT=5
LEDGER="$ONTHERUN_MERGE_DESK_DIR/ledger.jsonl"

fresh() { rm -rf "$STUB" "$ONTHERUN_MERGE_DESK_DIR"; mkdir -p "$STUB"; }

# Wait for a command to succeed, for up to 30s: the limit is for a machine under load, and
# is never reached on one that is not.
await() {
  local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ $i -ge 150 ] && return 1
    sleep 0.2
  done
}

desk() { OUT=$("$DESK" "$@" 2>&1); RC=$?; }

enqueues() { # the mutations so far, in order, as `id id ...`
  [ -f "$STUB/calls" ] || return 0
  grep '^enqueue ' "$STUB/calls" | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//'
}

# A pull request as GitHub would answer for it: open, mergeable, CLEAN, green, at head
# `aaaaaaa<number>`, never in the queue -- with any field overridden as key=value, the
# value read as JSON when it is JSON and as a string otherwise.
pr() { # owner/name number [key=value ...]
  local repo=$1 n=$2 over='{}' kv k v
  shift 2
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    if jq . >/dev/null 2>&1 <<<"$v"; then   # not -e: `null` and `false` are JSON too
      over=$(jq -c --arg k "$k" --argjson v "$v" '.[$k] = $v' <<<"$over")
    else
      over=$(jq -c --arg k "$k" --arg v "$v" '.[$k] = $v' <<<"$over")
    fi
  done
  jq -nc --argjson n "$n" --arg repo "$repo" --argjson o "$over" '
    ({state: "OPEN", isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
      reviewDecision: null, isInMergeQueue: false, headRefOid: "aaaaaaa\($n)",
      baseRefName: "main", rollup: "SUCCESS", queued_at: "2026-01-01T00:00:00Z",
      removed_at: null, removed_reason: null} + $o) as $p
    | {data: {repository: {pullRequest: {
        id: "PR_\($n)", number: $n, url: "https://github.com/\($repo)/pull/\($n)",
        state: $p.state, isDraft: $p.isDraft, mergeable: $p.mergeable,
        mergeStateStatus: $p.mergeStateStatus, reviewDecision: $p.reviewDecision,
        isInMergeQueue: $p.isInMergeQueue, headRefOid: $p.headRefOid,
        baseRefName: $p.baseRefName,
        mergeQueueEntry: (if $p.isInMergeQueue
          then {position: 1, enqueuedAt: $p.queued_at} else null end),
        commits: {nodes: [{commit: {statusCheckRollup:
          (if $p.rollup then {state: $p.rollup} else null end)}}]},
        timelineItems: {nodes: (if $p.removed_at
          then [{createdAt: $p.removed_at, reason: $p.removed_reason}] else [] end)}
      }}}}' > "$STUB/${repo%%/*}.${repo#*/}.$n.json"
}

echo "ontherun-merge-desk.sh"

# ------------------------------------------------------------------------- usage
fresh
desk;                        assert_eq "no command is usage" 64 "$RC"
desk frobnicate;             assert_eq "an unknown command is usage" 64 "$RC"
desk submit;                 assert_eq "submit with no PR is usage" 64 "$RC"
desk submit not-a-pr;        assert_eq "submit with no repo is usage" 64 "$RC"
desk submit acme/api#x;      assert_eq "submit with no number is usage" 64 "$RC"
desk submit acme/api#1 --from; assert_eq "--from with no value is usage" 64 "$RC"
desk run --forever;          assert_eq "run with an unknown flag is usage" 64 "$RC"
ONTHERUN_MERGE_DESK_HOLD_MINUTES=soon desk status
assert_eq "a hold limit that is not a number is refused" 1 "$RC"
desk told;                   assert_eq "told with no seq is usage" 64 "$RC"
desk told abc;               assert_eq "told with a word is usage" 64 "$RC"
desk watch now;              assert_eq "watch with an argument is usage" 64 "$RC"

# ------------------------------------------------------------------------ submit
fresh
pr acme/api 11; pr acme/api 12
desk submit 'acme/api#11' --from "Plan A"
assert_eq  "submit: taken" 0 "$RC"
assert_has "submit: says where it stands" \
  "reported acme/api#11 at aaaaaaa as 1; 0 waiting ahead of it in acme/api" "$OUT"
assert_has "submit: says nothing is running" "no merge desk is running" "$OUT"
desk submit https://github.com/acme/api/pull/12 --from "Plan B"
assert_has "submit: a URL names the same thing" \
  "reported acme/api#12 at aaaaaaa as 2; 1 waiting ahead of it in acme/api" "$OUT"
desk submit 'acme/api#11' --from "Plan A"
assert_eq  "submit: the same PR at the same commit is not added twice" \
  "acme/api#11 is already in the line as 1 (waiting)" "$OUT"
assert_eq  "submit: and the ledger did not grow" 2 "$(grep -c . "$LEDGER")"
assert_eq  "submit: enqueues nothing itself" "" "$(enqueues)"

pr acme/api 11 headRefOid=bbbbbbb11
desk submit 'acme/api#11' --from "Plan A"
assert_has "submit: the same PR at a new commit joins the back" \
  "reported acme/api#11 at bbbbbbb as 3; 1 waiting ahead of it in acme/api" "$OUT"
desk outbox
assert_eq  "submit: the superseded report owes nobody a message" "" "$OUT"
desk status
assert_lacks "submit: and is out of the line" "1  acme/api#11" "$OUT"

refused() { # name needle key=value ...
  local name=$1 needle=$2
  shift 2
  fresh; pr acme/api 13 "$@"
  desk submit 'acme/api#13'
  assert_eq  "submit refuses $name" 1 "$RC"
  assert_has "submit refuses $name, with the reason" "$needle" "$OUT"
  assert_eq  "submit refuses $name, and records nothing" "" "$(cat "$LEDGER" 2>/dev/null)"
}
refused "a closed PR"       "(closed)"          state=CLOSED
refused "a merged PR"       "already merged"    state=MERGED
refused "a draft"           "(draft)"           isDraft=true
refused "a conflicting PR"  "(conflict): it conflicts with main" mergeable=CONFLICTING mergeStateStatus=DIRTY
refused "failed checks"     "(checks_failed)"   mergeStateStatus=BLOCKED rollup=FAILURE
refused "a wanted review"   "(review_required)" mergeStateStatus=BLOCKED reviewDecision=REVIEW_REQUIRED

fresh; pr acme/api 13
desk submit 'acme/api#13' --sha deadbeefcafe
assert_eq  "submit refuses a head that is not --sha" 1 "$RC"
assert_has "submit refuses a head that is not --sha, with both commits" \
  "its head is aaaaaaa, not the deadbee that was reported" "$OUT"
desk submit 'acme/api#14'
assert_eq  "submit: a PR GitHub does not answer for is a failure" 1 "$RC"
assert_has "submit: and says it could not be read" "cannot read acme/api#14" "$OUT"

fresh; pr acme/api 13 mergeStateStatus=BLOCKED rollup=PENDING
desk submit 'acme/api#13'
assert_eq  "submit takes a PR whose checks are still running" 0 "$RC"

# ------------------------------------------------------------------- report order
fresh
pr acme/api 21; pr acme/api 22; pr acme/api 23
desk submit 'acme/api#22' --from "Plan B"
desk submit 'acme/api#21' --from "Plan A"
desk submit 'acme/api#23' --from "Plan C"
desk run --once
assert_eq "order: enqueued as reported, not by number" "PR_22 PR_21 PR_23" "$(enqueues)"
assert_eq "order: one line each, with who reported it" \
'enqueued acme/api#22 position=1 from="Plan B"
enqueued acme/api#21 position=2 from="Plan A"
enqueued acme/api#23 position=3 from="Plan C"' "$OUT"
assert_has "order: the mutation names the reported commit" \
  "enqueue PR_22 aaaaaaa22" "$(cat "$STUB/calls")"
pr acme/api 21 isInMergeQueue=true; pr acme/api 22 isInMergeQueue=true
pr acme/api 23 isInMergeQueue=true
desk run --once
assert_eq "order: a PR in the queue is not enqueued again" "PR_22 PR_21 PR_23" "$(enqueues)"
assert_eq "order: and a quiet queue prints nothing" "" "$OUT"

# ------------------------------------------------------------------- holding the line
fresh
pr acme/api 31 mergeStateStatus=BLOCKED rollup=PENDING; pr acme/api 32
desk submit 'acme/api#31'; desk submit 'acme/api#32'
desk run --once
assert_eq "hold: pending checks hold the line" "holding acme/api#31 for=checks" "$OUT"
assert_eq "hold: nothing behind it is enqueued" "" "$(enqueues)"
desk run --once
assert_eq "hold: said once" "" "$OUT"
desk status
assert_has "hold: status shows it" "1  acme/api#31  held since " "$OUT"
pr acme/api 31
desk run --once
assert_eq "hold: released in order" "PR_31 PR_32" "$(enqueues)"

fresh
pr acme/api 31 mergeable=UNKNOWN mergeStateStatus=UNKNOWN; pr acme/api 32
desk submit 'acme/api#31'; desk submit 'acme/api#32'
desk run --once
assert_eq "hold: unknown mergeability holds too" "holding acme/api#31 for=mergeability" "$OUT"

fresh
pr acme/api 31 mergeStateStatus=BLOCKED rollup=null
desk submit 'acme/api#31'
desk run --once
assert_eq "hold: BLOCKED with no check registered is not green" \
  "holding acme/api#31 for=checks" "$OUT"

fresh
pr acme/api 31 rollup=null; pr acme/api 32 mergeStateStatus=UNSTABLE rollup=FAILURE
desk submit 'acme/api#31'; desk submit 'acme/api#32'
desk run --once
assert_eq "enqueue: CLEAN with no checks, and UNSTABLE, are GitHub saying yes" \
  "PR_31 PR_32" "$(enqueues)"

fresh
pr acme/api 31 mergeStateStatus=BLOCKED rollup=PENDING; pr acme/api 32
desk submit 'acme/api#31' --from "Plan A"; desk submit 'acme/api#32'
desk run --once
ONTHERUN_MERGE_DESK_HOLD_MINUTES=0 desk run --once
assert_has "hold: past the limit it is sent back" \
  'sent-back acme/api#31 reason=timed_out tell="Plan A"' "$OUT"
assert_eq  "hold: and the line moves in the same pass" "PR_32" "$(enqueues)"
desk outbox
assert_has "hold: the detail says what it waited for" \
  "timed_out: its checks have not finished on aaaaaaa after 0 minutes" "$OUT"

# ---------------------------------------------------- sent back from the waiting line
back() { # name reason key=value ...
  local name=$1 reason=$2
  shift 2
  fresh; pr acme/api 41; pr acme/api 42
  desk submit 'acme/api#41' --from "Plan A"; desk submit 'acme/api#42'
  pr acme/api 41 "$@"
  desk run --once
  assert_has "waiting: $name is sent back" \
    "sent-back acme/api#41 reason=$reason tell=\"Plan A\"" "$OUT"
  assert_eq  "waiting: $name does not hold the line" "PR_42" "$(enqueues)"
}
back "a head that moved"      head_moved      headRefOid=ccccccc41
back "a draft"                draft           isDraft=true
back "a conflict"             conflict        mergeable=CONFLICTING
back "a DIRTY merge state"    conflict        mergeStateStatus=DIRTY
back "failed checks"          checks_failed   mergeStateStatus=BLOCKED rollup=ERROR
back "a wanted review"        review_required mergeStateStatus=BLOCKED reviewDecision=CHANGES_REQUESTED
back "a closed PR"            closed          state=CLOSED

fresh; pr acme/api 41
desk submit 'acme/api#41' --from "Plan A"
pr acme/api 41 state=MERGED
desk run --once
assert_eq "waiting: a PR merged by someone else is reported merged" \
  'merged acme/api#41 tell="Plan A"' "$OUT"
assert_eq "waiting: and is not enqueued" "" "$(enqueues)"

fresh; pr acme/api 41 mergeStateStatus=BLOCKED
desk submit 'acme/api#41'
desk run --once
assert_eq "waiting: BLOCKED for a reason unseen is GitHub's to answer" "PR_41" "$(enqueues)"

# ------------------------------------------------------------------------ no answer
fresh
pr acme/api 51; pr acme/api 52; pr acme/web 53
desk submit 'acme/api#51'; desk submit 'acme/api#52'; desk submit 'acme/web#53'
rm "$STUB/acme.api.51.json"
desk run --once
assert_eq    "no answer: that repo's line holds, the other repo's moves" "PR_53" "$(enqueues)"
assert_lacks "no answer: and nothing is sent back on it" sent_back "$(cat "$LEDGER")"

# ------------------------------------------------------------- what the mutation says
fresh; pr acme/api 61; pr acme/api 62
desk submit 'acme/api#61' --from "Plan A"; desk submit 'acme/api#62'
echo "REFUSE:Merge queue is not enabled for this branch" > "$STUB/enqueue-PR_61"
desk run --once
assert_has "refused: sent back" 'sent-back acme/api#61 reason=refused tell="Plan A"' "$OUT"
assert_eq  "refused: the line moves" "PR_61 PR_62" "$(enqueues)"
desk outbox
assert_has "refused: GitHub's words are the detail" \
  "refused: GitHub would not enqueue it: Merge queue is not enabled for this branch" "$OUT"

fresh; pr acme/api 61
desk submit 'acme/api#61' --from "Plan A"
echo "RACE:Pull request is already in the merge queue" > "$STUB/enqueue-PR_61"
desk run --once
assert_eq "raced: a PR something else enqueued is in the queue, not sent back" \
  'enqueued acme/api#61 by=other from="Plan A"' "$OUT"

fresh; pr acme/api 61; pr acme/api 62
desk submit 'acme/api#61' --from "Plan A"; desk submit 'acme/api#62'
echo DOWN > "$STUB/enqueue-PR_61"
desk run --once
assert_eq "mutation unanswered: nothing is said" "" "$OUT"
assert_eq "mutation unanswered: and the line holds" "PR_61" "$(enqueues)"
pr acme/api 61 isInMergeQueue=true
desk run --once
assert_has "mutation unanswered: it had gone through, and the next pass sees it" \
  'enqueued acme/api#61 by=other from="Plan A"' "$OUT"
assert_eq  "mutation unanswered: it is not sent twice" "PR_61 PR_62" "$(enqueues)"

fresh; pr acme/api 61 isInMergeQueue=true
desk submit 'acme/api#61' --from "Plan A"
assert_eq "adopt: a PR already in the queue can be reported" 0 "$RC"
desk run --once
assert_eq "adopt: and is followed, not enqueued" \
  'enqueued acme/api#61 by=other from="Plan A"|' "$OUT|$(enqueues)"

# ------------------------------------------------------------ in GitHub's merge queue
queued() { # name expected-output key=value ...
  local name=$1 want=$2
  shift 2
  fresh; pr acme/api 71
  desk submit 'acme/api#71' --from "Plan A"
  desk run --once
  pr acme/api 71 "$@"
  desk run --once
  assert_eq "queued: $name" "$want" "$OUT"
}
queued "still there: nothing"            "" isInMergeQueue=true
queued "merged"                          'merged acme/api#71 tell="Plan A"' state=MERGED
queued "closed"                          'sent-back acme/api#71 reason=closed tell="Plan A"' state=CLOSED
queued "taken out for a conflict"        'sent-back acme/api#71 reason=conflict tell="Plan A"' \
  removed_at=2026-01-02T00:00:00Z removed_reason=merge_conflict mergeable=CONFLICTING
queued "taken out for failed checks"     'sent-back acme/api#71 reason=checks_failed tell="Plan A"' \
  removed_at=2026-01-02T00:00:00Z removed_reason=failed_checks
queued "taken out by hand"               'sent-back acme/api#71 reason=dequeued tell="Plan A"' \
  removed_at=2026-01-02T00:00:00Z removed_reason=manual
queued "taken out for a reason unnamed"  'sent-back acme/api#71 reason=removed tell="Plan A"' \
  removed_at=2026-01-02T00:00:00Z removed_reason=queue_cleared
queued "an earlier round's removal: nothing" "" \
  removed_at=2025-12-31T00:00:00Z removed_reason=merge_conflict
queued "removed as merged, not yet MERGED: nothing" "" \
  removed_at=2026-01-02T00:00:00Z removed_reason=merged
desk outbox
assert_eq "queued: so nothing is owed for it" "" "$OUT"

fresh; pr acme/api 71
desk submit 'acme/api#71' --from "Plan A"
desk run --once
pr acme/api 71 removed_at=2026-01-02T00:00:00Z removed_reason=queue_cleared
desk run --once
desk outbox
assert_has "queued: GitHub's own reason is in the detail" \
  "removed: GitHub took it out of the merge queue (queue_cleared)" "$OUT"
rm "$STUB/acme.api.71.json"
desk run --once
assert_eq "queued: no answer is no news" "" "$OUT"

# ---------------------------------------------------------------- outbox and told
fresh; pr acme/api 81; pr acme/api 82
desk submit 'acme/api#81' --from "Plan A"; desk submit 'acme/api#82'
desk run --once
pr acme/api 81 state=MERGED
pr acme/api 82 removed_at=2026-01-02T00:00:00Z removed_reason=merge_conflict
desk run --once
desk outbox
assert_eq "outbox: one row per outcome, with who to tell" \
"1	merged	acme/api#81	to: Plan A	-	https://github.com/acme/api/pull/81
2	sent-back	acme/api#82	to: -	conflict: GitHub took it out of the merge queue (merge_conflict)	https://github.com/acme/api/pull/82" "$OUT"
desk told 99
assert_eq "told: an unknown seq is refused" 1 "$RC"
desk told 1
desk outbox
assert_lacks "told: a told outcome leaves the outbox" "acme/api#81" "$OUT"
assert_has   "told: the other stays" "acme/api#82" "$OUT"

pr acme/api 82
desk submit 'acme/api#82' --from "Plan B"
assert_has "resubmit: a PR that was sent back joins the back under a new seq" \
  "reported acme/api#82 at aaaaaaa as 3; 0 waiting ahead" "$OUT"
desk status
assert_has "status: a waiting PR"             "3  acme/api#82  waiting  from: Plan B" "$OUT"
assert_has "status: an outcome nobody was told" "2  acme/api#82  sent back: conflict  from: -" "$OUT"
assert_lacks "status: a told outcome is gone" "acme/api#81" "$OUT"

printf 'not json\n' >> "$LEDGER"
desk status
assert_eq "a ledger that does not parse is an error, not an empty line" 1 "$RC"
desk run
assert_eq  "run: a ledger that does not parse ends the loop" 1 "$RC"
assert_has "run: and says so on the line a watcher reads" "broken: the ledger does not parse" "$OUT"
assert_has "run: and in the log" "broken: the ledger does not parse" \
  "$(cat "$ONTHERUN_MERGE_DESK_DIR/run.log")"

# ------------------------------------------------------------------- the run loop
fresh; pr acme/api 91
"$DESK" watch > "$TMP/watch.log" 2>&1 &
watcher=$!
# `watch` execs tail, so the pid is tail's once it is following -- not before.
is_tail() { case $(ps -o command= -p "$watcher") in tail*) return 0 ;; *) return 1 ;; esac; }
await is_tail
"$DESK" run > "$TMP/run.log" 2>&1 &
runner=$!
await test -s "$ONTHERUN_MERGE_DESK_DIR/run.lock/pid"
desk run
assert_eq  "run: a second loop is refused" 1 "$RC"
assert_has "run: and names the first" "already running (pid $runner)" "$OUT"
desk submit 'acme/api#91' --from "Plan A"
assert_lacks "run: submit sees the loop" "no merge desk is running" "$OUT"
await grep -q enqueued "$TMP/run.log"
assert_eq  "run: the loop enqueues what is reported while it runs" \
  'enqueued acme/api#91 position=1 from="Plan A"' "$(cat "$TMP/run.log")"
await grep -q enqueued "$TMP/watch.log"
assert_eq  "watch: prints the loop's lines as they are logged" \
  'enqueued acme/api#91 position=1 from="Plan A"' "$(cat "$TMP/watch.log")"
kill "$watcher"; wait "$watcher" 2>/dev/null
desk status
assert_has "run: status says it is running" "merge desk running (pid $runner)" "$OUT"
kill "$runner"; wait "$runner" 2>/dev/null
desk status
assert_has "run: a stopped loop leaves no lock" "no merge desk is running" "$OUT"

fresh; pr acme/api 92
desk submit 'acme/api#92'
mkdir -p "$ONTHERUN_MERGE_DESK_DIR/pass.lock"
( : ) & dead=$!; wait "$dead"
echo "$dead" > "$ONTHERUN_MERGE_DESK_DIR/pass.lock/pid"
desk run --once
assert_eq "a lock whose holder is gone is taken over" "PR_92" "$(enqueues)"

fresh; pr acme/api 93
desk submit 'acme/api#93'
mkdir -p "$ONTHERUN_MERGE_DESK_DIR/pass.lock"
desk run --once
assert_eq "a fresh lock with no pid yet is another pass starting" "" "$(enqueues)"
touch -t 202001010000 "$ONTHERUN_MERGE_DESK_DIR/pass.lock"
desk run --once
assert_eq "an old lock that never got a pid is taken over" "PR_93" "$(enqueues)"

# -------------------------------------------------- the only thing it does on GitHub
assert_eq "every call of the run was a PR query or an enqueue" "" \
  "$(grep -v -e '^query ' -e '^enqueue ' "$ALL_CALLS")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
