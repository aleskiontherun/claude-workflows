#!/usr/bin/env bash
# Tests for ontherun-plan-lint.sh. No framework: fixtures/lint-plan.md as the one positive
# fixture (all three node kinds, two phases, a ledger, a counted Status, three review
# rounds), and every negative fixture derived from it by a mutation applied inside this
# file.
#
#   ontherun-plan-lint.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs `ruby` and `git`.
#
# **Every negative case asserts which check fails FIRST, not merely that the lint fails.**
# Most mutations break two checks at once -- a duplicate id also breaks the ledger, a
# shifted node also breaks the parse -- so a case asserting only the exit status would stay
# green with the check under test deleted. Naming the check is what makes each case go red
# for exactly one removal, and it is also what pins the ranking: the text-level `indent`
# check has to fire before `state-parse`, or a node pasted two spaces too deep is reported
# as a YAML error against the node above it.
#
# **Every mutation asserts that its anchor matched.** An unmutated copy passes the lint,
# which would turn the case's expected failure into a red with no explanation; the abort
# names the anchor instead. Anchors are patterns over the fixture's shape (the first node,
# `of its N nodes`) rather than its figures, and the figures the assertions need are
# derived from the fixture here, independently of the script. Edit the fixture only in
# ways that keep the anchors matching: `api-1` the first PR node, pending, with
# `implementer-high` just above its status; the first node a pending manual one;
# `api-3` needing `manual-5` and listed before `setup-1`; `api-2` and `web-1` adjacent; a
# Status that names a promotion and counts its nodes.

# The mutations are ruby expressions, single-quoted so their `$`, `\n` and backticks
# reach ruby untouched; the ones that must carry a shell figure use double quotes.
# shellcheck disable=SC2016

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LINT="$SCRIPT_DIR/ontherun-plan-lint.sh"

