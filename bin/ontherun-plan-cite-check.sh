#!/usr/bin/env bash
# Sweep one plan's file-and-line citations against its node repos' default branches.
#
#   ontherun-plan-cite-check.sh [--drift N] [--strict] <plan.md>
#
# Three citation shapes, all inside backticks, the way plans write them:
#
#   `acme-api/src/app/core/config.py:245 @ 0bc08c7`
#       repo/path with :LINE, :START-END or :12,40-45, and optionally ` @ <sha>` naming
#       the tree the citation was read from; or with the sha alone and no line, which
#       checks the file and what is named beside it but can measure no drift. The repo
#       is any git checkout nested under the workspace root, or one the plan's state
#       block names. A path may carry the `[id]` and `(group)` segments of a route.
#   `config.py:137-144`
#       a bare path, resolved to one file at the default branch by suffix. Its repo is
#       the sha's when it carries one, else the last repo the paragraph named before it
#       (a prefixed citation, a repo's path, an `owner/name` slug ending in a repo's
#       directory name, a node id whose prefix a state block in the plans directory maps
#       to a repo), else the first named after it, else whichever repo has the suffix --
#       in the single-repo layout, the root itself. Among several files: one shorter
#       than the cited line is not it; one cited in full earlier with the same line
#       wins; then the one where the sentence's own symbols sit near the cited line;
#       then the file most recently cited in full; then the repo-root one. What is still
#       ambiguous is SKIPped with the candidates listed. Only a path carrying a `.` or a
#       `/` counts, which keeps `localhost:8025` and `10:04` out; a path found only in
#       the plans repo (`plans/`, a workspace repo's `CLAUDE.md` or `.claude/`) is
#       SKIPped, not swept. `.render.test.tsx:50` right after `picker.test.ts:12`
#       borrows that citation's stem.
#   `README.md:117-118 @ 96406fe` says "the application repositories open at …"
#       a double-quoted sentence of two or more words near either.
#
# The file must exist at the repo's default branch (origin/HEAD, else origin/main, else
# origin/master), fetched first: checkouts routinely sit on unmerged branches, so the
# working tree is never read. Every backticked symbol and quoted sentence in the same
# sentence as a citation is then paired with the NEAREST citation or file mention, by
# prose distance, and checked only when that gap is short (60 characters) and the
# neighbour is a citation -- plans write `restoreNudge()` (`cite`), (`cite`: "quote")
# and `cite` says "quote", and a name three clauses away, or beside a file named without
# a line, belongs to something else. Sentences end at ". ", "; ", a table's "|" and the
# like, never inside a span. The needle is looked for in the paired file; failing that,
# in the sentence's other cited files, since `"quote" (cite), "quote" (cite)` pairs by a
# margin of one character. Matching joins wrapped lines and ignores `*`, because a
# sentence quoted from a decision record or a docstring rarely sits on one line and is
# often bold there. One line per problem:
#
#   MISS   the file is gone, the sha is unknown, or the symbol/quote is in none of the
#          sentence's cited files                                             -> exit 1
#   DRIFT  its nearest occurrence is more than N lines from the cited line (--drift N,
#          default 12), or the range runs past the end of the file
#                                        -> a warning; a failure only under --strict
#   SKIP   a bare citation nothing resolves, a plans-repo file, or a span shaped like
#          a citation that none of the above parses -> reported, counted neither way
#
# A repo the plan's state block names with no checkout under the workspace root, or one
# with no default branch to read, is an ERROR on stderr, its citations SKIP, and the run
# exits 2 whatever else it found: nothing it reports can be vouched for. 64 on usage.
#
# With ` @ <sha>` a MISS or DRIFT is measured at that sha too, and the line says whether
# the tree moved since or the citation was wrong when written. Informational.
#
# DRIFT is a warning because reference/plan-format.md (*How a plan cites the
# tree*) says ranges are hints and the named construct is the fact. A symbol preceded by
# "no", "not", "never", "without", "gains" or "adds" is an assertion of absence, or of a
# future, and is not looked for; repo names and file names are not symbols. What none of
# this can check is a sentence that cites no file -- that stays the reviewer's.
#
# The workspace root is $ONTHERUN_WORKSPACE, else the parent of the nearest ancestor directory
# named `plans`, else the plan's git toplevel; a linked worktree of a workspace repo
# resolves to its main working tree, where the nested checkouts are
# (reference/workspace.md). Node repos are the git checkouts under it --
# not the plans repo -- plus the root itself when it is a code checkout with `plans/`
# nested inside it (`repo: .`).
#
# Needs bash, git and awk. ontherun-plan-cite-check.test.sh beside this file runs it against
# throwaway repos in both layouts.

set -u

usage() {
  printf 'usage: %s [--drift N] [--strict] <plan.md>\n' "${0##*/}" >&2
  exit 64
}

