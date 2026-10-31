#!/usr/bin/env bash
# Fixtures quote code in backticks inside single quotes, on purpose.
# shellcheck disable=SC2016
# Tests for ontherun-plan-cite-check.sh. No framework: throwaway checkouts nested in a fake
# workspace repo, a plan written per case, assertions on stdout and exit status.
#
#   ontherun-plan-cite-check.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs git and awk.
#
# **Every checkout sits on a branch that disagrees with its default branch**, and one
# origin takes a commit after its clone was made. That is the state real checkouts are
# in while a plan runs, so the sweep has to read origin/<default> after a fetch and
# nothing else -- a working-tree read passes every case here that a branch-only file
# should fail, and misses the one a later push should pass. One case reads a plan from a
# worktree of the workspace repo, which carries none of the nested checkouts; the
# single-repo cases put `plans/` in a git repo of its own inside a code checkout whose
# default branch is not called main.
#
# git runs with per-command overrides only -- never `git config` into a checkout -- and
# with signing off, because a machine whose global config signs commits has no key for a
# throwaway one.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CHECK="$SCRIPT_DIR/ontherun-plan-cite-check.sh"

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

# ------------------------------------------------------------------ the fixtures

g() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

WS="$TMP/ws"; ORIGINS="$TMP/origins"
mkdir -p "$WS/plans/done" "$WS/.claude/agents" "$ORIGINS"
WS_REAL=$(cd "$WS" && pwd -P)       # git reports paths with symlinks resolved (/private/var on macOS)
echo '# workspace' > "$WS/CLAUDE.md"
echo '# plans' > "$WS/plans/README.md"
# A shipped plan's state block is where a node id's prefix gets its repo.
cat > "$WS/plans/done/shipped.md" <<'EOF'
```yaml
repos: [acme-api, acme-web, acme-site, acme-ios]
nodes:
  - id: api-1
    repo: acme-api
  - id: web-1
    repo: acme-web
  - id: site-1
    repo: acme-site
  - id: ios-1
    repo: acme-ios
```
EOF
echo 'reviewer' > "$WS/.claude/agents/plan-reviewer.md"
g init -q "$WS" && g -C "$WS" add -A && g -C "$WS" commit -q -m workspace

mkrepo() { # name -> a bare origin and, inside the fake workspace, a clone of it
  g init -q --bare "$ORIGINS/$1.git"
  g clone -q "$ORIGINS/$1.git" "$WS/$1" 2>/dev/null
}
commit() { # repo message -> the short sha
  g -C "$WS/$1" add -A && g -C "$WS/$1" commit -q -m "$2" && g -C "$WS/$1" rev-parse --short HEAD
}
filler() { # n prefix -> n numbered lines
  local i; for ((i = 1; i <= $1; i++)); do printf '%s %d\n' "$2" "$i"; done
}

# acme-api: two commits on main, so an ` @ sha` can name a tree where a symbol sat
# elsewhere; a working tree on a branch that deletes one cited file and adds another;
# and a commit pushed to the origin from a second clone after this one was made.
mkrepo acme-api
A="$WS/acme-api"
mkdir -p "$A/src/app/services" "$A/src/app/core/worker" "$A/src/app/api/v1"
{ filler 11 '# nudge'; echo 'def restorePasskeyNudge(user):'; filler 5 '    # body'; } > "$A/src/app/services/nudge.py"
{ filler 4 '# core'; echo 'POSTGRES_SERVER: str = "db"'; filler 14 '# core'
  echo 'def redis_url(self) -> str:'; filler 10 '    # body'; } > "$A/src/app/core/config.py"
{ filler 2 '# v1'; echo 'router = APIRouter()'; filler 7 '# v1'; } > "$A/src/app/api/v1/config.py"
{ filler 29 'decision line'
  echo '**The suite has its own database**, and builds it with the migrations.'
  filler 9 'decision line'
  echo 'Nothing durable lives'
  echo 'here: every Redis use is ephemeral.'
  filler 19 'decision line'; } > "$A/DECISIONS.md"
cat > "$A/src/app/services/blob_store.py" <<'EOF'
"""The files volume.

Callers hand over an opaque key and never see a Path - which is what
makes the S3 backend a rewrite of this file rather than a change to
every call site.
"""
def put(key, data):
    pass
EOF
cat > "$A/src/app/core/worker/functions.py" <<'EOF'
import os
import sys
# cleanup
# see below
# a privacy
# hole inside an erasure feature
def purge_deleted_accounts():
    pass
