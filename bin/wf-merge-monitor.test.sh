#!/usr/bin/env bash
# Tests for wf-merge-monitor.sh. No framework: a stub `gh` on PATH, canned JSON, and
# assertions on stdout and exit status.
#
#   wf-merge-monitor.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs `jq`. Most of its wall clock is the
# poll-loop cases waiting on real polls; it turns the poll interval and the retry
# backoff down through the two env knobs the script carries for this, and exports both
# before the first case that would otherwise pay for them.
#
# **The stub applies the script's OWN `--jq` expressions to canned JSON** rather than
# echoing a finished row or a finished bucket word. That is what puts both jq strings
# under test instead of stubbing them away: a `--jq` wrapped across two source lines
# emits two lines per PR here exactly as it would against the real `gh`, and the
# three-valued check rollup -- including the `cancel` that folds into `fail` -- is the
# script's own expression being evaluated rather than a word this file chose.
#
# **The head-resolution cases pass two branches and assert the rows in full.** The two
# easiest ways to break head resolution are invisible on a one-branch list: a `for b in
# $BRANCHES` over a space-separated string (zsh does not word-split it) walks once and is
# correct by accident, and a `case` pattern split as `*" OPEN "*" draft=false "*` cannot
# match at all. Asserting
# the whole snapshot rather than just the head line is what catches the second class --
# a monitor emitting the right rows in gh's order rather than the queue's resolves the
# wrong head.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MONITOR="$SCRIPT_DIR/wf-merge-monitor.sh"

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

assert_out() { # name expected-stdout actual-stdout
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1" "expected:" "$2" "actual:" "$3"; fi
}

assert_has() { # name needle haystack
  case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain |$2|" "got |$3|" ;; esac
}

assert_lacks() { # name needle haystack
  case $3 in *"$2"*) bad "$1" "expected NOT to contain |$2|" "got |$3|" ;; *) ok "$1" ;; esac
}

# ---------------------------------------------------------------- the stub `gh`
#
# STUB_ROWS names a JSON file of PRs, or the word FAIL. STUB_CHECKS is a comma-separated
# list of buckets (`pass`, `pass,cancel`, `pending`), or NOCHECKS / FAIL for the two
# non-zero exits. STUB_CALLS collects one line per invocation so a case can assert how
# many attempts the retry made. STUB_TICK, when set, is a poll counter: `pr list` reads
# `$STUB_ROWS.$n` when that file exists, and STUB_CHECKS_AFTER / STUB_CHECKS_LATER
# switch the bucket list from poll N onwards. STUB_HANG_LIST / STUB_HANG_CHECKS make
# the first N calls of that kind print a partial line and then hang, as gh can on a bad
# network; the hang is a bash script waiting on a child, so a kill that reaches only the
# script leaves the child holding whatever output it inherited. STUB_ARGS, when set,
# collects every invocation's arguments.

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
jqexpr=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && jqexpr=$a; prev=$a; done
n=0
[ -n "${STUB_TICK:-}" ] && n=$(cat "$STUB_TICK" 2>/dev/null || echo 0)
[ -n "${STUB_ARGS:-}" ] && echo "$*" >> "$STUB_ARGS"
case "$1 $2" in
  "pr list")
    echo list >> "$STUB_CALLS"
    [ "$(grep -c '^list$' "$STUB_CALLS")" -le "${STUB_HANG_LIST:-0}" ] \
      && { echo partial; sleep 5; }
    [ -n "${STUB_TICK:-}" ] && echo "$((n + 1))" > "$STUB_TICK"
    src=${STUB_ROWS:-}
    [ -f "$src.$n" ] && src="$src.$n"
    [ "$src" = FAIL ] && { echo "HTTP 502 Bad Gateway" >&2; exit 1; }
    jq -r "$jqexpr" < "$src"
    ;;
  "pr checks")
    echo checks >> "$STUB_CALLS"
    [ "$(grep -c '^checks$' "$STUB_CALLS")" -le "${STUB_HANG_CHECKS:-0}" ] \
      && { echo partial; sleep 5; }
    c=${STUB_CHECKS:-pass}
    [ -n "${STUB_CHECKS_AFTER:-}" ] && [ "$n" -ge "$STUB_CHECKS_AFTER" ] \
      && c=${STUB_CHECKS_LATER:-pass}
    case $c in
      NOCHECKS) echo "no checks reported on the '$3' branch" >&2; exit 1 ;;
      FAIL)     echo "HTTP 401: Bad credentials" >&2; exit 1 ;;
      *) jq -nc --arg s "$c" '[$s | split(",") | .[] | {bucket:.}]' | jq -r "$jqexpr" ;;
    esac
    ;;
  *) echo "stub: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"