drift_max=12
strict=false
while [ $# -gt 0 ]; do
  case $1 in
    --drift)   [ $# -ge 2 ] || usage; drift_max=$2; shift 2 ;;
    --drift=*) drift_max=${1#--drift=}; shift ;;
    --strict)  strict=true; shift ;;
    --)        shift; break ;;
    -*)        usage ;;
    *)         break ;;
  esac
done
[ $# -eq 1 ] || usage
case $drift_max in ''|*[!0-9]*) usage ;; esac
plan=$1
[ -r "$plan" ] || { printf 'cannot read %s\n' "$plan" >&2; exit 2; }

wf_here() { # this script's directory, symlinks resolved
  local s=${BASH_SOURCE[0]} d
  while [ -L "$s" ]; do
    d=$(cd -P -- "$(dirname -- "$s")" && pwd)
    s=$(readlink -- "$s"); case $s in /*) ;; *) s=$d/$s ;; esac
  done
  cd -P -- "$(dirname -- "$s")" && pwd
}
# shellcheck source=SCRIPTDIR/ontherun-lib.sh
. "$(wf_here)/ontherun-lib.sh" || exit 2

root=$(wf_root "$plan") || { printf 'cannot resolve the workspace root for %s\n' "$plan" >&2; exit 2; }
plans_dir=$(wf_plans_dir "$plan") || exit 2
# The plans repo: the root itself in a workspace repo, `plans/` in the single-repo layout.
# Its files are the workspace's own and are not swept; it is never a node repo.
# Resolved to its main working tree, so a plan read from a worktree of the workspace repo
# still names the root as the plans repo.
prepo=$(wf_main_tree "$(dirname -- "$plan")") || prepo=""
prel=""
case ${prepo:-} in "$root"/*) prel=${prepo#"$root"/} ;; esac

# Any checkout nested under the root can host a node, so the repos are found rather than
# listed: every directory holding a `.git`, not descending into one -- and the root
# itself when it is a code checkout of its own rather than the plans repo.
discover_repos() {
  (cd "$root" && find . -mindepth 1 \( -name .git -o -name .claude -o -name node_modules \) -prune \
    -o -type d -exec test -e '{}/.git' \; -print -prune) | sed 's|^\./||' \
    | { if [ -n "$prel" ]; then grep -vxF -- "$prel"; else cat; fi; } | LC_ALL=C sort
  [ -e "$root/.git" ] && [ "${prepo:-}" != "$root" ] && printf '.\n'
}

block_nodes() { # plan... -> "id repo" per node of each state block; "- repo" per `repos:` entry
  awk '
    /^```yaml/ { y = 1; next }
    /^```/     { y = 0; next }
    !y         { next }
    /^repos:/  { s = $0; sub(/^repos:[ \t]*\[/, "", s); sub(/\].*/, "", s)
                 n = split(s, a, /[ ,]+/); for (k = 1; k <= n; k++) if (a[k] != "") print "-", a[k] }
    /^[ \t]*- id:/ { id = $NF }
    /^[ \t]+repo:/ && id != "" { print id, $NF; id = "" }
  ' "$@" 2>/dev/null
}