EOF
filler 5 '# claude' > "$A/CLAUDE.md"
OLD=$(commit acme-api old)
{ filler 28 '# moved'; cat "$A/src/app/services/nudge.py"; } > "$A/nudge.tmp"
mv "$A/nudge.tmp" "$A/src/app/services/nudge.py"
{ filler 2 '# files'; echo 'from .blob_store import new_key'; } > "$A/src/app/services/dive_files.py"
MAIN=$(commit acme-api main)
g -C "$A" push -q -u origin main
g -C "$A" checkout -q -b feature
g -C "$A" rm -q src/app/core/config.py
echo 'x = 1' > "$A/src/app/only_in_worktree.py"
commit acme-api "branch only" >/dev/null
g clone -q "$ORIGINS/acme-api.git" "$TMP/api2"
echo 'def landed_after_clone(): pass' > "$TMP/api2/src/app/pushed_later.py"
g -C "$TMP/api2" add -A && g -C "$TMP/api2" commit -q -m later && g -C "$TMP/api2" push -q origin main

# acme-web: a wrong-path fixture (`src/lib/api/config.ts` exists, `src/lib/config.ts`
# does not), a 690-line page whose quoted sentence wraps, and the `.render.test.tsx`
# shorthand's two files. Its branch rewrites the quoted line.
mkrepo acme-web
W="$WS/acme-web"
mkdir -p "$W/src/lib/api" "$W/src/app/privacy" "$W/src/components/picker" "$W/src/app/species/[id]"
{ filler 189 '// species'; echo '        credit line beside the AphiaID row'; filler 10 '// species'; } > "$W/src/app/species/[id]/page.tsx"
{ echo '// config'; echo 'export const projectOperated = true;'; filler 3 '// config'; } > "$W/src/lib/api/config.ts"
{ filler 681 '// privacy'; echo '      whether traffic to this copy is encrypted in transit'
  echo "      is the operator's call."; filler 7 '// privacy'; } > "$W/src/app/privacy/page.tsx"
{ filler 11 '// test'; echo '  "Taxonomy: WoRMS",'; filler 3 '// test'; } > "$W/src/components/picker/multi-select.test.ts"
{ filler 49 '// render'; echo '  credit link'; filler 10 '// render'; } > "$W/src/components/picker/multi-select.render.test.tsx"
filler 3 '# claude' > "$W/CLAUDE.md"
g -C "$W" add -A && g -C "$W" commit -q -m main && g -C "$W" push -q -u origin main
g -C "$W" checkout -q -b wip
{ filler 681 '// privacy'; echo '      rewritten on the branch'; filler 8 '// privacy'; } > "$W/src/app/privacy/page.tsx"
g -C "$W" add -A && g -C "$W" commit -q -m wip

# acme-site: a compose comment wrapped under `#` markers, a doc whose quoted sentence
# wraps onto a line opening with a path, a short DECISIONS.md (so a line number rules it
# out), and two README.md files.
mkrepo acme-site
F="$WS/acme-site"
mkdir -p "$F/docs/foo"
{ filler 264 '# compose'; echo '    # Nothing durable lives'; echo '    # here: a restart loses nothing.'
  filler 4 '# compose'; } > "$F/docker-compose.yml"
filler 20 'site decision' > "$F/DECISIONS.md"
{ filler 18 'proxy'; echo '**2. Point your proxy at `web:3000`.** One upstream, no path splitting: the web container carries'
  echo '`/api/v1` through to the API itself, so it is a complete front end.'; filler 5 'proxy'; } > "$F/docs/reverse-proxy.md"
{ filler 105 'install'; echo 'every dive is in here'; filler 14 'install'; } > "$F/docs/install.md"
filler 40 'readme' > "$F/README.md"
filler 40 'readme' > "$F/docs/foo/README.md"
g -C "$F" add -A && g -C "$F" commit -q -m main && g -C "$F" push -q -u origin main
g -C "$F" checkout -q -b tidy

# acme-pool: a root README.md, which acme-site has too, so only the repo the prose names
# can tell the two apart.
mkrepo acme-pool
P="$WS/acme-pool"
{ filler 2 'pool'; echo 'An open pool of dive sites.'; echo 'pool'; echo 'Each site is one file per site.'
  filler 5 'pool'; } > "$P/README.md"
g -C "$P" add -A && g -C "$P" commit -q -m main && g -C "$P" push -q -u origin main

