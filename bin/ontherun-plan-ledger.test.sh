#!/usr/bin/env bash
# Fixtures quote code in backticks inside single quotes, on purpose.
# shellcheck disable=SC2016
# Tests for ontherun-plan-ledger.sh. No framework: fixture plans written into a throwaway
# workspace whose nested checkouts carry fake GitHub remotes, the script run against them,
# and assertions on stdout, stderr, exit status and the rewritten file.
#
#   ontherun-plan-ledger.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs git. Runs in about a second.
#
# The fixture blocks are written the way plans write them, quoting included: the
# octal-looking `sha: 0124767` is in the first one because a YAML parser would have
# turned it into a number, and the point of parsing by hand is that it does not.
#
# Links come from each checkout's `origin`, so the workspace holds one checkout per URL
# form the script must read (scp-style, ssh://, https), one two levels down, one whose
# remote is not GitHub, and a repo the block names with no checkout at all. Both layouts
# are covered -- a workspace repo with nested checkouts, and a single repo whose `plans/`
# is a nested git repo of its own -- plus $ONTHERUN_WORKSPACE and a plan read from a worktree
# of the workspace repo, which carries none of the nested checkouts.
#
# git runs with per-command overrides only, never `git config` into a repo, and with
# signing off: a machine whose global config signs commits has no key for a throwaway one.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LEDGER="$SCRIPT_DIR/ontherun-plan-ledger.sh"

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

assert_out() { # name expected-text actual-text
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1" "expected:" "$2" "actual:" "$3"; fi
}

assert_has() { # name needle haystack
  case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain |$2|" "got |$3|" ;; esac
}

assert_lacks() { # name needle haystack
  case $3 in *"$2"*) bad "$1" "expected NOT to contain |$2|" "got |$3|" ;; *) ok "$1" ;; esac
}

assert_same_file() { # name expected-file actual-file
  if cmp -s "$2" "$3"; then ok "$1"
  else bad "$1" "$(diff "$2" "$3" 2>&1 | head -20)"; fi
}

