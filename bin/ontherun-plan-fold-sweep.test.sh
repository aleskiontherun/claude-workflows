#!/usr/bin/env bash
# Tests for ontherun-plan-fold-sweep.sh. No framework: a throwaway git repo holding one plan, a
# fold applied to it, `git diff` for the diff -- the same command ontherun-plan-fold-diff.sh runs
# -- and assertions on the report and the exit status.
#
#   ontherun-plan-fold-sweep.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs `git` and `perl`.
#
# **The fixture carries one survivor of every term shape, and one decoy for each rule
# that suppresses a term**: a paragraph the fold only re-wraps (its number must not
# become a term), a value the fold re-states in another hunk (the term stays, flagged,
# and the added line is not a hit), a number word wrapped across two lines and one in
# bold (both must be found), a longer number that contains the removed one (must not
# match), and a bare "1" (never a term on its own). Line numbers are asserted, so the
# fixture is written out twice rather than mutated -- the second copy is the fold.
# Every survivor sits on a line the fold leaves alone: a hit on a line the fold wrote
# is skipped by design, so a survivor placed on one would test nothing.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SWEEP="$SCRIPT_DIR/ontherun-plan-fold-sweep.sh"
FOLD="$SCRIPT_DIR/ontherun-plan-fold-diff.sh"

command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v perl >/dev/null || { echo "perl is required" >&2; exit 2; }

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