export PATH

g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# The queue's repo is a checkout whose origin is on GitHub, so every call carries `-R`.
REPO="$TMP/repo"; mkdir -p "$REPO"
g init -q "$REPO" && g -C "$REPO" remote add origin git@github.com:acme/acme-api.git
export STUB_CALLS="$TMP/calls"

# All three knobs, exported before the first case that pays for any: the retry cases
# below would otherwise sleep the shipping default of 5s twice each. The timeout is well
# clear of a stub call that answers; the hang cases turn it down further.
export WF_MERGE_MONITOR_INTERVAL=0.4 WF_MERGE_MONITOR_BACKOFF=0 WF_MERGE_MONITOR_TIMEOUT=2

run() { : > "$STUB_CALLS"; OUT=$("$MONITOR" "$@" 2>&1); RC=$?; }

calls() { # `grep -c` prints 0 and exits 1 on no match, so swallow the status rather
          # than appending a second count with a `|| echo 0`.
  [ -f "$STUB_CALLS" ] || { echo 0; return; }
  grep -c "^$1\$" "$STUB_CALLS" || true
}

prs() { # branch:number:STATE:true|false:oid ...  -> the JSON `gh pr list` returns
  local out="[" first=1 spec b n s d t
  for spec in "$@"; do
    IFS=: read -r b n s d t <<<"$spec"
    [ $first -eq 1 ] || out="$out,"
    first=0
    out="$out{\"number\":$n,\"headRefName\":\"$b\",\"state\":\"$s\",\"isDraft\":$d,\"headRefOid\":\"$t\"}"
  done
  printf '%s]\n' "$out"
}

# ------------------------------------------------------------------- the fixtures
#
# gh returns PRs in ITS order, which is deliberately not queue order.
prs claude/api-2-second:21:OPEN:false:bbbbbbbcafe \
    claude/other-plan-1:99:OPEN:false:ccccccccafe \
    claude/api-1-first:20:MERGED:false:aaaaaaaacafe > "$TMP/rows.json"

prs claude/api-1-first:20:OPEN:true:aaaaaaaacafe \
    claude/api-2-second:21:OPEN:false:bbbbbbbcafe > "$TMP/draft.json"

prs claude/api-1-first:20:MERGED:false:aaaaaaaacafe \
    claude/api-2-second:21:CLOSED:false:bbbbbbbcafe > "$TMP/terminal.json"

# A branch whose name is a prefix of another's, and one carrying regex metacharacters.
prs claude/api-1-first-extended:30:OPEN:false:dddddddcafe \
    claude/api-1-first:31:OPEN:false:eeeeeeecafe \
    claude/api-2-v1.2:32:OPEN:false:fffffffcafe > "$TMP/prefix.json"

echo "wf-merge-monitor.sh"

# ---------------------------------------------------- head resolution, two branches

export STUB_ROWS="$TMP/rows.json" STUB_CHECKS=pass
run --once "$REPO" claude/api-1-first claude/api-2-second
assert_out "two branches: rows in QUEUE order, foreign branch dropped, head skips MERGED" \
"claude/api-1-first pr=20 MERGED draft=false tip=aaaaaaa
claude/api-2-second pr=21 OPEN draft=false tip=bbbbbbb
head claude/api-2-second: checks=pass" "$OUT"
assert_eq "  and exits 0" 0 "$RC"

# Reversing the queue order must reverse the rows and move the head. This is what a
# joined-string walk cannot do: it sees the whole list as one branch name.
run --once "$REPO" claude/api-2-second claude/api-1-first
assert_out "queue order is the argument order, not gh's" \
"claude/api-2-second pr=21 OPEN draft=false tip=bbbbbbb
claude/api-1-first pr=20 MERGED draft=false tip=aaaaaaa
head claude/api-2-second: checks=pass" "$OUT"