command -v ruby >/dev/null || { echo "ruby is required" >&2; exit 2; }
command -v git >/dev/null || { echo "git is required" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/lint-plan.md"
cp "$SCRIPT_DIR/fixtures/lint-plan.md" "$FIXTURE" \
  || { echo "fixture missing: $SCRIPT_DIR/fixtures/lint-plan.md" >&2; exit 2; }

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

run() { OUT=$("$LINT" "$@" 2>&1); RC=$?; }

first() { printf '%s\n' "$OUT" | sed -n 's/^ontherun-plan-lint: FAIL \([a-z-]*\) .*/\1/p'; }

# mutate '<ruby over s>' -- writes a fresh mutant of the fixture to $F. The expression
# edits the string `s` in place (`s.sub!`, `s.gsub!`); `sub!` touches the first match
# only, which is what lets an anchor like "    agent: owner\n" name one node. Aborts if the
# expression left the fixture unchanged.
case_n=0
mutate() {
  case_n=$((case_n + 1))
  F="$TMP/case-$case_n.md"
  LC_ALL=en_US.UTF-8 ruby -Eutf-8:utf-8 -e '
    s = File.read(ARGV[0], encoding: "UTF-8")
    before = s.dup
    eval(ARGV[2])
    abort("mutation left the fixture unchanged: #{ARGV[2]}") if s == before
    File.write(ARGV[1], s)' -- "$FIXTURE" "$F" "$1" || { bad "mutation $case_n applied" "$1"; F=""; }
}

expect_first() { # name check [needle ...] -- lint $F: exit 1, first failing check, needles
  local name=$1 check=$2 n
  shift 2
  run "$F"
  if [ "$RC" -ne 1 ]; then bad "$name" "expected exit 1, got $RC" "$OUT"; return; fi
  assert_eq "$name" "$check" "$(first)"
  for n in "$@"; do assert_has "  and names $n" "$n" "$OUT"; done
}

expect_ok() { # name -- lint $F: exit 0
  run "$F"
  if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1" "expected exit 0, got $RC" "$OUT"; fi
}

# ------------------------------------------------------- figures, derived independently
#
# Counted with grep rather than read back from the script, so that a script counting
# wrongly cannot agree with itself here.
N=$(grep -c '^  - id: ' "$FIXTURE")
SETUP=$(grep -c '^    kind: setup$' "$FIXTURE")
MANUAL=$(grep -c '^    kind: manual$' "$FIXTURE")
PR=$((N - SETUP - MANUAL))
LAST_ROUND=$(grep -oiE '^- \*\*[^*]*\bround [0-9]+' "$FIXTURE" | tail -1 | grep -oE '[0-9]+$')
FIRST_ID=$(grep -m1 '^  - id: ' "$FIXTURE" | sed 's/^  - id: //')

echo "ontherun-plan-lint.sh"

# ------------------------------------------------------------------ the positive fixture

run "$FIXTURE"
assert_eq "the fixture passes" 0 "$RC"
assert_eq "  and the summary counts its nodes by kind" \
  "ontherun-plan-lint: ok $FIXTURE — $N nodes ($PR pr, $SETUP setup, $MANUAL manual)" "$OUT"
if [ "$SETUP" -gt 0 ] && [ "$MANUAL" -gt 0 ] && [ "$PR" -gt 0 ]; then
  ok "  the fixture carries all three kinds"
else
  bad "  the fixture carries all three kinds" "pr=$PR setup=$SETUP manual=$MANUAL"
fi

# --------------------------------------------------------------------------- state-block

mutate 's.sub!("## State\n\n```yaml\n", "## State\n\n")'
expect_first "no yaml fence under ## State" state-block "no \`\`\`yaml fence"

mutate 's.sub!(/^```\n(?=\n## Review history)/, "\n")'
expect_first "a fence not closed before the next heading" state-block "not closed"

mutate 's.sub!(/^## State\n\n```yaml\n.*?^```\n/m, "")'
expect_ok "a plan with no ## State block passes the block checks"
assert_has "  and says so" "no ## State block" "$OUT"

# --------------------------------------------------------------------------------- indent
#
# A node and a field pasted too deep, plus the shift only a text check can see.

mutate "s.sub!(\"  - id: $FIRST_ID\n\", \"    - id: $FIRST_ID\n\")"
expect_first "a \`- id:\` at 4 spaces" indent "\`- id:\` at 4 spaces"
assert_has "  with the file line" "line $(grep -n "^    - id: $FIRST_ID" "$F" | cut -d: -f1):" "$OUT"
assert_lacks "  reported once, not once per field" "a node's fields sit at 4" "$OUT"

mutate 's.sub!("    agent: owner\n", "        agent: owner\n")'
expect_first "a field at 8 spaces" indent "\`agent:\` at 8 spaces"
assert_has "  with the file line" "line $(grep -n '^        agent: owner' "$F" | cut -d: -f1):" "$OUT"

# The two fields the generator reads are node fields too.
mutate 's.sub!("    reason: ", "        reason: ")'
expect_first "a reason: at 8 spaces" indent "\`reason:\` at 8 spaces"

# Every node shifted by two is valid YAML -- a sequence may sit deeper than its key -- so
# the parse cannot catch it and the indent check is the only thing that does.
mutate 's.gsub!(/^    (?=[a-z]+:)/, "      "); s.gsub!(/^      (?=- )/, "        "); s.gsub!(/^  (?=- id:)/, "    ")'
expect_first "a whole block shifted by two" indent
assert_lacks "  parses, so state-parse stays quiet" "state-parse" "$OUT"
assert_eq "  and is reported once per node" "$N" "$(printf '%s\n' "$OUT" | grep -c '^FAIL indent:')"

# ---------------------------------------------------------------------------- state-parse

mutate 's.sub!("needs: [manual-5]", "needs: [manual-5")'
expect_first "an unclosed flow sequence" state-parse "flow sequence"
assert_has "  at the file line" "line $(grep -n 'needs: \[manual-5$' "$F" | cut -d: -f1):" "$OUT"

# A `delivered:` report is free text copied verbatim, and a signature carries `: ` twice.
DELIVERED='    delivered:\n      - src/app/convert.py:12 — convert(data: bytes, *, exported_at: datetime | None = None)\n      - src/components/Picker.tsx:40 — onCourseSelected?: (course: Course) => void\n\n      - usage: \"\" as const\n'
mutate "s.sub!(/^(  - id: api-1\n(?:    .*\n)*?    status: pending\n)/, \"\\\\1$DELIVERED\")"
expect_ok "delivered items that are not YAML do not break the parse"

# Blanked, not dropped: a parse error below them still names its own file line.
mutate "s.sub!(/^(  - id: api-1\n(?:    .*\n)*?    status: pending\n)/, \"\\\\1$DELIVERED\"); s.sub!(\"needs: [manual-5]\", \"needs: [manual-5\")"
expect_first "  and a parse error below them keeps its file line" state-parse \
  "line $(grep -n 'needs: \[manual-5$' "$F" | cut -d: -f1):"

mutate 's.sub!(/^```yaml\n.*?^```\n/m, "```yaml\n```\n")'
expect_first "an empty block" state-parse "empty"

mutate 's.sub!(/^```yaml\n.*?^```\n/m, "```yaml\nrepos: [a]\n```\n")'
expect_first "a block without a nodes list" state-parse "nodes"

# ----------------------------------------------------------------------------- ids-unique

mutate 's.sub!("  - id: api-8\n", "  - id: api-6\n")'
expect_first "a duplicate id" ids-unique "\`api-6\` appears twice"

mutate "s.sub!(\"  - id: $FIRST_ID\n    kind: manual\n\", \"  - kind: manual\n\")"
expect_first "a node without an id" ids-unique "node 1 has no \`id\`"

# ---------------------------------------------------------------------------- needs-exist

mutate 's.sub!("needs: [manual-5]", "needs: [manual-99]")'
expect_first "a need that is not a node" needs-exist "\`api-3\` needs \`manual-99\`"

mutate 's.sub!("    needs: []\n", "")'
expect_first "a node without a needs list" needs-exist "\`$FIRST_ID\` has no \`needs\`"

# ------------------------------------------------------------------------------ dag-order

mutate 's.sub!("needs: [manual-5]", "needs: [setup-1]")'
expect_first "a need listed after the node" dag-order "\`api-3\` needs \`setup-1\`"

mutate 's.sub!("needs: [manual-5]", "needs: [api-3]")'
expect_first "a node that needs itself" dag-order "needs itself"

# ----------------------------------------------------------------------------------- kind

mutate 's.sub!(/^(    agent: implementer-x?high\n    status: pending\n)/, "\\1    check: \"x\"\n")'
expect_first "a PR node with a check" kind "\`api-1\` is a PR node and carries a \`check:\`"

mutate 's.sub!("    repo: acme-api\n", "")'
expect_first "a PR node without a repo" kind "\`api-1\` is a PR node and has no \`repo\`"

mutate 's.sub!(/^(  - id: api-1\n(?:    .*\n)*?)    agent: .*\n/, "\\1")'
expect_first "a PR node without an agent" kind "\`api-1\` is a PR node and has no \`agent\`"

mutate 's.sub!("  - id: setup-1\n    kind: setup\n", "  - id: setup-1\n    kind: setup\n    repo: acme-site\n")'
expect_first "a setup node with a repo" kind "\`setup-1\` is a setup node and carries a \`repo\`"

mutate 's.sub!("    agent: conductor\n", "    agent: implementer\n")'
expect_first "a setup node with the wrong agent" kind "needs \`agent: conductor\`, not \`implementer\`"

mutate 's.sub!(/^(  - id: setup-1\n(?:    .*\n)*?)    check: .*\n/, "\\1")'
expect_first "a setup node without a check" kind "\`setup-1\` is a setup node and has no \`check:\`"

mutate 's.sub!("    agent: owner\n", "    agent: conductor\n")'
expect_first "a manual node with the wrong agent" kind "needs \`agent: owner\`, not \`conductor\`"

mutate 's.sub!("    kind: manual\n", "    kind: chore\n")'
expect_first "an unknown kind" kind "\`kind: chore\`"

mutate 's.sub!("  - id: api-1\n    repo: acme-api\n", "  - id: api-1\n    kind: pr\n    repo: acme-api\n")'
expect_first "an explicit kind: pr, which the README says to omit" kind "\`kind: pr\`"

mutate "s.sub!(/^(  - id: $FIRST_ID\n(?:    .*\n)*?)    title: .*\n/, \"\\\\1\")"
expect_first "a node without a title" kind "\`$FIRST_ID\` has no \`title\`"

# --------------------------------------------------------------------------------- status

mutate 's.sub!("    status: pending\n", "    status: shipped\n")'
expect_first "a status outside the README's eight" status "\`status: shipped\`"

mutate 's.sub!(/^(  - id: api-1\n(?:    .*\n)*?)    status: pending\n/, "\\1    status: done\n")'
expect_first "done on a PR node" status "\`api-1\` is a PR node marked \`done\`"

mutate "s.sub!(/^(  - id: $FIRST_ID\n(?:    .*\n)*?)    status: pending\n/, \"\\\\1    status: merged\n\")"
expect_first "merged on a manual node" status "\`$FIRST_ID\` is a manual node marked \`merged\`"

# The block and its bullet move together, as the generator would move them.
mutate "s.sub!(/^(  - id: $FIRST_ID\n(?:    .*\n)*?)    status: pending\n/, \"\\\\1    status: done\n\"); s.sub!(/^(- \\*\\*$FIRST_ID\\*\\* .*) — not started\$/, \"\\\\1 — done\")"
expect_ok "done on a manual node is its terminal status"

# --------------------------------------------------------------------------------- ledger

mutate 's.sub!(/^- \*\*api-4\*\*.*\n/, "")'
expect_first "a node missing from the ledger" ledger "missing \`api-4\`"

mutate 's.sub!(/^(- \*\*api-2\*\*.*\n)(- \*\*web-1\*\*.*\n)/, "\\2\\1")'
expect_first "two ledger bullets swapped" ledger "leaves block order"
assert_has "  naming the bullet" "it has \`web-1\`, the block has \`api-2\`" "$OUT"

mutate 's.sub!(/^(- \*\*api-4\*\*.*\n)/, "\\1- **api-99** `x` — not started\n")'
expect_first "a ledger bullet for a node that does not exist" ledger "extra \`api-99\`"

# A bold bullet that is not id-shaped is preamble, not ledger. It sits after the ledger's
# last bullet: inside the run it would be one more thing the generator strips.
mutate 's.sub!("\n**Owner decisions, 2026-09-07**", "\n- **Rejected:** a bullet that is not a node\n\n**Owner decisions, 2026-09-07**")'
expect_ok "a non-id bold bullet in the preamble is not a ledger entry"

# The ids and their order intact, a title hand-edited: only the generator's rendering
# tells, and plan-format.md says the ledger is that rendering and nothing else.
mutate 's.sub!(/^(- \*\*api-4\*\* )`test\(db\): /, "\\1`test(db)!: ")'
expect_first "a ledger bullet hand-edited away from the block" ledger "not ontherun-plan-ledger.sh's rendering"
assert_has "  and says how to regenerate it" "ontherun-plan-ledger.sh $F --write" "$OUT"

# The generator's own refusals reach the report: a merged node the README says carries
# a sha, without one.
mutate 's.sub!(/^(  - id: api-1\n(?:    .*\n)*?)    status: pending\n/, "\\1    status: merged\n    pr: 1\n")'
expect_first "a merged node with no sha" ledger "refuses the block: node api-1: merged with no sha"

# Without the generator beside the script that half of the check is skipped, and a
# hand-edited title passes on ids and order alone.
mkdir -p "$TMP/alone"
cp "$LINT" "$TMP/alone/ontherun-plan-lint.sh"
mutate 's.sub!(/^(- \*\*api-4\*\* )`test\(db\): /, "\\1`test(db)!: ")'
OUT=$("$TMP/alone/ontherun-plan-lint.sh" "$F" 2>&1); RC=$?
assert_eq "  with no plan-ledger.sh beside the script, ids and order are the whole check" 0 "$RC"

# The format's `merged: YYYY-MM-DD` is a date to YAML, and a safe load has to permit it.
# Checked on the copy without the generator, whose rendering the bullet would then owe.
mutate 's.sub!(/^(  - id: api-1\n(?:    .*\n)*?)    status: pending\n/, "\\1    status: merged\n    pr: 1\n    sha: abc1234\n    merged: 2026-09-07\n")'
OUT=$("$TMP/alone/ontherun-plan-lint.sh" "$F" 2>&1); RC=$?
assert_eq "a merged: date field parses" 0 "$RC"
[ "$RC" -eq 0 ] || printf '        %s\n' "$OUT"

# Any other class the safe load refuses is a state-parse line, not a backtrace.
mutate 's.sub!(/^    agent: implementer-x?high\n/, "    agent: !ruby/object:Object {}\n")'
expect_first "a tag the safe load refuses" state-parse "unspecified class"

# --------------------------------------------------------------------------------- counts

mutate 's.sub!(/\bof its \d+ nodes/, "of its 999 nodes")'
expect_first "a wrong node count" counts "says 999 nodes; the block has $N"

mutate 's.sub!(/\b\d+ are PRs/, "999 are PRs")'
expect_first "a wrong PR count" counts "says 999 are PRs; the block has $PR"

# The sentence wraps in the plan, so its anchors accept any whitespace between words.
mutate 's.sub!(/\b\d+ are\s+things the conductor does/, "999 are things the conductor does")'
expect_first "a wrong conductor count" counts "says 999 are the conductor's; the block has $SETUP"

mutate "s.sub!(/\\b\\d+ are the owner's/, \"999 are the owner's\")"
expect_first "a wrong owner count" counts "says 999 are the owner's; the block has $MANUAL"

# The shorter phrasing, right and then wrong by one.
mutate "s.sub!(/of its \\d+ nodes,\\s+\\d+ are PRs,\\s+\\d+ are\\s+things the conductor does\\s+from its own session,\\s+and \\d+ are the owner's/, \"Of its $N nodes, $PR are PRs, $SETUP are the conductor's and $MANUAL are the owner's\")"
expect_ok "the conductor's/owner's phrasing with the right figures"

mutate "s.sub!(/of its \\d+ nodes,\\s+\\d+ are PRs,\\s+\\d+ are\\s+things the conductor does\\s+from its own session,\\s+and \\d+ are the owner's/, \"Of its $N nodes, $PR are PRs, $((SETUP + 1)) are the conductor's and $MANUAL are the owner's\")"
expect_first "  and off by one" counts "says $((SETUP + 1)) are the conductor's"

# ---------------------------------------------------------------------------------- round
#
# The fixture's Status names no round in flight; each case writes one in.

mutate "s.sub!(\"**Status: \", \"**Status: round $((LAST_ROUND + 1)) is in flight — \")"
expect_ok "round N+1 in flight with the history ending at round N"

mutate "s.sub!(\"**Status: \", \"**Status: Round $((LAST_ROUND + 1)) is in flight — \")"
expect_ok "  whatever the case of Round"

mutate "s.sub!(\"**Status: \", \"**Status: round $LAST_ROUND is in flight — \")"
expect_first "round N in flight when round N is already in the history" round \
  "round $LAST_ROUND is in flight, but ## Review history ends at round $LAST_ROUND"

mutate "s.sub!(\"**Status: \", \"**Status: round $((LAST_ROUND + 2)) is in flight — \")"
expect_first "a round two ahead of the history" round "ends at round $LAST_ROUND"

mutate 's.sub!("**Status: ", "**Status: not yet promoted — the first `plan-reviewer` round is in flight. ")'
expect_first "the creation sentence on a plan with a review history" round "round 1 is in flight, but ## Review history ends at round $LAST_ROUND"

mutate 's.sub!("**Status: ", "**Status: not yet promoted — the first `plan-reviewer` round is in flight. "); s.sub!(/^## Review history\n.*?(?=^## )/m, "")'
expect_ok "the creation sentence on a plan with no review history"

# ---------------------------------------------------------------------------------- draft

mutate 's.sub!("**Status: ", "**Status: DRAFT — ")'
expect_first "DRAFT beside a promotion" draft "names a promotion and carries the DRAFT marker"

# The paragraph rewritten whole: the marker with the block standing is the shallow park.
mutate 's.sub!(/\A(# .*\n\n)\*\*Status:.*?\n\n/m, "\\1**Status: DRAFT — parked at the cap.**\n\n")'
expect_ok "DRAFT with a ## State block is the shallow park"

mutate 's.sub!(/\A(# .*\n\n)\*\*Status:.*?\n\n/m, "\\1**Status: DRAFT — not yet promoted, capped.**\n\n")'
expect_ok "a negated promotion is not a promotion claim"

mutate 's.sub!(/\A(# .*\n\n)\*\*Status:.*?\n\n/m, "\\1**Status: DRAFT — parked.**\n\n"); s.sub!(/^## State\n\n```yaml\n.*?^```\n/m, "")'
expect_first "DRAFT with neither open questions nor a block" draft "neither"

mutate 's.sub!(/\A(# .*\n\n)\*\*Status:.*?\n\n/m, "\\1**Status: DRAFT — parked.**\n\n"); s.sub!(/^## State\n\n```yaml\n.*?^```\n/m, "## Open questions for the detailing pass\n\n- one\n")'
expect_ok "DRAFT with open questions and no block is a draft"

# ------------------------------------------------------------------------------ self-count
#
# The fixture carries none, so each case writes one into the Status paragraph, which is
# line 3 of the plan.

mutate 's.sub!("**Status: ", "**Status: the five rules below apply — ")'
expect_first "a number word before one of the plan's nouns" self-count 'line 3: "five rules"' 'write "the rules"'

mutate 's.sub!("**Status: ", "**Status: the five\nrules below apply — ")'
expect_first "  found across a line wrap" self-count '"five rules"'

mutate 's.sub!("**Status: ", "**Status: 13 nodes wait — ")'
expect_first "a digit before one" self-count '"13 nodes"'

mutate 's.sub!("**Status: ", "**Status: the three sweep PRs wait — ")'
expect_first "an adjective between them" self-count '"three sweep"'

mutate 's.sub!("**Status: ", "**Status: the Phase 3 nodes wait — ")'
expect_ok "a number that belongs to the word before it is a reference"

mutate 's.sub!("**Status: ", "**Status: two of the three node-repo conditions hold — ")'
expect_ok "a noun used as an adjective is not a count of nodes"

mutate 's.sub!("**Status: ", "**Status: two more rounds are budgeted — ")'
expect_ok "a budget is not a count of the page"

mutate 's.sub!("## Review history\n", "## Review history\n\nThe five rules held.\n")'
expect_ok "inside ## Review history a count narrates a moment"

mutate 's.sub!("\n**Owner decisions, 2026-09-07**", "\n12. **The five rules stand.** Ruled, and\n    the six nodes with them.\n\n**Owner decisions, 2026-09-07**")'
expect_ok "a numbered item and its continuation may count what they ruled on"

mutate 's.sub!("**Status: ", "**Status: the 2026-09-02 review round 1 ran — ")'
expect_ok "the tail of a date is not a count"

mutate 's.sub!("**Status: ", "**Status: set by the #56 owner decision; the PR 2 gates hold — ")'
expect_ok "a PR number and a PR reference are not counts"

mutate 's.sub!("**Status: ", "**Status: two review passes ran — ")'
expect_first "an irregular plural is advised correctly" self-count 'write "the passes"'

mutate "s.sub!(/^(  - id: api-1\n(?:    .*\n)*?    status: pending\n)/, \"\\\\1    delivered:\n      - conform.py:157 — Result.status is 0 pass / 1 a case failed\n\")"
expect_ok "a delivered: report is free text and is not read"

printf '# A strategy document\n\nIt describes three phases of the world.\n' > "$TMP/strategy-counts.md"
run "$TMP/strategy-counts.md"
assert_eq "a file with no **Status: line is not checked for counts" 0 "$RC"

# ----------------------------------------------------------------------- no Status line

printf '# A strategy document\n\nIt describes the world.\n\n## A section\n\ntext\n' > "$TMP/strategy.md"
run "$TMP/strategy.md"
assert_eq "a file with no **Status: line passes" 0 "$RC"

# ------------------------------------------------------------------------ the arguments

run
assert_eq "no arguments: usage, exit 64" 64 "$RC"
run "$TMP/no-such-plan.md"
assert_eq "an unreadable plan: exit 2" 2 "$RC"

# ---------------------------------------------------------------- linked ledgers
#
# The generator renders on a copy in a temp dir, and a copy resolves no workspace of its
# own; the lint pins it to the plan's root, so a ledger whose links came from a checkout's
# origin is fresh rather than stale.

g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
WS="$TMP/ws"
mkdir -p "$WS/plans"
g init -q "$WS/acme-api" && g -C "$WS/acme-api" remote add origin git@github.com:acme/acme-api.git
LINKED="$WS/plans/linked.md"
LC_ALL=en_US.UTF-8 ruby -Eutf-8:utf-8 -e '
  s = File.read(ARGV[0], encoding: "UTF-8")
  s.sub!(/^(  - id: api-1\n(?:    .*\n)*?)    status: pending\n/, "\\1    status: merged\n    pr: 41\n    sha: 0a1b2c3\n") or abort("anchor")
  File.write(ARGV[1], s)' -- "$FIXTURE" "$LINKED"
"$SCRIPT_DIR/ontherun-plan-ledger.sh" "$LINKED" --write 2>/dev/null
assert_has "the fixture's ledger now links api-1 to its origin" \
  "[#41](https://github.com/acme/acme-api/pull/41)" "$(cat "$LINKED")"
run "$LINKED"
assert_eq "  and a lint run elsewhere still finds it fresh" 0 "$RC"
[ "$RC" -eq 0 ] || printf '        %s\n' "$OUT"

# ------------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