run() { OUT=$("$SWEEP" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

# ------------------------------------------------------------------------- the repo
#
# Signing is forced off per invocation rather than configured into the repo: never
# `git config` a value into a repo to test something.
REPO="$TMP/repo"
mkdir -p "$REPO/plans"
g() { git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q

PLAN="$REPO/plans/a.md"

write_base() {
cat > "$PLAN" <<'BASE'
# A plan (`acme-api`)

**Status: DRAFT — round 1 is in flight; six members differ.** Twenty-two files carry it.

## State

```yaml
nodes:
  - id: api-1
    status: pending
```

## Review history

- **2026-09-01, round 1 — `revise`.** The census differs on six members, said 384
  dives, and named `conform.WRITTEN`; the CI was three-step.

## Context — verified repo facts

The corpus holds 384 DM5 XML files; `conform.WRITTEN` is the set. Donated files sit
under `export/`. The reader raises at `registry.py` too, not 1384 times. It returns six
members, **six** of them bold, to the README, which
says "in this repository" twice, and the spec's CI is three-step.

This paragraph is only reflowed by the fold: it names 22 files and the value
stays the same on both sides of the diff.

Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.

## Verification

6. A zip of the 384 files yields one logbook of 384 dives; three-step CI runs, and
   the README's "in this repository" claim holds. The donated fixture stays, and
   `conform.WRITTEN` is checked.

Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.

### Appendix

Release A ships first; release A is tagged at `v0.1.0`.
The tag for release A is `v0.1.0`.
BASE
}

# The fold: the Status round and count move on; the corpus count, a code name and a
# rare word change on one line of ## Context and a quote and a compound on another; one
# paragraph is only re-wrapped; a line re-stating the old total is added under
# ## Verification; the release letter moves on in the appendix. Every old value is left
# standing somewhere else, on a line the fold does not touch.
write_folded() {
cat > "$PLAN" <<'FOLDED'
# A plan (`acme-api`)

**Status: DRAFT — round 2 is in flight; eight members differ.** Twenty-two files carry it.

## State

```yaml
nodes:
  - id: api-1
    status: pending
```

## Review history

- **2026-09-01, round 1 — `revise`.** The census differs on six members, said 384
  dives, and named `conform.WRITTEN`; the CI was three-step.

## Context — verified repo facts

The corpus holds 342 DM5 XML files; `registry.WRITTEN` is the set. Owner files sit
under `export/`. The reader raises at `registry.py` too, not 1384 times. It returns six
members, **six** of them bold, to the README, which
says "in the specification repository" twice, and the spec's CI is four-step.

This paragraph is only reflowed by the fold: it names 22 files and
the value stays the same on both sides of the diff.

Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.

## Verification

6. A zip of the 384 files yields one logbook of 384 dives; three-step CI runs, and
   the README's "in this repository" claim holds. The donated fixture stays, and
   `conform.WRITTEN` is checked.
   The other 42 of the 384 are freedives.

Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.
Padding line.

### Appendix

Release B ships first; release B is tagged at `v0.1.0`.
The tag for release A is `v0.1.0`.
FOLDED
}

write_base
g add plans/a.md
g commit -q -m "the plan"
write_folded
DIFF="$TMP/fold.diff"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"

echo "ontherun-plan-fold-sweep.sh"

# ------------------------------------------------------------ the fold, every shape

run "$PLAN" "$DIFF"
assert_eq "a fold with survivors: exit 1" 1 "$RC"
assert_eq "  and nothing on stderr" "" "$ERR"
assert_has "  the header counts the hunks and the removed lines" "ontherun-plan-fold-sweep: 4 hunks, 6 removed lines," "$OUT"
assert_has "  and the terms with survivors" "; 8 with survivors outside ## Review history" "$OUT"

assert_has "numword: the old count, once wrapped and once bold, plus the history line" \
  "numword  six  2 outside ## Review history, 1 in it" "$OUT"
assert_has "  the wrapped one is reported at the line its word sits on, under its heading" \
  "     21  Context — verified repo facts   under \`export/\`. The reader raises at" "$OUT"
assert_has "  the bold one too" "     22  Context — verified repo facts   members, **six** of them bold," "$OUT"
assert_has "  and the history hit by line number" "         ## Review history: 15" "$OUT"

assert_has "pair: the number word with its noun, found across the line wrap" \
  "pair     \"six members\"  1 outside ## Review history, 1 in it" "$OUT"

assert_has "num: the old total, with the re-statement in another hunk flagged" \
  "num      384  1 outside ## Review history, 1 in it, also written by the fold" "$OUT"
assert_has "  found where the scenario still says it" "     39  Verification                    6. A zip of the 384 files" "$OUT"
assert_lacks "  but not on the line the fold added" "     42  " "$OUT"
block=$(printf '%s\n' "$OUT" | sed -n '/^num      384/,/^$/p')
assert_lacks "  and not inside a longer number" "     21  " "$block"

assert_has "code: the renamed symbol, exact" \
  "code     \`conform.WRITTEN\`  1 outside ## Review history, 1 in it" "$OUT"
assert_has "  at its surviving line" "     41  Verification                    \`conform.WRITTEN\` is checked." "$OUT"

assert_has "quote: the replaced sentence" "quote    \"in this repository\"  1 outside ## Review history" "$OUT"
assert_has "compound: the hyphenated count" "compound three-step  1 outside ## Review history, 1 in it" "$OUT"
assert_has "word: a rare word the fold dropped, matched without regard to case" \
  "word     Donated  1 outside ## Review history" "$OUT"
assert_has "  at the line that still has it" "     40  Verification                    the README's" "$OUT"
assert_has "pair: a release letter" "pair     \"Release A\"  1 outside ## Review history" "$OUT"
assert_lacks "code: a tag the changed sentence keeps beside unchanged words is not a term" "code     \`v0.1.0\`" "$OUT"
assert_lacks "  nor is a pair on 'first' the sentence keeps" '"ships first"' "$OUT"
assert_has "  under the deepest heading above it" "     56  Appendix                        The tag for release A" "$OUT"

assert_has "terms with no survivor outside the history share one line, with their history count" \
  'no survivors outside ## Review history: pair "384 DM5", pair "flight six", pair "holds 384", pair "round 1" (1 in it)' "$OUT"
assert_lacks "a re-wrapped paragraph yields no term" "22 files" "$OUT"
assert_lacks "  nor does a word on both sides of a hunk" "Twenty-two" "$OUT"
assert_lacks "a bare one-digit number is never a term" "num 1" "$OUT"
assert_lacks "an added word is not a term" "specification" "$OUT"
assert_lacks "  nor an added count" "eight" "$OUT"
assert_lacks "  nor the new release letter" "Release B" "$OUT"
assert_lacks "a re-wrapped line carrying 'only' is not new text" "added lines to check" "$OUT"

# The most specific terms come first: one survivor before two.
first=$(printf '%s\n' "$OUT" | grep -n '^numword  six' | cut -d: -f1)
last=$(printf '%s\n' "$OUT" | grep -n -m1 '^code     ' | cut -d: -f1)
if [ -n "$first" ] && [ -n "$last" ] && [ "$last" -lt "$first" ]; then
  ok "terms are ranked by survivors, fewest first"
else
  bad "terms are ranked by survivors, fewest first" "code at line $last, numword at line $first"
fi
word_at=$(printf '%s\n' "$OUT" | grep -n '^word     ' | cut -d: -f1)
if [ -n "$word_at" ] && [ -n "$first" ] && [ "$first" -lt "$word_at" ]; then
  ok "  and the word tier comes after the rest, whatever its count"
else
  bad "  and the word tier comes after the rest, whatever its count" "word at line $word_at, numword at line $first"
fi

# --------------------------------------------------- the file ontherun-plan-fold-diff.sh writes

if [ -x "$FOLD" ]; then
  SCRATCH="$TMP/scratch"
  FROM_SCRIPT=$(CLAUDE_SCRATCHPAD="$SCRATCH" "$FOLD" "$PLAN" 2>/dev/null)
  run "$PLAN" "$FROM_SCRIPT"
  assert_eq "ontherun-plan-fold-diff.sh's file is accepted as-is" 1 "$RC"
  assert_has "  with the same survivors" "; 8 with survivors outside ## Review history" "$OUT"
else
  bad "ontherun-plan-fold-diff.sh's file is accepted as-is" "ontherun-plan-fold-diff.sh not found beside this test"
fi

# ------------------------------------------------------- survivors only in history

write_base
perl -pi -e 's/round 1 is in flight/round 2 is in flight/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a value surviving only in ## Review history: exit 0" 0 "$RC"
assert_has "  the header says so" "; 0 with survivors outside ## Review history" "$OUT"
assert_has "  and the term is listed with its history count" 'pair "round 1" (1 in it)' "$OUT"

# ------------------------------------------------------------- nothing to sweep for

write_base
printf 'A rule added at the end, removing nothing.\n' >> "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a fold that only adds: exit 0" 0 "$RC"
assert_has "  and says there is nothing to sweep for" "1 hunk, nothing removed" "$OUT"

write_base
# shellcheck disable=SC2016
printf 'The cap never moves, as `acme-web/compose.yml` says, and only the head reads it.\n' >> "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a fold that only adds an absolute and a path: exit 1" 1 "$RC"
assert_has "  still says there was nothing to sweep for" "1 hunk, nothing removed" "$OUT"
assert_has "  and lists the line with what matched" "added lines to check before the spawn (1)" "$OUT"
# shellcheck disable=SC2016
assert_has "  the absolutes and the path, in order" '[never; only; `acme-web/compose.yml`]  The cap never moves' "$OUT"
assert_has "  under its heading" "     56  Appendix                        [never" "$OUT"

write_base
perl -pi -e 's/Donated files sit/Donated files always sit/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "an absolute written into a changed sentence: exit 1" 1 "$RC"
assert_has "  is listed although no term survives" "added lines to check before the spawn (1)" "$OUT"
assert_has "  at its line" "     20  Context — verified repo facts   [always]  The corpus holds" "$OUT"

write_base
perl -0pi -e 's/22 files and the value\nstays/22 files and\nthe value stays/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a fold that only re-wraps: exit 0" 0 "$RC"
assert_has "  and says every value was re-stated" "0 terms; every removed value is re-stated in its own hunk" "$OUT"

# "not" is an article-class word, so the only pair is the one on the number's right; the
# code name the changed sentence keeps sits beside unchanged words and is not a term.
write_base
perl -pi -e 's/not 1384 times/not 1385 times/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a value with no echo: exit 0" 0 "$RC"
assert_has "  listed on the no-survivors line" 'no survivors outside ## Review history: pair "1384 times", num 1384' "$OUT"
assert_lacks "  and the file name beside the changed count is old text, not a path to check" "added lines to check" "$OUT"

# ------------------------------------------------------- references and moves

write_base
perl -pi -e 's/^Padding line\.$/See `api-1` and `## Review history` nearby./ if $. == 28' "$PLAN"
g add plans/a.md
g commit -q -m "a line of references"
perl -ni -e 'print unless $. == 28' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a removed line of references: exit 0" 0 "$RC"
assert_lacks "  a bare node id is not a term" "code \`api-1\`" "$OUT"
assert_lacks "  nor is a heading reference" "code \`## Review history\`" "$OUT"
assert_has "  the plain word beside them is" "word nearby" "$OUT"

write_base
g add plans/a.md
g commit -q -m "the plan again"
perl -pi -e 's/Donated files sit/Owner files sit/' "$PLAN"
printf 'Donated by the owner.\n' >> "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_lacks "a removed word the fold wrote elsewhere is a move, not a term" "word     Donated" "$OUT"
assert_lacks "  and is not reported as common either" "skipped as common" "$OUT"

write_base
perl -pi -e 's/^Padding line\.$/Depths of 3.45–12.04 m and 3–60 s./ if $. == 28' "$PLAN"
g add plans/a.md
g commit -q -m "a range"
perl -pi -e 's/3\.45–12\.04 m/1.39–15.48 m/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a range with a one-letter unit: exit 0" 0 "$RC"
assert_has "  the range is a term on its own" "num 3.45–12.04" "$OUT"
assert_lacks "  and its unit makes no pair" 'pair "3.45–12.04 m"' "$OUT"

# ------------------------------------------- wrapped spans, one-word quotes, names

write_base
perl -pi -e 's#^Padding line\.$#Run `git grep -n something# if $. == 28; s#^Padding line\.$#origin/main -- src` to see it, with "profile" and `fold-checker`.# if $. == 29' "$PLAN"
g add plans/a.md
g commit -q -m "a wrapped span"
perl -pi -e 's/-n something/-n another/; s/"profile"/"depth"/; s/`fold-checker`/`plan-reviewer`/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_has "a backticked span wrapped across two lines is one term" "code \`git grep -n something origin/main -- src\`" "$OUT"
assert_lacks "  and its halves are not" "code \`origin/main" "$OUT"
assert_has "a one-word quote is a word" "word profile" "$OUT"
assert_lacks "  not a quote" 'quote "profile"' "$OUT"
assert_lacks "a hyphenated lowercase name is a reference, not a term" "fold-checker" "$OUT"

# ------------------------------------------------------------- an appended enumerator
#
# Appending to a list is ontherun-plan-lint.sh's business (the self-count check); here it is a
# fold that only adds, and a list that is merely re-wrapped yields nothing.

write_base
perl -pi -e 's/^Padding line\.$/The five rules: (1) a, (2) b, (3) c, (4) d and (5) e./ if $. == 28' "$PLAN"
g add plans/a.md
g commit -q -m "five rules"
printf '(6) f, appended at the end.\n' >> "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "an enumerator appended with nothing removed: exit 0" 0 "$RC"
assert_has "  is nothing to sweep for" "nothing removed" "$OUT"

write_base
perl -pi -e 's/^Padding line\.$/The rules: (1) a, (2) b, (3) c. Twenty-two of them./ if $. == 28' "$PLAN"
g add plans/a.md
g commit -q -m "three rules on one line"
perl -pi -e 's/^The rules: \(1\) a, \(2\) b, \(3\) c\. Twenty-two of them\.$/The rules: (1) a, (2) b,\n(3) c. Twenty-two of them./' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a re-wrapped enumerated list: exit 0" 0 "$RC"
assert_has "  yields no term" "0 terms" "$OUT"

# -------------------------------------------------------------------- the caps
#
# The echoes are of a code term, which no other term matches, so the counts below are
# that term's alone.

write_base
for _ in $(seq 15); do printf "Still \`conform.WRITTEN\` here.\\n" >> "$PLAN"; done
g add plans/a.md
g commit -q -m "fifteen echoes"
perl -pi -e 's/conform\.WRITTEN/registry.WRITTEN/ if $. == 20' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "sixteen survivors: exit 1" 1 "$RC"
assert_has "  the list stops at twelve" "         and 4 more; --all lists them" "$OUT"
n=$(printf '%s\n' "$OUT" | grep -c "Still \`conform.WRITTEN\` here")
assert_eq "  showing eleven of the fifteen echoes after the scenario's own" 11 "$n"
run --all "$PLAN" "$DIFF"
n=$(printf '%s\n' "$OUT" | grep -c "Still \`conform.WRITTEN\` here")
assert_eq "--all lists all fifteen" 15 "$n"
assert_lacks "  and drops the tail line" "--all lists them" "$OUT"

# Forty-five echoes plus the scenario's "one logbook" is 46; "line" stays on both sides
# so the number word is the only term with a survivor.
write_base
for _ in $(seq 45); do printf 'Exactly one thing here.\n' >> "$PLAN"; done
g add plans/a.md
g commit -q -m "a common number word"
perl -pi -e 's/^Padding line\.$/Only one padding line./ if $. == 28' "$PLAN"
g add plans/a.md
g commit -q -m "one to remove"
perl -pi -e 's/Only one padding line/Only two padding line/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a number word with more than forty survivors: exit 1 still" 1 "$RC"
assert_has "  is summarised, not listed" "numword  one  46 outside ## Review history -- not listed" "$OUT"
n=$(printf '%s\n' "$OUT" | grep -c 'Exactly one thing here')
assert_eq "  none of its lines shown" 0 "$n"
assert_lacks "  and nothing was skipped as common" "skipped as common" "$OUT"
run --all "$PLAN" "$DIFF"
n=$(printf '%s\n' "$OUT" | grep -c 'Exactly one thing here')
assert_eq "--all lists all forty-five" 45 "$n"

write_base
for _ in $(seq 45); do printf "Uses \`acmelib\` here.\\n" >> "$PLAN"; done
perl -pi -e 's/^Padding line\.$/Also `acmelib` once./ if $. == 28' "$PLAN"
g add plans/a.md
g commit -q -m "a common code term"
perl -pi -e 's/Also `acmelib` once/Also `other` once/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_has "a code term with more than forty survivors is summarised too" \
  "code     \`acmelib\`  45 outside ## Review history -- not listed, a term this common is noise" "$OUT"

# ---------------------------------------------------------- a condition that grows

write_base
perl -pi -e 's/^Padding line\.$/The gate waits for the spec to be `open`./ if $. == 28; s/^Padding line\.$/Launch once the spec is `open`, and not before./ if $. == 45' "$PLAN"
g add plans/a.md
g commit -q -m "a gate on open"
perl -pi -e 's/to be `open`\.$/to be `open` and corrected./' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a condition that keeps its old value and grows: exit 1" 1 "$RC"
assert_has "  the old value is a term although the new sentence keeps it" "code     \`open\`  1 outside ## Review history, also written by the fold" "$OUT"
assert_has "  found at the statement the fold did not reach" "     45  Verification                    Launch once the spec is" "$OUT"

# A kept name whose neighbours did not move is not a term, even in a changed sentence.
write_base
perl -pi -e 's/^Padding line\.$/The `conform` step runs after the census./ if $. == 28; s/^Padding line\.$/Only `conform` decides./ if $. == 45' "$PLAN"
g add plans/a.md
g commit -q -m "a kept name"
perl -pi -e 's/after the census\./after the corrected census./' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a changed sentence keeping a name beside unchanged words: exit 0" 0 "$RC"
assert_lacks "  the name is not a term" "\`conform\`" "$OUT"

# A span that wraps from a changed line into an unchanged one is not half a term.
write_base
perl -pi -e 's#^Padding line\.$#Run `git grep -n something# if $. == 28; s#^Padding line\.$#origin/main -- src` to see it.# if $. == 29' "$PLAN"
g add plans/a.md
g commit -q -m "a span into an unchanged line"
perl -pi -e 's/-n something$/-n another/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_lacks "an unpaired backtick pairs with nothing" "code \`origin/main" "$OUT"
assert_lacks "  and yields no fragment" "to see it" "$OUT"

# A removed line that starts inside a span opened on the unchanged line above it.
write_base
perl -pi -e 's#^Padding line\.$#See the `long command# if $. == 28; s#^Padding line\.$#continues here` and then `plans/x.md` too.# if $. == 29' "$PLAN"
g add plans/a.md
g commit -q -m "a span from an unchanged line"
perl -pi -e 's/`plans\/x\.md` too\.$/`plans\/x.md` also./' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_lacks "the stray is the closer, not the opener" "code \` and then \`" "$OUT"
assert_has "  and the real span beside the changed word is the term" "code \`plans/x.md\`" "$OUT"

# A glob inside a span is part of the name, not emphasis.
write_base
perl -pi -e 's#^Padding line\.$#The sweep reads `plans/*.md` for it.# if $. == 28; s#^Padding line\.$#Every file under `plans/*.md` is a plan.# if $. == 45' "$PLAN"
g add plans/a.md
g commit -q -m "a globbed span"
perl -pi -e 's#reads `plans/\*\.md` for it#reads `plans/done/*.md` for it#' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a globbed span removed from one sentence and kept in another: exit 1" 1 "$RC"
assert_has "  the name keeps its glob" "code     \`plans/*.md\`  1 outside ## Review history" "$OUT"
assert_lacks "  and is not stripped to a name that exists nowhere" "plans/.md" "$OUT"

# The Status sentence the main fold reworded keeps its plain words out of the word tier.
write_base
g add plans/a.md
g commit -q -m "the plan once more"
write_folded
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_lacks "a reworded sentence's plain words are not terms" "word     DRAFT" "$OUT"
assert_lacks "  nor on the no-survivors line" "word DRAFT" "$OUT"
assert_lacks "  even when one survives elsewhere" "word     members" "$OUT"
g checkout -q -- plans/a.md

# ------------------------------------------ ordinary words, State keys, number words

write_base
perl -pi -e 's/^Padding line\.$/Everything returned here stands, per the `status` and `id` fields./ if $. == 28' "$PLAN"
g add plans/a.md
g commit -q -m "ordinary words and state keys"
perl -pi -e 's/^Everything returned here stands, per the `status` and `id` fields\.$/Padding line./' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_lacks "an ordinary English word is not a term, whatever its case" "Everything" "$OUT"
assert_lacks "  nor a verb" "returned" "$OUT"
assert_lacks "  nor another" "stands" "$OUT"
assert_lacks "a backticked field name of the State block is a reference" "\`status\`" "$OUT"
assert_lacks "  and so is the id field" "\`id\`" "$OUT"

write_base
for _ in $(seq 16); do printf 'Only six here.\n' >> "$PLAN"; done
g add plans/a.md
g commit -q -m "sixteen sixes"
perl -pi -e 's/six members differ/eight members differ/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_has "a number word with more than fifteen survivors is summarised" \
  "numword  six  18 outside ## Review history, 1 in it -- not listed, a term this common is noise" "$OUT"
assert_has "  while its pair is listed in full" "pair     \"six members\"  1 outside ## Review history, 1 in it" "$OUT"

# ------------------------------------------------------------ the rare-word bound

write_base
for _ in $(seq 7); do printf 'A donated line.\n' >> "$PLAN"; done
g add plans/a.md
g commit -q -m "seven donated lines"
perl -pi -e 's/Donated files/Owner files/' "$PLAN"
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
run "$PLAN" "$DIFF"
assert_eq "a removed word surviving eight times: not a term, exit 0" 0 "$RC"
assert_has "  and named as skipped" "skipped as common (more than 6 survivors; --rare N raises it): Donated" "$OUT"
run --rare 10 "$PLAN" "$DIFF"
assert_eq "--rare 10 admits it: exit 1" 1 "$RC"
assert_has "  with all eight" "word     Donated  8 outside ## Review history" "$OUT"

# ------------------------------------------------------------------- refusals

g checkout -q -- plans/a.md
run
assert_eq "no arguments: usage, exit 64" 64 "$RC"
run "$PLAN"
assert_eq "one argument: usage, exit 64" 64 "$RC"
run "$PLAN" "$DIFF" extra
assert_eq "three arguments: usage, exit 64" 64 "$RC"
run --rare x "$PLAN" "$DIFF"
assert_eq "--rare without a number: usage, exit 64" 64 "$RC"
run --bogus "$PLAN" "$DIFF"
assert_eq "an unknown flag: usage, exit 64" 64 "$RC"

run "$TMP/missing.md" "$DIFF"
assert_eq "a plan that does not exist: exit 2" 2 "$RC"
assert_has "  says which" "cannot read $TMP/missing.md" "$ERR"
run "$PLAN" "$TMP/missing.diff"
assert_eq "a diff that does not exist: exit 2" 2 "$RC"

printf 'not a diff\n' > "$TMP/not.diff"
run "$PLAN" "$TMP/not.diff"
assert_eq "a file that is not a diff: exit 2" 2 "$RC"
assert_has "  says so" "is not a unified diff of one file" "$ERR"

printf '# Plan B\n\nline one\n' > "$REPO/plans/b.md"
g add plans/b.md
g commit -q -m "a second plan"
perl -pi -e 's/round 1 is in flight/round 2 is in flight/' "$PLAN"
printf 'line two\n' >> "$REPO/plans/b.md"
git -C "$REPO" diff HEAD -- plans/ > "$TMP/two.diff"
run "$PLAN" "$TMP/two.diff"
assert_eq "a diff of two files: exit 2" 2 "$RC"
assert_has "  says how many and whose diff to hand over" "carries 2 files; hand over ontherun-plan-fold-diff.sh's diff" "$ERR"
git -C "$REPO" diff HEAD -- plans/b.md > "$TMP/other.diff"
run "$PLAN" "$TMP/other.diff"
assert_eq "a diff of a different file: exit 2" 2 "$RC"
assert_has "  names both" "is a diff of plans/b.md, not of $PLAN" "$ERR"
g checkout -q -- plans/

write_folded
git -C "$REPO" diff HEAD -- plans/a.md > "$DIFF"
perl -pi -e 's/Padding line\./Padding line, edited./ if $. == 28' "$PLAN"
run "$PLAN" "$DIFF"
assert_eq "a diff older than the plan: exit 2" 2 "$RC"
assert_has "  says to regenerate it" "does not match $PLAN at line 28; the plan has changed since it was written -- regenerate it" "$ERR"

# ------------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