own_nodes=$(block_nodes "$plan")
REPOS=$( { discover_repos; printf '%s\n' "$own_nodes" | awk 'NF { print $2 }'; } | awk 'NF && !s[$0]++' | tr '\n' ' ')
# A node id's prefix names a repo; this plan's block wins, then every other plan's.
PREFIXES=$( { printf '%s\n' "$own_nodes"; block_nodes "$plans_dir"/*.md "$plans_dir"/done/*.md; } \
  | awk '$1 != "-" && NF == 2 { p = $1; sub(/-[0-9]+$/, "", p); if (!(p in m)) { m[p] = 1; print p, $2 } }')
pair_max=60

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------- the trees

# Which repos were fetched or found missing is kept as marker files, not variables:
# most lookups run inside `$(...)`, and a variable set there never reaches the next one,
# so every bare citation would fetch every checkout again.
mkdir -p "$TMP/.fetched" "$TMP/.unavailable"
rdir() { [ "$1" = . ] && printf '%s' "$root" || printf '%s' "$root/$1"; }
mark() { [ "$1" = . ] && printf '%%root' || printf '%s' "${1//\//%}"; }  # `.` would name the directory itself
have_repo() { [ -e "$(rdir "$1")/.git" ]; }
ensure_repo() { # repo -> 0 once its checkout has been fetched; 1 if there is no checkout
  local dir mark ref
  mark=$(mark "$1")
  dir=$(rdir "$1")
  [ -e "$TMP/.fetched/$mark" ] && return 0
  [ -e "$TMP/.unavailable/$mark" ] && return 1
  if ! have_repo "$1"; then
    printf 'ERROR no checkout for %s at %s\n' "$1" "$dir" >&2
    : > "$TMP/.unavailable/$mark"
    return 1
  fi
  ref=$(wf_default_ref "$dir") || { git -C "$dir" fetch -q origin 2>/dev/null; ref=$(wf_default_ref "$dir"); } || {
    printf 'ERROR no default branch for %s: neither origin/HEAD, origin/main nor origin/master\n' "$1" >&2
    : > "$TMP/.unavailable/$mark"
    return 1
  }
  git -C "$dir" fetch -q origin "${ref#origin/}" 2>/dev/null \
    || printf 'WARN fetch failed for %s; checking the %s it last fetched\n' "$1" "$ref" >&2
  printf '%s' "$ref" > "$TMP/.fetched/$mark"
}
ref_of() { cat "$TMP/.fetched/$(mark "$1")" 2>/dev/null || printf 'origin/main'; }  # after ensure_repo

file_at() { # repo ref path -> prints a cached copy's path; 1 if not a file at that ref
  local f="$TMP/$1/$2/$3"
  if [ ! -e "$f" ] && [ ! -e "$f.absent" ]; then
    mkdir -p "$(dirname -- "$f")"
    if [ "$(git -C "$(rdir "$1")" cat-file -t "$2:$3" 2>/dev/null)" = blob ]; then
      git -C "$(rdir "$1")" show "$2:$3" > "$f"
    else
      : > "$f.absent"
    fi
  fi
  [ -e "$f" ] && printf '%s' "$f"
}

line_count() { # cached file -> its line count, a missing final newline included
  awk 'END { print NR }' "$1"
}

suffix_in() { # list-file bare-path -> the listed paths ending in /it (or equal to it);
              # failing any, those merely ending in it, for a `.render.test.tsx`
  local p aligned="" loose=""
  while IFS= read -r p; do
    if [ "$p" = "$2" ] || [[ $p == */"$2" ]]; then aligned="$aligned$p"$'\n'
    elif [[ $p == *"$2" ]]; then loose="$loose$p"$'\n'; fi
  done < <(grep -F -e "$2" "$1")
  printf '%s' "${aligned:-$loose}"
}

tree_list() { # repo -> the file listing at its default branch, cached
  local ls="$TMP/$1/default.ls"
  [ -e "$ls" ] || { mkdir -p "$(dirname -- "$ls")"; git -C "$(rdir "$1")" ls-tree -r --name-only "$(ref_of "$1")" > "$ls"; }
  printf '%s' "$ls"
}

plans_list() { # -> the plans repo's tracked files as paths from the root, cached
  local ls="$TMP/plans-repo.ls"
  if [ ! -e "$ls" ]; then
    if [ -n "${prepo:-}" ]; then
      git -C "$prepo" ls-files 2>/dev/null | awk -v p="$prel" '{ print (p == "" ? "" : p "/") $0 }' > "$ls"
    else
      : > "$ls"
    fi
  fi
  printf '%s' "$ls"
}

repo_of_sha() { # sha -> the one repo among REPOS that has it; empty if none or several
  local r found=""
  for r in $REPOS; do
    have_repo "$r" || continue
    git -C "$(rdir "$r")" rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1 || continue
    [ -z "$found" ] || { found=""; break; }
    found=$r
  done
  printf '%s' "$found"
}