# acme-ios: a third root README.md beside acme-site's and the pool's.
mkrepo acme-ios
I="$WS/acme-ios"
{ echo '# Acme for iOS'; filler 10 'ios'; echo 'A SwiftUI client for an Acme server.'
  filler 5 'ios'; } > "$I/README.md"
IOS=$(commit acme-ios main); g -C "$I" push -q -u origin main

# ops/infra: a checkout two levels down, under a plain grouping directory.
mkdir -p "$ORIGINS/ops"
mkrepo ops/infra
N="$WS/ops/infra"
{ filler 2 'infra'; echo 'The blueprint pins region: frankfurt.'; filler 16 'infra'; echo 'The worker runs hourly.'
  filler 10 'infra'; } > "$N/README.md"
commit ops/infra main >/dev/null; g -C "$N" push -q -u origin main

PLANS="$WS/plans"
plan() { # name -> writes $PLANS/name.md from stdin, OLDSHA/MAINSHA substituted
  sed -e "s/OLDSHA/$OLD/g" -e "s/MAINSHA/$MAIN/g" > "$PLANS/$1.md"
}
run() { OUT=$(cd "$PLANS" && "$CHECK" "$@" 2>&1); RC=$?; }

echo "ontherun-plan-cite-check.sh"

# -------------------------------------------------------------- a clean plan
#
# Every shape and every resolution rule at once, and the whole output is one line: a
# symbol at its line, a sha that resolves, quotes wrapped in the plan and in the file
# (under `#` markers, in bold, and onto a line that opens with a path), a repo
# established by its name with a possessive, by a node id, and by the paragraph before; a bare path settled by the line count, by a symbol near the
# line (two symbols in one file are one vote, not a tie), by the stem of the citation
# before it, and by being at the repo root; a symbol under "no" and one beside a file
# named without a line, both left alone; a table row; a timestamp and two host:port
# spans that are not citations and are not counted.

plan A <<'EOF'
# Plan A (`acme-api` + `acme-web`)