export STUB_ROWS="$TMP/draft.json"
run --once "$REPO" claude/api-1-first claude/api-2-second
assert_out "a draft PR is listed but is never the head" \
"claude/api-1-first pr=20 OPEN draft=true tip=aaaaaaa
claude/api-2-second pr=21 OPEN draft=false tip=bbbbbbb
head claude/api-2-second: checks=pass" "$OUT"

export STUB_ROWS="$TMP/terminal.json"
run --once "$REPO" claude/api-1-first claude/api-2-second
assert_out "MERGED and CLOSED both leave the queue: no head, rows still shown" \
"claude/api-1-first pr=20 MERGED draft=false tip=aaaaaaa
claude/api-2-second pr=21 CLOSED draft=false tip=bbbbbbb
head: none eligible" "$OUT"
assert_eq "  and still exits 0" 0 "$RC"
assert_eq "  and does not call gh pr checks with an empty head" 0 "$(calls checks)"

export STUB_ROWS="$TMP/prefix.json"
run --once "$REPO" claude/api-1-first claude/api-2-v1.2
assert_out "a branch name matches its own row only -- not a longer one it prefixes" \
"claude/api-1-first pr=31 OPEN draft=false tip=eeeeeee
claude/api-2-v1.2 pr=32 OPEN draft=false tip=fffffff
head claude/api-1-first: checks=pass" "$OUT"

# ------------------------------------------------------------- the check rollup
#
# These run the script's own jq expression over real bucket arrays.