run() { OUT=$("$LEDGER" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# The workspace: a git repo of its own holding plans/, with the checkouts nested inside.
WS="$TMP/ws"
mkdir -p "$WS/plans/done"
checkout() { # path remote-url -> a checkout under the workspace with that origin
  mkdir -p "$WS/$1"
  g init -q "$WS/$1"
  g -C "$WS/$1" remote add origin "$2"
}
checkout acme-api   git@github.com:acme/acme-api.git
checkout acme-web   https://github.com/acme/acme-web.git
checkout acme-site  ssh://git@github.com/acme/acme-site
checkout tools/spec git@github.com:acme-org/spec.git
checkout tools/sdk  https://gitlab.com/acme/sdk.git
printf 'acme-api/\nacme-web/\nacme-site/\ntools/\n' > "$WS/.gitignore"
g init -q "$WS"
g -C "$WS" add .gitignore && g -C "$WS" commit -q -m workspace
WS_REAL=$(cd "$WS" && pwd -P)       # the script reports physical paths (/private/var on macOS)

# A minimal plan around a block: `plan <file> <block-file> [<preamble-file>]`. The
# preamble defaults to a one-line Status with no ledger.
plan() {
  local out=$1 block=$2 pre=${3:-}
  case $out in /*) ;; *) out=$WS/plans/$out ;; esac
  {
    echo '# A plan (`acme-api` + `acme-web`)'
    echo
    if [ -n "$pre" ]; then cat "$pre"; else echo '**Status:** live.'; echo; fi
    echo '## State'
    echo
    echo '```yaml'
    cat "$block"
    echo '```'
    echo
    echo '## Build order'
    echo
    echo '- **api-1** is first, and this bullet is prose that must survive a --write.'
  } > "$out"
}

echo "ontherun-plan-ledger.sh"

# ------------------------------------------------------------------ every status

cat > "$TMP/statuses.yaml" <<'YAML'
repos: [acme-api, acme-web, acme-site, tools/spec, tools/sdk]
nodes:
  - id: manual-1
    kind: manual
    title: "The owner's account"
    needs: []
    agent: owner
    status: done
    check: "it exists"
  - id: setup-1
    kind: setup
    title: "The org profile: acme/.github"
    needs: [manual-1]
    agent: conductor
    status: pending
    check: "gh repo view acme/.github --json visibility reports PUBLIC"
  - id: api-1
    repo: acme-api
    title: "feat(files)!: a second blob backend"
    needs: []
    agent: implementer-high
    status: merged
    branch: claude/api-1-blob
    pr: 160
    sha: 0124767
    merged: 2026-09-08
    delivered:
      - src/app/core/blob_store.py:61 — the backend
      - |
        a block scalar
        that spans lines
  - id: web-1
    repo: acme-web
    title: "feat(files): the picker"
    needs: [api-1]
    agent: implementer
    status: merged
    branch: claude/web-1-picker
    pr: 170
    sha: "9908764"
  - id: front-1
    repo: acme-site
    title: "docs: object storage"
    needs: [api-1]
    agent: implementer
    status: open
    branch: claude/front-1-docs
    pr: 12
  - id: spec-1
    repo: tools/spec
    title: "docs: the README links the application repositories"
    needs: []
    agent: implementer
    status: draft-pr
    branch: claude/spec-1-readme
    pr: 9
  - id: py-1
    repo: tools/sdk
    title: "feat: the package"
    needs: [spec-1]
    agent: implementer
    status: running
    branch: claude/py-1-package
  - id: api-2
    repo: acme-api
    title: "chore: after the flip"
    needs: [api-1, web-1]
    agent: implementer
    status: pending
  - id: api-3
    repo: acme-api
    title: "docs: README badges"
    needs: []
    agent: implementer
    status: blocked
    reason: "the owner's ruling on badges (decision 3)"
  - id: web-2
    repo: acme-web
    title: "docs: README badges"
    needs: []
    agent: implementer
    status: blocked
  - id: web-3
    repo: acme-web
    title: "chore: the devcontainer"
    needs: []
    agent: implementer
    status: dropped
  - id: api-4
    repo: acme-api
    title: "fix: something"
    needs: []
    agent: implementer
    status: running
  - id: sdk-1
    repo: tools/sdk
    title: "feat: a remote that is not GitHub"
    needs: []
    agent: implementer
    status: open
    pr: 4
  - id: gone-1
    repo: "acme-gone"
    title: "fix: a repo with no checkout"
    needs: []
    agent: implementer
    status: merged
    pr: 3
    sha: abc1234
YAML
plan statuses.md "$TMP/statuses.yaml"

run "$WS/plans/statuses.md"
assert_eq "every status: exit 0" 0 "$RC"
assert_out "every status renders its phrase; sha 0124767 is text, not a number" \
'- **manual-1** The owner'"'"'s account — done
- **setup-1** The org profile: acme/.github — not started, needs `manual-1`
- **api-1** `feat(files)!: a second blob backend` — [#160](https://github.com/acme/acme-api/pull/160) merged 2026-09-08, squash [`0124767`](https://github.com/acme/acme-api/commit/0124767)
- **web-1** `feat(files): the picker` — [#170](https://github.com/acme/acme-web/pull/170) merged, squash [`9908764`](https://github.com/acme/acme-web/commit/9908764)
- **front-1** `docs: object storage` — [#12](https://github.com/acme/acme-site/pull/12) open, awaiting review
- **spec-1** `docs: the README links the application repositories` — [#9](https://github.com/acme-org/spec/pull/9) draft, waiting on the human
- **py-1** `feat: the package` — in progress on `claude/py-1-package`
- **api-2** `chore: after the flip` — not started, needs `api-1`, `web-1`
- **api-3** `docs: README badges` — blocked: the owner'"'"'s ruling on badges (decision 3)
- **web-2** `docs: README badges` — blocked
- **web-3** `chore: the devcontainer` — dropped
- **api-4** `fix: something` — in progress
- **sdk-1** `feat: a remote that is not GitHub` — #4 open, awaiting review
- **gone-1** `fix: a repo with no checkout` — #3 merged, squash `abc1234`' "$OUT"
assert_has "a non-GitHub remote is named on stderr" \
  "no GitHub checkout for \`tools/sdk\` under $WS_REAL" "$ERR"
assert_has "  and so is a repo with no checkout" "no GitHub checkout for \`acme-gone\`" "$ERR"
assert_lacks "  but not a repo whose nodes need no link" "\`tools/spec\`" "$ERR"

# --------------------------------------------------------------------- quoting

cat > "$TMP/quoting.yaml" <<'YAML'
repos: [acme-api, acme-web]
nodes:
  - id: api-1
    repo: acme-api
    title: "feat(auth): a \"quoted\" title: with a colon and a \\ backslash"
    needs: []
    agent: implementer
    status: pending
  - id: api-2
    repo: acme-api
    title: 'fix: it''s single-quoted'
    needs: [ api-1 , "web-1" ]
    agent: implementer
    status: pending
  - id: web-1
    repo: acme-web
    title: docs: a plain scalar # with a trailing comment
    needs: []
    agent: implementer
    status: pending
  - id: web-2
    repo: acme-web
    title: "a double-quoted title
      folded across two lines"
    needs: []
    agent: implementer
    status: pending
YAML
plan "$TMP/quoting.md" "$TMP/quoting.yaml"

run "$TMP/quoting.md"
assert_out "double quotes unescape, single quotes fold '', plain drops its comment, a folded scalar joins" \
'- **api-1** `feat(auth): a "quoted" title: with a colon and a \ backslash` — not started
- **api-2** `fix: it'"'"'s single-quoted` — not started, needs `api-1`, `web-1`
- **web-1** `docs: a plain scalar` — not started
- **web-2** `a double-quoted title folded across two lines` — not started' "$OUT"

# ---------------------------------------------------------------- phase headings

cat > "$TMP/phases.yaml" <<'YAML'
repos: [acme-api, acme-web]
nodes:
  # ---- Phase 1: pre-launch ----
  - id: api-1
    repo: acme-api
    title: "feat: one"
    needs: []
    agent: implementer
    status: pending
  - id: api-2
    repo: acme-api
    title: "feat: two"
    needs: [api-1]
    agent: implementer
    status: pending
  # ---- Phase 2: launch ----
  - id: web-1
    repo: acme-web
    title: "feat: three"
    needs: [api-2]
    agent: implementer
    status: pending
  # a comment that is not a phase marker attaches nothing
  - id: web-2
    repo: acme-web
    title: "feat: four"
    needs: [web-1]
    agent: implementer
    status: pending
  # ---- Phase 3 ----
  - id: web-3
    repo: acme-web
    title: "feat: five"
    needs: [web-2]
    agent: implementer
    status: pending
YAML

plan "$TMP/phases-fresh.md" "$TMP/phases.yaml"
run "$TMP/phases-fresh.md"
assert_out "headings are derived from the block's comments when the plan has none" \
'**Phase 1 — Pre-launch**

- **api-1** `feat: one` — not started
- **api-2** `feat: two` — not started, needs `api-1`

**Phase 2 — Launch**

- **web-1** `feat: three` — not started, needs `api-2`
- **web-2** `feat: four` — not started, needs `web-1`

**Phase 3**

- **web-3** `feat: five` — not started, needs `web-2`' "$OUT"

# Two headings written by hand, with parentheticals, for three phase comments. The
# prose between the Status paragraph and the ledger is the kind a phased plan carries.
cat > "$TMP/phases-pre.md" <<'EOF'
**Status: ready to implement** — promoted 2026-09-07, nothing has
launched yet.

This is the first plan to carry phases, and this paragraph sits between the Status
paragraph and the ledger.

**Phase 1 — Pre-launch** (repos private)

- **api-1** `feat: one` — stale
- **api-2** `feat: stale title` — in progress on `claude/api-2-old`

**Phase 2 — Launch** (releases exist)

- **web-1** `feat: three` —
  wrapped onto a second line, the way the README's examples are
- **web-2** `feat: four` — not started, needs `web-1`
- **web-3** `feat: five` — not started,
  needs `web-2`

**Owner decisions, 2026-09-07** — a bold-led paragraph after the ledger that must
not be mistaken for a heading.

EOF
plan "$TMP/phases.md" "$TMP/phases.yaml" "$TMP/phases-pre.md"

run "$TMP/phases.md"
assert_out "existing headings are kept by position, with their parentheticals; the third is derived" \
'**Phase 1 — Pre-launch** (repos private)

- **api-1** `feat: one` — not started
- **api-2** `feat: two` — not started, needs `api-1`

**Phase 2 — Launch** (releases exist)

- **web-1** `feat: three` — not started, needs `api-2`
- **web-2** `feat: four` — not started, needs `web-1`

**Phase 3**

- **web-3** `feat: five` — not started, needs `web-2`' "$OUT"

cp "$TMP/phases.md" "$TMP/phases-written.md"
run "$TMP/phases-written.md" --write
assert_eq "--write: exit 0, silent" "0|" "$RC|$OUT"
cat > "$TMP/phases-expected.md" <<'EOF'
# A plan (`acme-api` + `acme-web`)

**Status: ready to implement** — promoted 2026-09-07, nothing has
launched yet.

This is the first plan to carry phases, and this paragraph sits between the Status
paragraph and the ledger.

**Phase 1 — Pre-launch** (repos private)

- **api-1** `feat: one` — not started
- **api-2** `feat: two` — not started, needs `api-1`

**Phase 2 — Launch** (releases exist)

- **web-1** `feat: three` — not started, needs `api-2`
- **web-2** `feat: four` — not started, needs `web-1`

**Phase 3**

- **web-3** `feat: five` — not started, needs `web-2`

**Owner decisions, 2026-09-07** — a bold-led paragraph after the ledger that must
not be mistaken for a heading.

## State

EOF
sed -n '/^## State$/,$p' "$TMP/phases.md" | tail -n +3 >> "$TMP/phases-expected.md"
assert_same_file "--write replaces the ledger and its headings in place; the leading heading is not duplicated, the wrapped bullets (the last one included) are one line, prose on both sides and the ## Build order bullet survive" \
  "$TMP/phases-expected.md" "$TMP/phases-written.md"

cp "$TMP/phases-written.md" "$TMP/phases-again.md"
run "$TMP/phases-again.md" --write
assert_same_file "--write is idempotent" "$TMP/phases-written.md" "$TMP/phases-again.md"

# The block's first node opens no phase, so a bold line above the bullets is prose and
# stays where it is -- once.
cat > "$TMP/nophase-pre.md" <<'EOF'
**Status:** live.

**Not a heading**

- **api-1** `feat: one` — stale

EOF
cat > "$TMP/nophase.yaml" <<'YAML'
repos: [acme-api]
nodes:
  - id: api-1
    repo: acme-api
    title: "feat: one"
    needs: []
    agent: implementer
    status: pending
YAML
plan "$TMP/nophase.md" "$TMP/nophase.yaml" "$TMP/nophase-pre.md"
run "$TMP/nophase.md" --write
assert_eq "a bold line above the bullets is left alone when the block opens no phase" \
  1 "$(grep -c '^\*\*Not a heading\*\*$' "$TMP/nophase.md")"
assert_eq "  and the bullet under it was rewritten" \
  1 "$(grep -c '^- \*\*api-1\*\* `feat: one` — not started$' "$TMP/nophase.md")"

# ------------------------------------------------------ --write with no ledger yet

plan "$TMP/fresh.md" "$TMP/nophase.yaml"
run "$TMP/fresh.md" --write
assert_out "a plan with no ledger gets one after its Status paragraph" \
'# A plan (`acme-api` + `acme-web`)

**Status:** live.

- **api-1** `feat: one` — not started

## State' "$(sed -n '1,7p' "$TMP/fresh.md")"

cat > "$TMP/tight-pre.md" <<'EOF'
**Status:** live, and the paragraph
runs straight into the next heading.
EOF
plan "$TMP/tight.md" "$TMP/nophase.yaml" "$TMP/tight-pre.md"
run "$TMP/tight.md" --write
assert_out "  even when no blank line separates the Status paragraph from ## State" \
'**Status:** live, and the paragraph
runs straight into the next heading.

- **api-1** `feat: one` — not started

## State' "$(sed -n '3,8p' "$TMP/tight.md")"

# ------------------------------------------------------------------------ errors

cat > "$TMP/nopr.yaml" <<'YAML'
repos: [acme-api]
nodes:
  - id: api-1
    repo: acme-api
    title: "feat: one"
    needs: []
    agent: implementer
    status: open
    branch: claude/api-1-one
  - id: api-2
    repo: acme-api
    title: "feat: two"
    needs: []
    agent: implementer
    status: merged
    branch: claude/api-2-two
    pr: 5
  - id: api-3
    repo: acme-api
    title: "feat: three"
    needs: []
    agent: implementer
    status: done
  - id: api-4
    repo: acme-api
    title: "feat: four"
    needs: []
    agent: implementer
    status: shipped
YAML
plan "$TMP/nopr.md" "$TMP/nopr.yaml"
cp "$TMP/nopr.md" "$TMP/nopr-before.md"
run "$TMP/nopr.md" --write
assert_eq "a node missing what its status needs: exit 1" 1 "$RC"
assert_has "  open with no pr is named, under the prefix ontherun-plan-lint.sh strips" \
  "ontherun-plan-ledger: $TMP/nopr.md: node api-1: open with no pr" "$ERR"
assert_has "  merged with no sha is named" "node api-2: merged with no sha" "$ERR"
assert_has "  done on a pr node is named" "node api-3: done on a pr node" "$ERR"
assert_has "  an unknown status is named" "node api-4: unknown status \`shipped\`" "$ERR"
assert_eq "  and nothing is printed" "" "$OUT"
assert_same_file "  and the file is untouched" "$TMP/nopr-before.md" "$TMP/nopr.md"

printf '# A strategy document\n\nNo Status line, no block.\n' > "$TMP/strategy.md"
run "$TMP/strategy.md"
assert_eq "no ## State block: exit 1" 1 "$RC"
assert_has "  and says so" "no \`## State\` block" "$ERR"

run "$TMP/no-such-plan.md"
assert_eq "an unreadable plan: exit 1" 1 "$RC"
run
assert_eq "no arguments: usage, exit 64" 64 "$RC"
run "$WS/plans/statuses.md" "$TMP/quoting.md"
assert_eq "two plans: usage, exit 64" 64 "$RC"
run "$WS/plans/statuses.md" --wrote
assert_eq "an unknown flag: usage, exit 64" 64 "$RC"

# ------------------------------------------------------------------- the layouts

cat > "$TMP/one.yaml" <<'YAML'
repos: [acme-api]
nodes:
  - id: api-1
    repo: acme-api
    title: "feat: one"
    needs: []
    agent: implementer
    status: merged
    pr: 7
    sha: 1234abc
YAML
WANT='- **api-1** `feat: one` — [#7](https://github.com/acme/acme-api/pull/7) merged, squash [`1234abc`](https://github.com/acme/acme-api/commit/1234abc)'

plan done/shipped.md "$TMP/one.yaml"
run "$WS/plans/done/shipped.md"
assert_out "a plan in plans/done/ resolves the same workspace root" "$WANT" "$OUT"

# A plan outside any plans/ directory finds nothing on its own, and $ONTHERUN_WORKSPACE names
# the root for it.
mkdir -p "$TMP/elsewhere"
plan "$TMP/elsewhere/p.md" "$TMP/one.yaml"
run "$TMP/elsewhere/p.md"
assert_has "a plan outside the workspace renders unlinked" "— #7 merged, squash \`1234abc\`" "$OUT"
OUT=$(ONTHERUN_WORKSPACE="$WS" "$LEDGER" "$TMP/elsewhere/p.md" 2>/dev/null)
assert_out "  and \$ONTHERUN_WORKSPACE names the root for it" "$WANT" "$OUT"

# A worktree of the workspace repo holds plans/ and none of the nested checkouts; the root
# is the workspace repo's main working tree.
mkdir -p "$WS/plans/live"
plan live/wt.md "$TMP/one.yaml"
g -C "$WS" add plans && g -C "$WS" commit -q -m plans
g -C "$WS" worktree add -q "$TMP/wt" -b wt
run "$TMP/wt/plans/live/wt.md"
assert_out "a plan read from a worktree of the workspace repo still finds the checkouts" "$WANT" "$OUT"

# The single-repo layout: the root is the code checkout, plans/ is a git repo of its own
# that the checkout excludes, and `repo: .` is the root.
SOLO="$TMP/solo"
mkdir -p "$SOLO/plans"
g init -q "$SOLO" && g -C "$SOLO" remote add origin https://github.com/solo/app.git
echo 'plans/' >> "$SOLO/.git/info/exclude"
g init -q "$SOLO/plans"
cat > "$TMP/solo.yaml" <<'YAML'
repos: [.]
nodes:
  - id: app-1
    repo: .
    title: "feat: in the only repo"
    needs: []
    agent: implementer
    status: open
    pr: 2
YAML
plan "$SOLO/plans/solo.md" "$TMP/solo.yaml"
g -C "$SOLO/plans" add solo.md && g -C "$SOLO/plans" commit -q -m plan
run "$SOLO/plans/solo.md"
assert_out "single repo: \`repo: .\` links to the root's own origin" \
  '- **app-1** `feat: in the only repo` — [#2](https://github.com/solo/app/pull/2) open, awaiting review' "$OUT"
assert_eq "  with nothing on stderr" "" "$ERR"

# ------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