`restorePasskeyNudge()` lives at `acme-api/src/app/services/nudge.py:40`, and
`redis_url()` at `acme-api/src/app/core/config.py:20 @ MAINSHA`. The compose
comment (`acme-site/docker-compose.yml:265-266`: "Nothing durable lives
here: a restart loses nothing") wraps in the file; so does the privacy page's
"whether traffic to this copy is encrypted in transit is the operator's call"
(`acme-web/src/app/privacy/page.tsx:682-690`), and the proxy doc's
"Point your proxy at `web:3000`. One upstream, no path splitting: the web container
carries `/api/v1` through to the API itself" (`acme-site/docs/reverse-proxy.md:19-20`)
wraps onto a slash. The acme-api's `DECISIONS.md:30`
says "The suite has its own database, and builds it with the migrations". The
comment at `core/worker/functions.py:5-6` calls that "a privacy hole inside an
erasure feature". `POSTGRES_SERVER` sits at `config.py:5`. `router` and `APIRouter`
are at `config.py:3,7`. Arq's settings carry no `ssl` (`config.py:20`). `docs/install.md`
adds "the second half" in the S3 variant, while `acme-site/docs/install.md:106`
says "every dive is in here".

| service | where |
| `worker` | pure cron (`acme-api/src/app/core/worker/functions.py:7`, `purge_deleted_accounts`) |

- **web-4.** The picker's pinned strings (`multi-select.test.ts:12`, `.render.test.tsx:50`) move.
- Also `README.md:37` in acme-site, e.g. its root one. Neither `2026-04-17T11:49:23.510+02:00`
  nor `127.0.0.1:8025:8025` nor `localhost:8025` is a citation.
EOF
run A.md
assert_out "a clean plan: one OK line, every shape resolved" \
  "OK 15 of 15 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"
assert_eq "  and exits 0" 0 "$RC"

# ------------------------------------------------------------------- MISS

plan B <<'EOF'
# Plan B

The flag's only consumer is `src/lib/config.ts:24` in `acme-web`, and
`acme-web/src/lib/api/config.ts:2` says "the flag is read once at boot".
`acme-api/src/app/services/nudge.py:40` defines `restorePasskeyNudge` and `frobnicate`.
EOF
run B.md
assert_out "a wrong path, a quote not in the file, a symbol not in the file" \
"MISS B.md:3  \`src/lib/config.ts:24\`: no file named src/lib/config.ts at origin/main of acme-web
MISS B.md:4  \`acme-web/src/lib/api/config.ts:2\`: \"the flag is read once at boot\" not in acme-web/src/lib/api/config.ts
MISS B.md:5  \`acme-api/src/app/services/nudge.py:40\`: \`frobnicate\` not in acme-api/src/app/services/nudge.py
OK 0 of 3 citations; DRIFT 0, MISS 3, SKIP 0" "$OUT"
assert_eq "  and exits 1" 1 "$RC"

# ------------------------------------------------------------- DRIFT and sha

plan C <<'EOF'
# Plan C

`restorePasskeyNudge()` sits at `acme-api/src/app/services/nudge.py:12 @ OLDSHA`,
where `frobnicate` never was. `landed_after_clone` at `acme-api/src/app/pushed_later.py:1`.
`acme-api/src/app/core/config.py:5-40` runs past the end, and `acme-api/DECISIONS.md:3 @ deadbeef0` cites nothing.
EOF
run C.md
assert_has "a symbol that moved since the cited sha: DRIFT, and the sha says so" \
  "DRIFT C.md:3  \`acme-api/src/app/services/nudge.py:12 @ $OLD\`: \`restorePasskeyNudge\` nearest at :40, 28 lines from :12 (0 lines off at $OLD: the tree moved since)" "$OUT"
assert_has "a symbol absent at the sha too: MISS, wrong when cited" \
  "MISS C.md:3  \`acme-api/src/app/services/nudge.py:12 @ $OLD\`: \`frobnicate\` not in acme-api/src/app/services/nudge.py (absent at $OLD too: wrong when cited)" "$OUT"
assert_lacks "a file pushed to the origin after the clone is seen: the sweep fetches" \
  "pushed_later" "$OUT"
assert_has "a range past the end of the file is DRIFT" \
  "DRIFT C.md:5  \`acme-api/src/app/core/config.py:5-40\`: range runs past the end of the file (30 lines)" "$OUT"
assert_has "an unknown sha is MISS" \
  "MISS C.md:5  \`acme-api/DECISIONS.md:3 @ deadbeef0\`: unknown sha deadbeef0 in acme-api" "$OUT"
assert_has "  and the tally" "OK 1 of 4 citations; DRIFT 2, MISS 2, SKIP 0" "$OUT"
assert_eq "  exit 1 on the MISSes" 1 "$RC"

plan D <<'EOF'
# Plan D

`restorePasskeyNudge()` sits at `acme-api/src/app/services/nudge.py:12`.
EOF
run D.md
assert_has "DRIFT alone is reported" "28 lines from :12" "$OUT"
assert_eq "  but exits 0: ranges are hints" 0 "$RC"
run --strict D.md
assert_eq "--strict makes DRIFT fail" 1 "$RC"
run --drift 40 D.md
assert_out "--drift N widens the tolerance" "OK 1 of 1 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"
run --drift=40 D.md
assert_out "  in either spelling" "OK 1 of 1 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"

# ------------------------------------------- origin/main, not the working tree

plan E <<'EOF'
# Plan E

`acme-api/src/app/only_in_worktree.py:1` is only on the branch, while
`acme-api/src/app/core/config.py:5` is only at origin/main; and web's
`acme-web/src/app/privacy/page.tsx:682` says "whether traffic to this copy is encrypted in transit".
EOF
run E.md
assert_out "a file the branch added is MISS; files the branch deleted or rewrote are read at origin/main" \
"MISS E.md:3  \`acme-api/src/app/only_in_worktree.py:1\`: no such file at origin/main of acme-api
OK 2 of 3 citations; DRIFT 0, MISS 1, SKIP 0" "$OUT"

# ------------------------------------------------------- SKIP and no checkout

plan F <<'EOF'
# Plan F

`config.py:3` is ambiguous with nothing to break the tie; `plans/done/shipped.md:1` and
`.claude/agents/plan-reviewer.md:1` are the workspace's; `tools/spec/README.md:1` has no checkout.

```yaml
repos: [acme-api, tools/spec]
```
EOF
run F.md
assert_has "two files fit and nothing tells them apart: SKIP, both named" \
  "SKIP F.md:3  \`config.py:3\`: ambiguous: acme-api:src/app/api/v1/config.py acme-api:src/app/core/config.py" "$OUT"
assert_has "a plans/ file is the plans repo's: SKIP" \
  "SKIP F.md:3  \`plans/done/shipped.md:1\`: a plans-repo file: not swept" "$OUT"
assert_has "  so is a .claude/ one, its leading dot notwithstanding" \
  "SKIP F.md:4  \`.claude/agents/plan-reviewer.md:1\`: a plans-repo file: not swept" "$OUT"
assert_has "a repo with no checkout is an ERROR on stderr" "ERROR no checkout for tools/spec at $WS_REAL/tools/spec" "$OUT"
assert_has "  and its citation a SKIP" "SKIP F.md:4  \`tools/spec/README.md:1\`: no checkout for tools/spec" "$OUT"
assert_has "  the tally counts them" "OK 0 of 4 citations; DRIFT 0, MISS 0, SKIP 4" "$OUT"
assert_eq "  and the missing checkout exits 2" 2 "$RC"

# ------------------------------------------------------------------ pairing

plan G <<'EOF'
# Plan G

"Nothing durable lives here" (`acme-api/DECISIONS.md:40-41`), "every call site" (`acme-api/src/app/services/blob_store.py:3-5`); `new_key` (`acme-api/src/app/services/nudge.py:1`, `dive_files.py:3`) is imported.
EOF
run G.md
assert_out "quotes pair with the citation after each; a symbol found in a neighbouring cited file is not stale" \
  "OK 4 of 4 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"

plan H <<'EOF'
# Plan H

```bash
git grep -n frobnicate -- `acme-api/nope.py:1`
```

`acme-api/src/app/services/nudge.py:40` defines `restorePasskeyNudge`.
EOF
run H.md
assert_out "fenced code is not swept" "OK 1 of 1 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"

# ------------------------------------------------------ the other citation shapes
#
# A route with `[id]` in it, a sha with no line (the file and what is named
# beside it are checked; nothing can drift), and a span shaped like a citation that
# nothing parses, which must be SKIPped and counted rather than vanish from the tally.

plan I <<'EOF'
# Plan I

The credit sits at `acme-web/src/app/species/[id]/page.tsx:186-192` ("credit line beside the AphiaID row"); `acme-api/src/app/core/config.py @ MAINSHA` holds `redis_url`; `acme-api/src/app/nope.py @ MAINSHA` does not exist; `(detail)/[id]/page.tsx:1` is a wrong bracket path; and `src/app/{kind}/store.py:12` is a shape this sweep does not parse.
EOF
run I.md
assert_out "a bracketed route resolves; a sha-only citation checks the file; the rest are visible" \
"MISS I.md:3  \`acme-api/src/app/nope.py @ $MAIN\`: no such file at origin/main of acme-api (nor at $MAIN: wrong when cited)
MISS I.md:3  \`(detail)/[id]/page.tsx:1\`: no file named (detail)/[id]/page.tsx at origin/main of acme-api
SKIP I.md:3  \`src/app/{kind}/store.py:12\`: a citation shape this sweep does not parse
OK 2 of 5 citations; DRIFT 0, MISS 2, SKIP 1" "$OUT"
assert_eq "  and exits 1" 1 "$RC"

# ------------------------------------------------------------------ the pool
#
# Its slug and its node ids name it -- the ids through this plan's own state block, since
# no shipped plan has a `pool-` node. Named before the slug, acme-site would be the last
# repo the prose named, and its README does not hold the quote.

plan J <<'EOF'
# Plan J

**pool-1.** `README.md:3` says "An open pool of dive sites".

The `acme-site` front page links the pool, `acme/acme-pool`, whose `README.md:5` says "one file per site".

```yaml
nodes:
  - id: pool-1
    repo: acme-pool
```
EOF
run J.md
assert_out "a node id and the slug both resolve to acme-pool" \
  "OK 2 of 2 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"

# ----------------------------------------------------------------- the iOS app
#
# Its path, its node ids and its shas name it. Without them a bare citation resolves
# against acme-site's citation before it.

plan K <<EOF
# Plan K

\`acme-ios/README.md:1 @ $IOS\` opens "Acme for iOS".

\`acme-site/README.md:3\` stays, and \`README.md:12 @ $IOS\` is the app's.

\`acme-site/README.md:3\` stays. **ios-2.** \`README.md:12\` says "A SwiftUI client for an Acme server".
EOF
run K.md
assert_out "a node id and a sha both resolve to acme-ios" \
  "OK 5 of 5 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"

# ------------------------------------------- a checkout no list has heard of
#
# Any checkout nested under the workspace can host a node, two levels down included, and
# is found by being there: its path, its slug and a node id the plan maps to it name it.
# Its README.md is long enough that acme-site's, named just before, is a candidate too.
# `ios-3` resolves through the shipped plan's block, `infra-1` through this plan's own.

plan L <<'EOF'
# Plan L

`ops/infra/README.md:2-3` says "region: frankfurt".

`acme-site/README.md:2` stays, and `acme/infra` keeps the blueprint, whose `README.md:3` says "region: frankfurt".

`acme-site/README.md:2` stays. **infra-1.** `README.md:20` says "The worker runs hourly".

`acme-site/README.md:2` stays. **ios-3.** `README.md:12` says "A SwiftUI client for an Acme server".

```yaml
nodes:
  - id: infra-1
    repo: ops/infra
```
EOF
run L.md
assert_out "a nested checkout resolves by path, by slug and by node id" \
  "OK 7 of 7 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"

# ------------------------------------------------------------ the single repo
#
# The root is the code checkout and `plans/` a git repo of its own that it excludes. The
# origin's default branch is `trunk`, the checkout sits on a branch of its own, and the
# plan's block names the root as `repo: .`. Bare citations resolve to the root; a plans/
# file is the plans repo's and is not swept.

g init -q --bare -b trunk "$ORIGINS/solo.git"
g clone -q "$ORIGINS/solo.git" "$TMP/solo" 2>/dev/null
S="$TMP/solo"
mkdir -p "$S/src"
{ filler 2 '# app'; echo 'def handler(event):'; filler 4 '    # body'; } > "$S/src/app.py"
g -C "$S" add -A && g -C "$S" commit -q -m trunk && g -C "$S" push -q -u origin HEAD:trunk
g -C "$S" checkout -q -b mine
echo 'y = 2' > "$S/src/branch_only.py"
g -C "$S" add -A && g -C "$S" commit -q -m mine
echo 'plans/' >> "$S/.git/info/exclude"
mkdir -p "$S/plans"
g init -q "$S/plans"
cat > "$S/plans/solo.md" <<'EOF'
# Solo

**app-1.** `handler` sits at `src/app.py:3`, and `app.py:3` again by its suffix. `src/branch_only.py:1`
is only on a branch, and `plans/solo.md:1` is this plan.

```yaml
repos: [.]
nodes:
  - id: app-1
    repo: .
```
EOF
g -C "$S/plans" add solo.md && g -C "$S/plans" commit -q -m plan
OUT=$(cd "$S" && "$CHECK" plans/solo.md 2>&1); RC=$?
assert_out "single repo: bare citations resolve to the root at its default branch, not main" \
"MISS plans/solo.md:3  \`src/branch_only.py:1\`: no file named src/branch_only.py at origin/trunk of .
SKIP plans/solo.md:4  \`plans/solo.md:1\`: a plans-repo file: not swept
OK 2 of 4 citations; DRIFT 0, MISS 1, SKIP 1" "$OUT"
assert_eq "  and exits 1" 1 "$RC"

# A plans repo is never a node repo, even where nothing else names one.
cat > "$S/plans/only.md" <<'EOF'
# Only

`README.md:1` is nowhere.
EOF
OUT=$(cd "$S" && "$CHECK" plans/only.md 2>&1); RC=$?
assert_has "  and the nested plans repo is not swept as a node repo" \
  "no file named README.md at the default branch of any repo" "$OUT"

# ------------------------------------------------------------ the arguments

run
assert_eq "no arguments: usage, exit 64" 64 "$RC"
run --drift x A.md
assert_eq "a non-numeric --drift: usage, exit 64" 64 "$RC"
run nope.md
assert_eq "an unreadable plan exits 2" 2 "$RC"

# The checkouts sit in the workspace repo's MAIN working tree. A plan read from a
# worktree of it -- where plan work often runs -- sits beside no checkouts at all.
g -C "$WS" add plans/G.md && g -C "$WS" commit -q -m "plan G"
g -C "$WS" worktree add -q "$TMP/wt" -b wt
OUT=$(cd "$TMP/wt/plans" && "$CHECK" G.md 2>&1); RC=$?
assert_out "a plan read from a worktree of the workspace repo still finds the checkouts" \
  "OK 4 of 4 citations; DRIFT 0, MISS 0, SKIP 0" "$OUT"
OUT=$(cd "$PLANS" && ONTHERUN_WORKSPACE="$TMP/nowhere" "$CHECK" G.md 2>&1); RC=$?
assert_eq "\$ONTHERUN_WORKSPACE overrides the plan's own root: a root that is not there exits 2" 2 "$RC"

# ------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