export STUB_ROWS="$TMP/rows.json"
for spec in "pass:pass" "pass,skipping:pass" "pass,pending:pending" \
            "pass,fail:fail" "pass,cancel:fail" "pending,cancel:fail"; do
  buckets=${spec%%:*}; want=${spec##*:}
  STUB_CHECKS=$buckets run --once "$REPO" claude/api-1-first claude/api-2-second
  assert_has "rollup: [$buckets] -> $want" "checks=$want" "$OUT"
done

export STUB_CHECKS=NOCHECKS
run --once "$REPO" claude/api-1-first claude/api-2-second
assert_has "no checks yet reads as none, not as a failure" "checks=none" "$OUT"
assert_eq "  exit 0" 0 "$RC"
assert_eq "  and short-circuits the retry rather than burning three attempts" 1 "$(calls checks)"

export STUB_CHECKS=FAIL
run --once "$REPO" claude/api-1-first claude/api-2-second
assert_has "a dead gh pr checks is query-failed, never none" "checks=query-failed:" "$OUT"
assert_eq "  exit 2 -- rows are good, only the head's checks are unknown" 2 "$RC"
assert_has "  and the rows survive it" "claude/api-2-second pr=21 OPEN" "$OUT"
assert_eq "  and it retried three times first" 3 "$(calls checks)"

export STUB_ROWS=FAIL STUB_CHECKS=pass
run --once "$REPO" claude/api-1-first claude/api-2-second
assert_out "a dead gh pr list emits one line and no rows" "query-failed: gh pr list" "$OUT"
assert_eq "  exit 1 -- nothing was learned" 1 "$RC"
assert_eq "  and it retried three times" 3 "$(calls list)"

# ------------------------------------------------------------------ hung calls
#
# A hang must end as a failed attempt, inside the bound: three attempts at 0.3s are under
# a second, and the elapsed check is what fails if the kill misses or the hung child
# holds the output open.

elapsed_run() { local t0; t0=$(date +%s); run "$@"; ELAPSED=$(( $(date +%s) - t0 )); }

export STUB_ROWS="$TMP/rows.json" STUB_CHECKS=pass WF_MERGE_MONITOR_TIMEOUT=0.3
STUB_HANG_LIST=1 run --once "$REPO" claude/api-1-first claude/api-2-second
assert_has "a hung gh pr list is retried, and the retry's answer is used" \
  "head claude/api-2-second: checks=pass" "$OUT"
assert_eq "  exit 0" 0 "$RC"
assert_eq "  after two attempts" 2 "$(calls list)"
assert_lacks "  the hung attempt's partial output is dropped" "partial" "$OUT"

STUB_HANG_LIST=99 elapsed_run --once "$REPO" claude/api-1-first claude/api-2-second
assert_out "a gh pr list that hangs every time is query-failed" "query-failed: gh pr list" "$OUT"
assert_eq "  exit 1" 1 "$RC"
assert_eq "  after three attempts" 3 "$(calls list)"
if [ "$ELAPSED" -le 3 ]; then ok "  inside the bound (${ELAPSED}s)"
else bad "  inside the bound" "took ${ELAPSED}s"; fi

STUB_HANG_CHECKS=99 run --once "$REPO" claude/api-1-first claude/api-2-second
assert_has "a gh pr checks that hangs every time is query-failed, never none" \
  "head claude/api-2-second: checks=query-failed: gh: no response after 0.3s" "$OUT"
assert_eq "  exit 2" 2 "$RC"
assert_eq "  after three attempts" 3 "$(calls checks)"
export WF_MERGE_MONITOR_TIMEOUT=2

# ------------------------------------------------------------------- the arguments

run
assert_eq "no arguments: usage, exit 64" 64 "$RC"
run --once "$REPO"
assert_eq "a repo with no branches: usage, exit 64" 64 "$RC"
run --once "$TMP/no-such-repo" claude/api-1-first claude/api-2-second
assert_eq "an unreadable repo path fails loudly" 1 "$RC"

# Both calls name the repo with -R, from the checkout's origin.
export STUB_ROWS="$TMP/rows.json" STUB_CHECKS=pass STUB_ARGS="$TMP/args"
: > "$STUB_ARGS"
run --once "$REPO" claude/api-1-first claude/api-2-second
assert_has "gh pr list is run with -R <owner>/<name> from the origin" \
  "pr list -R acme/acme-api --state all --limit 100" "$(cat "$STUB_ARGS")"
assert_has "  and so is gh pr checks" "pr checks claude/api-2-second -R acme/acme-api --json bucket" "$(cat "$STUB_ARGS")"

# A relative repo resolves against $WF_WORKSPACE when it is set, else against the cwd.
mkdir -p "$TMP/ws"
g init -q "$TMP/ws/acme-web" && g -C "$TMP/ws/acme-web" remote add origin https://github.com/acme/acme-web.git
: > "$STUB_ARGS"; : > "$STUB_CALLS"
OUT=$(cd / && WF_WORKSPACE="$TMP/ws" "$MONITOR" --once acme-web claude/api-1-first claude/api-2-second 2>&1); RC=$?
assert_eq "a relative repo resolves against \$WF_WORKSPACE, not the cwd" 0 "$RC"
assert_has "  and queries that repo" "pr list -R acme/acme-web" "$(cat "$STUB_ARGS")"
: > "$STUB_ARGS"; : > "$STUB_CALLS"
OUT=$(cd "$TMP/ws" && env -u WF_WORKSPACE "$MONITOR" --once acme-web claude/api-1-first claude/api-2-second 2>&1); RC=$?
assert_eq "  and against the cwd without it" 0 "$RC"
assert_has "  the same repo" "pr list -R acme/acme-web" "$(cat "$STUB_ARGS")"
OUT=$(cd / && env -u WF_WORKSPACE "$MONITOR" --once acme-web claude/api-1-first claude/api-2-second 2>&1); RC=$?
assert_eq "  a relative repo that is not there fails loudly" 1 "$RC"

# A checkout whose origin is not GitHub is queried from its own directory, with no -R.
g init -q "$TMP/ws/elsewhere" && g -C "$TMP/ws/elsewhere" remote add origin https://gitlab.com/acme/x.git
: > "$STUB_ARGS"
run --once "$TMP/ws/elsewhere" claude/api-1-first claude/api-2-second
assert_eq "a non-GitHub origin: still exits 0" 0 "$RC"
assert_lacks "  and passes no -R" "-R" "$(cat "$STUB_ARGS")"
unset STUB_ARGS

# ---------------------------------------------------------------- the poll loop

export STUB_TICK="$TMP/tick"

# The loop gets its own process group and the whole group is killed: killing only the
# script leaves an in-flight `$(snapshot)` running, and it would go on calling the next
# case's stub and advancing its tick.
poll_for() { # out-file seconds -- run the loop in the background, then stop it
  : > "$STUB_CALLS"; echo 0 > "$STUB_TICK"
  set -m
  "$MONITOR" "$REPO" claude/api-1-first claude/api-2-second > "$1" 2>&1 &
  local loop=$!
  set +m
  sleep "$2"
  kill -- -"$loop" 2>/dev/null; wait "$loop" 2>/dev/null
}

# Polls 0-1 have both PRs open; from poll 2 api-1 is merged and the head moves. `pr list`
# increments the tick before `pr checks` re-reads it, so the baseline's checks call
# already sees 1 -- pending has to hold until 2.
export STUB_ROWS="$TMP/queue.json"
prs claude/api-1-first:20:MERGED:false:aaaaaaaacafe \
    claude/api-2-second:21:OPEN:false:bbbbbbbcafe > "$TMP/queue.json"
for i in 0 1; do
  prs claude/api-1-first:20:OPEN:false:aaaaaaaacafe \
      claude/api-2-second:21:OPEN:false:bbbbbbbcafe > "$TMP/queue.json.$i"
done
export STUB_CHECKS=pending STUB_CHECKS_AFTER=2 STUB_CHECKS_LATER=pass
poll_for "$TMP/loop.out" 2.2
assert_out "the loop prints the baseline once, then only what changed" \
"claude/api-1-first pr=20 OPEN draft=false tip=aaaaaaa
claude/api-2-second pr=21 OPEN draft=false tip=bbbbbbb
head claude/api-1-first: checks=pending
head claude/api-1-first: checks=pass
claude/api-1-first pr=20 MERGED draft=false tip=aaaaaaa
claude/api-2-second pr=21 OPEN draft=false tip=bbbbbbb
head claude/api-2-second: checks=pass" "$(cat "$TMP/loop.out")"

# A checks outage that does not end: the baseline succeeds, every poll after it fails.
# The head line must hold its last known value rather than flapping, and the loop must
# say nothing until four consecutive polls have failed. The recovery is the next case.
export STUB_ROWS="$TMP/steady.json"
prs claude/api-1-first:20:OPEN:false:aaaaaaaacafe \
    claude/api-2-second:21:OPEN:false:bbbbbbbcafe > "$TMP/steady.json"
export STUB_CHECKS=pass STUB_CHECKS_AFTER=2 STUB_CHECKS_LATER=FAIL
poll_for "$TMP/outage.out" 3.4   # four failing polls after poll 2, with slack for a slow shell
OUT=$(cat "$TMP/outage.out")
assert_has "an outage is announced once, at the fourth consecutive failure" \
  "query-failed for 4 polls: gh pr checks:" "$OUT"
assert_eq "  and only once" 1 "$(grep -c 'query-failed for 4 polls' "$TMP/outage.out")"
assert_lacks "  the head line never flaps to query-failed" \
  "head claude/api-1-first: checks=query-failed" "$OUT"
assert_eq "  the rows are not re-emitted, being unchanged" \
  2 "$(grep -c '^claude/api-' "$TMP/outage.out")"

# A gh pr list that hangs from the baseline on. The baseline speaks once, as a failed
# baseline does; after that the loop is silent until the fourth consecutive failure.
export STUB_HANG_LIST=999 WF_MERGE_MONITOR_TIMEOUT=0.3
poll_for "$TMP/hang.out" 6
unset STUB_HANG_LIST; export WF_MERGE_MONITOR_TIMEOUT=2
assert_out "a persistent hang reaches the four-poll query-failed line, and nothing else" \
"query-failed: gh pr list
query-failed for 4 polls: gh pr list" "$(cat "$TMP/hang.out")"

# Same shape, but the outage ends. This one needs its own stub: the schedule is a window
# rather than a switch, so STUB_CHECKS_AFTER/LATER cannot express it.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
jqexpr=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && jqexpr=$a; prev=$a; done
n=$(cat "$STUB_TICK" 2>/dev/null || echo 0)
case "$1 $2" in
  "pr list")   echo "$((n + 1))" > "$STUB_TICK"; jq -r "$jqexpr" < "$STUB_ROWS" ;;
  "pr checks") if [ "$n" -ge 2 ] && [ "$n" -le 5 ]; then
                 echo "HTTP 502 gateway" >&2; exit 1
               else jq -nc '[{bucket:"pass"}]' | jq -r "$jqexpr"; fi ;;
esac
STUB
poll_for "$TMP/recover.out" 3.6
OUT=$(cat "$TMP/recover.out")
assert_has "the recovery is announced when it comes" "query-recovered after" "$OUT"
assert_eq "  and only once" 1 "$(grep -c 'query-recovered' "$TMP/recover.out")"

# ------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