# Occurrences of a needle in a cached file, as the line each one starts on. Lines are
# joined with single spaces (a continuation line's comment marker dropped) so that a
# sentence wrapped in the source still matches; the needle's own whitespace is
# collapsed the same way, and both are stripped of the markup a plan quotes through --
# `**bold**`, `[a link](url)`, `<code>`, backticks -- so the rendered sentence still reads.
# Through ENVIRON, since -v would interpret backslashes.
occurrences() { # file needle
  NEEDLE=$2 awk '
    function norm(s) {
      gsub(/<[^>]*>/, "", s); gsub(/\]\([^)]*\)/, "", s); gsub(/[][*`]/, "", s)
      gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s
    }
    function cont(s) { sub(/^(#+|\/\/+|>+) ?/, "", s); return s }   # `//`, never one `/`: a path may open the line
    { L[NR] = norm($0) }
    END {
      n = norm(ENVIRON["NEEDLE"]); nl = length(n)
      if (nl == 0) exit
      for (i = 1; i <= NR; i++) {
        w = L[i]; j = i
        while (length(w) < length(L[i]) + nl && j < NR) { j++; w = w " " cont(L[j]) }
        p = index(w, n)
        if (p > 0 && p <= length(L[i])) print i
      }
    }' "$1"
}

nearest() { # file needle ranges -> "distance line" for the occurrence closest to the
            # cited ranges (0 when inside one); "-1 0" when there is none
  local best=-1 at=0 m d r a b
  while IFS= read -r m; do
    [ -n "$3" ] || { best=0; at=$m; break; }      # no line cited: present is enough
    for r in ${3//,/ }; do
      a=${r%-*}; b=${r#*-}
      if [ "$m" -lt "$a" ]; then d=$((a - m)); elif [ "$m" -gt "$b" ]; then d=$((m - b)); else d=0; fi
      if [ "$best" -lt 0 ] || [ "$d" -lt "$best" ]; then best=$d; at=$m; fi
    done
  done < <(occurrences "$1" "$2")
  printf '%s %s' "$best" "$at"
}

# --------------------------------------------------------------- the paragraph
#
# A paragraph is tokenised in order into CITE, FILE, SYM, QUOTE and REPO tokens, each
# stamped with the sentence it sits in and its character offset; the checks then run
# per sentence. A sentence ends at ". ", "! ", "? " or "; " in prose, closing brackets,
# stars and quotes allowed between, and at a table's "|" -- never inside a span. That
# splits on "e.g. " too, which costs only coverage, never a false report.

ere_alt() { # words, one per line -> one ERE alternation, each quoted
  awk 'NF' | sed 's/[].[^$*+?(){}|\\]/\\&/g' | paste -sd'|' -
}
named_repos=$(for r in $REPOS; do [ "$r" = . ] || printf '%s\n' "$r"; done)
repo_alt=$(printf '%s\n' "$named_repos" | ere_alt)
base_alt=$(printf '%s\n' "$named_repos" | sed 's|.*/||' | ere_alt)
prefix_alt=$(printf '%s\n' "$PREFIXES" | awk '{ print $1 }' | ere_alt)
cite_re='^(('"${repo_alt:-a^}"')/)?([][A-Za-z0-9_.(][][A-Za-z0-9_./()-]*)(:([0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*))?( @ ([0-9a-f]{7,40}))?$'
citeish_re='^[^[:space:]:]*[./][^[:space:]:]*:[0-9]+([-,][0-9]+)*( @ [0-9a-f]{7,40})?$'   # no `:` before the line: `T11:49:23.510+02:00` is a time
# A repo is named by its path, an `owner/name` slug ending in its directory name, or a
# node id; a name is not followed by `.` and a letter, which keeps `acme.app` from naming
# the checkout `acme`. With no named repo and no prefix, nothing is a signal.
sig_alt=$(printf '%s\n' "$repo_alt" "${base_alt:+[A-Za-z0-9_.-]+/($base_alt)}" "${prefix_alt:+($prefix_alt)-[0-9]+}" | awk 'NF' | paste -sd'|' -)
sig_re='(^|[^A-Za-z0-9_/.-])('"${sig_alt:-a^}"')([^A-Za-z0-9_.-]|\.([^A-Za-z0-9]|$)|$)'
neg_re='(^|[^A-Za-z])(no|not|never|without|nor|lacks|missing|absent|gains?|adds?|new|introduces?)[[:space:]]+$'
end_re='[.!?;][])*'"'"']*[[:space:]]|[|]'
file_re='^[][A-Za-z0-9_./()-]+\.[a-z0-9]{1,5}$'

ntok=0; sent=0; span_len=0
add_tok() { # kind text offset [repo path lines sha]
  tk_kind[ntok]=$1; tk_text[ntok]=$2; tk_sent[ntok]=$sent; tk_off[ntok]=$3; tk_len[ntok]=$span_len
  tk_line[ntok]=$(line_of "$3")
  tk_repo[ntok]=${4:-}; tk_path[ntok]=${5:-}; tk_lines[ntok]=${6:-}; tk_sha[ntok]=${7:-}
  tk_bare[ntok]=$([ -z "${4:-}" ] && echo 1 || echo 0); tk_bad[ntok]=0
  ntok=$((ntok + 1))
}

line_of() { # offset in the joined paragraph -> the source line it came from
  local i=0 n=$1
  while [ $((i + 1)) -lt "$npl" ] && [ "${pl_start[i + 1]}" -le "$n" ]; do i=$((i + 1)); done
  printf '%s' "${pl_no[i]}"
}

repo_named() { # a name scan_signals matched -> its repo; empty when it names none swept here
  local m=$1 r
  for r in $REPOS; do [ "$m" = "$r" ] && { printf '%s' "$r"; return; }; done
  case $m in
    *-[0-9]*) printf '%s\n' "$PREFIXES" | awk -v p="${m%-*}" '$1 == p { printf "%s", $2; exit }'; return ;;
  esac
  for r in $REPOS; do [ "${m##*/}" = "${r##*/}" ] && { printf '%s' "$r"; return; }; done
}

scan_signals() { # text offset -> a REPO token per repo the text names, in order
  local t=$1 m r
  while [[ $t =~ $sig_re ]]; do
    m=${BASH_REMATCH[2]}; r=""
    r=$(repo_named "$m")
    [ -n "$r" ] && add_tok REPO "$m" "$2" "$r"
    t=${t#*"${BASH_REMATCH[0]}"}
  done
}

negated() { [[ $1 =~ $neg_re ]]; }

code_span() { # span offset preceding-prose
  local s repo path lines sha r
  scan_signals "$1" "$2"
  if [[ $1 =~ $cite_re ]] && [ -n "${BASH_REMATCH[5]}${BASH_REMATCH[10]}" ]; then
    repo=${BASH_REMATCH[2]}; path=${BASH_REMATCH[3]}; lines=${BASH_REMATCH[5]}; sha=${BASH_REMATCH[10]}
    if [ -z "$repo" ]; then case $path in */*|*.*) ;; *) return ;; esac; fi
    add_tok CITE "$1" "$2" "$repo" "$path" "$lines" "$sha"
    return
  fi
  if [[ $1 =~ $citeish_re ]] && [[ $1 != *://* ]]; then   # `src/{kind}/x.py:12`: shaped like one, parsed by nothing
    add_tok UNPARSED "$1" "$2"
    return
  fi
  s=${1%%(*}                                    # restorePasskeyNudge() -> restorePasskeyNudge
  [[ $s =~ $file_re ]] && { add_tok FILE "$s" "$2"; return; }   # a file named without a line
  negated "$3" && return
  [[ $s =~ ^[A-Za-z_][A-Za-z0-9_.:-]*$ ]] || return   # commands, paths, URLs, flags, globs
  [ ${#s} -ge 3 ] || return
  [[ $s =~ [A-Za-z][A-Za-z] ]] || return        # v0.2.0, 2026-04-17T11:49
  [[ $s =~ ^[0-9a-f]{7,40}$ ]] && return        # a sha named in prose
  [[ $s =~ ^[a-z]+-[0-9]+$ ]] && return         # a node id
  case $s in main|master|HEAD) return ;; esac                     # names of refs and repos,
  for r in $named_repos; do [ "$s" = "$r" ] || [ "$s" = "${r##*/}" ] && return; done   # not things in a file
  add_tok SYM "$s" "$2"
}

quote_span() { # span offset preceding-prose
  scan_signals "$1" "$2"
  negated "$3" && return
  [[ $1 == *" "* ]] && [ ${#1} -ge 8 ] || return
  add_tok QUOTE "$1" "$2"
}

tokenise() { # $P -> the tk_* arrays
  local rest=$P pre d body span consumed=0 t
  ntok=0; sent=0
  while [ -n "$rest" ]; do
    pre=${rest%%[\`\"]*}
    scan_signals "$pre" "$consumed"
    t=$pre; while [[ $t =~ $end_re ]]; do sent=$((sent + 1)); t=${t#*"${BASH_REMATCH[0]}"}; done
    [ "$pre" = "$rest" ] && break
    consumed=$((consumed + ${#pre}))
    d=${rest:${#pre}:1}
    body=${rest:${#pre}+1}
    case $body in
      *"$d"*) span=${body%%"$d"*} ;;
      *) rest=$body; consumed=$((consumed + 1)); continue ;;   # unclosed: plain prose
    esac
    span_len=$((${#span} + 2))
    t=$pre; [ ${#t} -le 20 ] || t=${t: -20}     # `${pre: -20}` is empty when pre is shorter
    if [ "$d" = '`' ]; then code_span "$span" "$consumed" "$t"
    else quote_span "$span" "$consumed" "$t"; fi
    consumed=$((consumed + span_len))
    rest=${body:${#span}+1}
  done
}

# ------------------------------------------------------------------ the checks

n_cite=0; n_miss=0; n_drift=0; n_skip=0; n_clean=0
seen_full=""            # "repo:path:lines" per citation resolved so far, in plan order
carry_global=""         # the last repo named by any paragraph before this one
needles=""              # the current sentence's symbols and quotes, one per line
report() { # kind token-index message
  # shellcheck disable=SC2016  # the backticks are literal: the span is quoted as written
  printf '%s %s:%s  `%s`: %s\n' "$1" "$plan" "${tk_line[$2]}" "${tk_text[$2]}" "$3"
  tk_bad[$2]=1
  case $1 in MISS) n_miss=$((n_miss + 1)) ;; DRIFT) n_drift=$((n_drift + 1)) ;; SKIP) n_skip=$((n_skip + 1)) ;; esac
}

resolve_repo() { # token-index -> sets tk_repo[i] for a bare citation, or leaves it empty
  local i=$1 j r=""
  [ -z "${tk_sha[i]}" ] || r=$(repo_of_sha "${tk_sha[i]}")
  if [ -z "$r" ]; then
    for ((j = i - 1; j >= 0; j--)); do [ "${tk_kind[j]}" = REPO ] && { r=${tk_repo[j]}; break; }; done
  fi
  [ -n "$r" ] || r=$carry_global                    # the last repo an earlier paragraph named
  if [ -z "$r" ]; then                              # a later mention
    for ((j = i + 1; j < ntok; j++)); do
      [ "${tk_kind[j]}" = REPO ] && { r=${tk_repo[j]}; break; }
    done
  fi
  tk_repo[i]=$r
}

shares_a_range() { # lines-spec lines-spec -> 0 when they have a range in common
  local a b
  for a in ${1//,/ }; do for b in ${2//,/ }; do [ "$a" = "$b" ] && return 0; done; done
  return 1
}

resolve_path() { # token-index -> sets tk_repo[i] and tk_path[i] to the one file; MISS/SKIP otherwise
  local i=$1
  local bare=${tk_path[i]} end=${tk_lines[i]##*[-,]} r p f j c="" kept="" n d stem=""
  end=${end:-0}
  while IFS= read -r r; do                          # cited in full earlier with a line in common:
    [ -n "$r" ] || continue                         # the plan has already resolved it
    p=${r%:*}; p=${p#*:}
    if [ "$p" = "$bare" ] || [[ $p == */"$bare" ]]; then
      shares_a_range "${r##*:}" "${tk_lines[i]}" && kept=${r%:*}
    fi
  done <<<"$seen_full"
  [ -z "$kept" ] || { tk_repo[i]=${kept%%:*}; tk_path[i]=${kept#*:}; return 0; }
  if [[ $bare == .* ]]; then                        # `.render.test.tsx` after `x.test.ts:12`
    for ((j = i - 1; j >= 0; j--)); do
      [ "${tk_kind[j]}" = CITE ] && [ -n "${tk_file[j]:-}" ] && { stem=${tk_path[j]##*/}; stem=${stem%%.*}; break; }
    done
  fi
  gather() { # stem repos... -> "repo:path" per suffix match long enough to hold the cited line
    local st=$1 r p f; shift
    for r in "$@"; do
      { have_repo "$r" && ensure_repo "$r"; } || continue
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        f=$(file_at "$r" "$(ref_of "$r")" "$p") || continue
        [ "$(line_count "$f")" -ge "$end" ] && printf '%s:%s\n' "$r" "$p"
      done <<<"$(suffix_in "$(tree_list "$r")" "$st$bare")"
    done
  }
  gather_anywhere() { # stem -> $c: the prose's repo first, then every other one
    local others="" r
    # shellcheck disable=SC2086  # REPOS is a space-separated list, split on purpose
    c=$(gather "$1" ${tk_repo[i]:-$REPOS})
    [ -n "$c" ] || [ -z "${tk_repo[i]}" ] && return
    for r in $REPOS; do [ "$r" = "${tk_repo[i]}" ] || others="$others $r"; done
    # shellcheck disable=SC2086  # a space-separated list, split on purpose
    c=$(gather "$1" $others)
  }
  gather_anywhere "$stem"
  [ -n "$c" ] || [ -z "$stem" ] || gather_anywhere ""
  n=$(printf '%s' "$c" | grep -c .)
  if [ "$n" -gt 1 ]; then
    while IFS= read -r p; do                        # cited in full earlier, with a line in common
      [ -n "$p" ] || continue
      while IFS= read -r r; do
        [ "${r%:*}" = "$p" ] && shares_a_range "${r##*:}" "${tk_lines[i]}" && kept=$p
      done <<<"$seen_full"
    done <<<"$c"
    if [ -z "$kept" ] && [ -n "$needles" ]; then    # the sentence's own names sit near the line
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        f=$(file_at "${p%%:*}" "$(ref_of "${p%%:*}")" "${p#*:}") || continue
        while IFS= read -r r; do
          [ -n "$r" ] || continue
          read -r d _ < <(nearest "$f" "$r" "${tk_lines[i]}")
          [ "$d" -ge 0 ] && [ "$d" -le "$drift_max" ] || continue
          [ "$kept" = "$p" ] || { [ -z "$kept" ] && kept=$p || kept=-; }
        done <<<"$needles"
      done <<<"$c"
      [ "$kept" != - ] || kept=""
    fi
    if [ -z "$kept" ]; then                         # the most recently cited in full
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        while IFS= read -r p; do [ -n "$p" ] && [ "${r%:*}" = "$p" ] && kept=$p; done <<<"$c"
      done <<<"$seen_full"
    fi
    if [ -z "$kept" ]; then                         # the one at the repo root
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case ${p#*:} in */*) ;; *) [ -z "$kept" ] && kept=$p || kept=- ;; esac
      done <<<"$c"
      [ "$kept" != - ] || kept=""
    fi
    [ -z "$kept" ] || { c=$kept; n=1; }
  fi
  case $n in
    0) if [ -n "$(suffix_in "$(plans_list)" "$bare")" ]; then report SKIP "$i" "a plans-repo file: not swept"
       elif [ -n "${tk_repo[i]}" ]; then report MISS "$i" "no file named $bare at $(ref_of "${tk_repo[i]}") of ${tk_repo[i]}"
       else report MISS "$i" "no file named $bare at the default branch of any repo"; fi
       return 1 ;;
    1) c=${c%$'\n'}; tk_repo[i]=${c%%:*}; tk_path[i]=${c#*:} ;;
    *) report SKIP "$i" "ambiguous: $(printf '%s' "$c" | head -4 | tr '\n' ' ')$([ "$n" -gt 4 ] && printf '+%d more' $((n - 4)))"
       return 1 ;;
  esac
}

# Where a needle sits at the cited sha, for the parenthetical on a MISS or DRIFT line.
at_sha() { # token-index needle -> "" when the citation carries no sha
  local i=$1 f d
  [ -n "${tk_sha[i]}" ] || return 0
  f=$(file_at "${tk_repo[i]}" "${tk_sha[i]}" "${tk_path[i]}") || { printf ' (no such file at %s either)' "${tk_sha[i]}"; return; }
  read -r d _ < <(nearest "$f" "$2" "${tk_lines[i]}")
  if [ "$d" -lt 0 ]; then printf ' (absent at %s too: wrong when cited)' "${tk_sha[i]}"
  elif [ "$d" -le "$drift_max" ]; then printf ' (%s lines off at %s: the tree moved since)' "$d" "${tk_sha[i]}"
  else printf ' (%s lines off at %s too: wrong when cited)' "$d" "${tk_sha[i]}"; fi
}

check_cite() { # token-index -> 0 when the file resolved and tk_file[i] holds its cached copy
  local i=$1 f n end r
  n_cite=$((n_cite + 1))
  if [ "${tk_bare[i]}" = 1 ]; then
    resolve_repo "$i"
    resolve_path "$i" || return 1
  fi
  ensure_repo "${tk_repo[i]}" || { report SKIP "$i" "no checkout for ${tk_repo[i]}"; return 1; }
  if [ -n "${tk_sha[i]}" ] && ! git -C "$(rdir "${tk_repo[i]}")" rev-parse -q --verify "${tk_sha[i]}^{commit}" >/dev/null 2>&1; then
    report MISS "$i" "unknown sha ${tk_sha[i]} in ${tk_repo[i]}"
    tk_sha[i]=""
  fi
  if ! f=$(file_at "${tk_repo[i]}" "$(ref_of "${tk_repo[i]}")" "${tk_path[i]}"); then
    r="no such file at $(ref_of "${tk_repo[i]}") of ${tk_repo[i]}"
    if [ -n "${tk_sha[i]}" ]; then
      if file_at "${tk_repo[i]}" "${tk_sha[i]}" "${tk_path[i]}" >/dev/null; then r="$r (present at ${tk_sha[i]}: moved or deleted since)"
      else r="$r (nor at ${tk_sha[i]}: wrong when cited)"; fi
    fi
    report MISS "$i" "$r"
    return 1
  fi
  tk_file[i]=$f
  seen_full="$seen_full${tk_repo[i]}:${tk_path[i]}:${tk_lines[i]}"$'\n'
  end=${tk_lines[i]##*[-,]}
  n=$(line_count "$f")
  [ -z "$end" ] || [ "$end" -le "$n" ] || report DRIFT "$i" "range runs past the end of the file ($n lines)"
  return 0
}

check_needle() { # needle label primary-cite other-cites... -> one MISS or DRIFT line, or nothing
  local needle=$1 label=$2 i=$3 j d at files
  shift 3
  read -r d at < <(nearest "${tk_file[i]}" "$needle" "${tk_lines[i]}")
  if [ "$d" -lt 0 ]; then
    files=${tk_repo[i]}/${tk_path[i]}
    for j in "$@"; do
      read -r d _ < <(nearest "${tk_file[j]}" "$needle" "${tk_lines[j]}")
      [ "$d" -lt 0 ] || return 0                    # in a neighbour's file: paired wrong, not stale
      files="$files, ${tk_repo[j]}/${tk_path[j]}"
    done
    report MISS "$i" "$label not in $files$(at_sha "$i" "$needle")"
  elif [ "$d" -gt "$drift_max" ]; then
    report DRIFT "$i" "$label nearest at :$at, $d lines from :${tk_lines[i]}$(at_sha "$i" "$needle")"
  fi
}

gap() { # two token indices -> the prose between them, in characters
  local a=$1 b=$2 g
  [ "${tk_off[a]}" -le "${tk_off[b]}" ] || { a=$2; b=$1; }
  g=$((tk_off[b] - tk_off[a] - tk_len[a]))
  [ "$g" -ge 0 ] && printf '%s' "$g" || printf 0
}

fragments() { # quote -> its pieces around an ellipsis, trimmed, one per line
  local q=${1//.../…} frag
  q=${q//\*\*/}
  while IFS= read -r frag; do
    frag=${frag#"${frag%%[! ]*}"}; frag=${frag%"${frag##*[! ]}"}
    frag=${frag%[.,;:]}
    [ ${#frag} -ge 4 ] && printf '%s\n' "$frag"
  done <<<"${q//…/$'\n'}"
}

check_sentence() { # sentence number -> its citations, then each needle against the nearest
  local s=$1 i j cites="" ok="" others done="" best best_j g frag
  for ((i = 0; i < ntok; i++)); do
    [ "${tk_sent[i]}" = "$s" ] || continue
    case ${tk_kind[i]} in
      CITE)     cites="$cites $i" ;;
      UNPARSED) n_cite=$((n_cite + 1)); report SKIP "$i" "a citation shape this sweep does not parse" ;;
    esac
  done
  [ -n "$cites" ] || return
  needles=""
  for ((i = 0; i < ntok; i++)); do
    [ "${tk_sent[i]}" = "$s" ] || continue
    case ${tk_kind[i]} in
      SYM)   needles="$needles${tk_text[i]}"$'\n' ;;
      QUOTE) needles="$needles$(fragments "${tk_text[i]}" | head -1)"$'\n' ;;
    esac
  done
  for i in $cites; do check_cite "$i" && ok="$ok $i"; done
  [ -n "$ok" ] || return
  for ((i = 0; i < ntok; i++)); do
    [ "${tk_sent[i]}" = "$s" ] || continue
    case ${tk_kind[i]} in SYM|QUOTE) ;; *) continue ;; esac
    case $done in *"|${tk_text[i]}|"*) continue ;; esac; done="$done|${tk_text[i]}|"
    best=-1; best_j=-1
    for ((j = 0; j < ntok; j++)); do              # the nearest citation OR file mention
      [ "${tk_sent[j]}" = "$s" ] || continue
      case ${tk_kind[j]} in CITE|FILE) ;; *) continue ;; esac
      g=$(gap "$i" "$j")
      if [ "$best" -lt 0 ] || [ "$g" -lt "$best" ]; then best=$g; best_j=$j; fi
    done
    [ "$best" -le "$pair_max" ] || continue
    case " $ok " in *" $best_j "*) ;; *) continue ;; esac   # a file mention, or a MISS already
    others=${ok/ $best_j/}
    if [ "${tk_kind[i]}" = SYM ]; then
      # shellcheck disable=SC2086  # $others is a list of token indices, split on purpose
      check_needle "${tk_text[i]}" "\`${tk_text[i]}\`" "$best_j" $others
      continue
    fi
    while IFS= read -r frag; do
      [ -n "$frag" ] || continue
      # shellcheck disable=SC2086  # as above
      check_needle "$frag" "\"$(printf '%.48s' "$frag")$([ ${#frag} -gt 48 ] && printf '…')\"" "$best_j" $others
    done <<<"$(fragments "${tk_text[i]}")"
  done
}

process_paragraph() {
  local s i
  [ -n "$P" ] || return
  tokenise
  for ((s = 0; s <= sent; s++)); do check_sentence "$s"; done
  for ((i = 0; i < ntok; i++)); do
    if [ "${tk_kind[i]}" = CITE ] && [ "${tk_bad[i]}" = 0 ]; then n_clean=$((n_clean + 1)); fi
  done
  for ((i = ntok - 1; i >= 0; i--)); do
    [ "${tk_kind[i]}" = REPO ] && { carry_global=${tk_repo[i]}; break; }
  done
}

# -------------------------------------------------------------------- the walk
#
# Paragraphs end at a blank line, a heading or a list item; fenced code is skipped, being
# commands rather than citations. Each paragraph is joined with single spaces, list
# markers and indentation dropped, and every source line's start offset kept so a token
# can be reported on the line it came from.

P=""; npl=0; in_fence=false; lineno=0
flush() { process_paragraph; P=""; npl=0; }
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  s=${line#"${line%%[![:space:]]*}"}
  case $s in '```'*|'~~~'*) if $in_fence; then in_fence=false; else in_fence=true; flush; fi; continue ;; esac
  $in_fence && continue
  case $s in
    '') flush; continue ;;
    '#'*|-\ *|\*\ *|+\ *|[0-9]*.\ *) flush ;;
  esac
  s=${s#'> '}
  [[ $s =~ ^([-*+]|[0-9]+\.)[[:space:]]+ ]] && s=${s#"${BASH_REMATCH[0]}"}
  [ -z "$P" ] || P="$P "
  pl_start[npl]=${#P}; pl_no[npl]=$lineno; npl=$((npl + 1))
  P="$P$s"
done < "$plan"
flush

printf 'OK %d of %d citations; DRIFT %d, MISS %d, SKIP %d\n' "$n_clean" "$n_cite" "$n_drift" "$n_miss" "$n_skip"
[ -z "$(ls -A "$TMP/.unavailable")" ] || exit 2
[ "$n_miss" -eq 0 ] || exit 1
if $strict; then [ "$n_drift" -eq 0 ] || exit 1; fi
exit 0
