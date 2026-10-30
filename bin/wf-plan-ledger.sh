#!/usr/bin/env bash
# Render a plan's Status ledger from its `## State` block.
#
#   wf-plan-ledger.sh <plan.md> [--write]
#
# Prints the ledger -- one bullet per node, in block order, under the plan's phase
# headings -- or, with --write, splices it into the plan in place of the ledger that is
# there. The block is the source and the ledger is derived from it, never hand-edited
# (reference/plan-format.md, *Who writes which*). The shape is
# `- **<id>** <title> — <state>`, the title in backticks for a PR node and plain for a
# `setup` or `manual` one, the state worded as that file's live-plan example.
#
# Links. A node's PR and squash sha link to GitHub when its `repo` is a checkout under the
# workspace root whose `origin` is on github.com: `[#12](https://github.com/o/n/pull/12)`,
# ``[`abc1234`](https://github.com/o/n/commit/abc1234)``. With no checkout there, or a
# remote elsewhere, they render unlinked -- `#12`, `` `abc1234` `` -- and a note goes to
# stderr. `repo: .` is the workspace root itself (the single-repo layout). The root is
# $WF_WORKSPACE, else the parent of the nearest ancestor directory named `plans`, else the
# plan's git toplevel (reference/workspace.md).
#
# Phase headings come from the block's `# ---- <name> ----` comments: each one groups
# the nodes that follow it, and the ledger gets a bold heading line before that group.
# An existing heading line in the ledger is kept by position -- the k-th comment keeps
# the text of the k-th heading -- so a parenthetical a human added to a heading survives
# regeneration; a comment with no heading yet gets `**<name>**` with its `Phase N: x`
# turned into `Phase N — X`.
#
# What --write replaces is exactly the ledger: the run of node bullets between the
# `**Status:` paragraph and the first `##`, plus the heading lines among them and, when
# the block's first node opens a phase, the heading above the first bullet. Prose around
# the ledger is untouched; a plan with no ledger yet gets one after its Status paragraph.
# The file is rewritten only when the result differs, and never on an error.
#
# The block is parsed here rather than by a YAML library on purpose: a squash sha of
# digits only (`sha: 0124767`) is an octal integer to a YAML 1.1 parser and a decimal
# one to a 1.2 parser, and either reading corrupts the link this script exists to print.
# Every scalar stays the text it was written as. The grammar is plan-format.md's -- a
# `nodes:` list of flat mappings, `needs: [a, b]` flow lists, quoted or plain scalars --
# and nothing deeper than a node's own fields (`delivered:` items, `check:`
# continuations) is looked at.
#
# Exit status: 0 rendered (or written); 1 the plan has no `## State` block, no
# `**Status:` line, or a node whose status needs a field it lacks (an `open` node with
# no `pr`, a `merged` one with no `sha`); 64 usage.
#
# Needs bash, awk and git. wf-plan-ledger.test.sh beside this file covers every status,
# the quoting forms, the links in both layouts, the heading rules and the --write splice.

set -u

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

usage() { printf 'usage: %s <plan.md> [--write]\n' "${0##*/}" >&2; exit 64; }

write=false
plan=""
for arg in "$@"; do
  case $arg in
    --write) write=true ;;
    -*) usage ;;
    *) [ -z "$plan" ] || usage; plan=$arg ;;
  esac
done
[ -n "$plan" ] || usage
[ -r "$plan" ] || { printf 'wf-plan-ledger: %s: cannot read\n' "$plan" >&2; exit 1; }

# The base URL of every repo the block names, as `repo<TAB>url` lines for the awk below.
# A repo with no GitHub checkout under the root gets no line; the awk leaves its links
# bare and says so once, for the repos where a link was actually wanted.
root=$(wf_root "$plan") || root=""
urls=""
while IFS= read -r repo; do
  [ -n "$repo" ] && [ -n "$root" ] || continue
  case $repo in .) dir=$root ;; *) dir=$root/$repo ;; esac
  [ -e "$dir/.git" ] || continue
  slug=$(wf_slug "$dir") || continue
  urls=$urls$(printf '%s\t%s' "$repo" "https://github.com/$slug")$'\n'
done <<EOF
$(awk '
  /^## State[ \t]*$/ { s = 1; next }
  s && !y && /^```yaml[ \t]*$/ { y = 1; next }
  y && /^```[ \t]*$/ { exit }
  y && /^[ ]+repo:/ {
    v = $0; sub(/^[ ]+repo:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
    if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
    if (!(v in seen)) { seen[v] = 1; print v }
  }' "$plan")
EOF
export WF_LEDGER_URLS="$urls" WF_LEDGER_ROOT="$root"

# One pass over the file. The preamble (everything before the first `##`) is scanned for
# the Status line and the existing ledger; the fenced block under `## State` is parsed
# into nodes; END renders and, in write mode, re-emits the file around the new ledger.
PROGRAM=$(cat <<'AWK'
function indent(s,   t) { t = s; sub(/[^ ].*$/, "", t); return length(t) }

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# YAML scalar -> text. Double quotes honour backslash escapes, single quotes fold '',
# and a plain scalar loses a trailing ` # comment`. Nothing is ever re-typed.
function unquote(v,   out, i, c) {
  if (v ~ /^".*"$/) {
    v = substr(v, 2, length(v) - 2); out = ""
    for (i = 1; i <= length(v); i++) {
      c = substr(v, i, 1)
      if (c == "\\" && i < length(v)) { i++; c = substr(v, i, 1) }
      out = out c
    }
    return out
  }
  if (v ~ /^'.*'$/) { v = substr(v, 2, length(v) - 2); gsub(/''/, "'", v); return v }
  sub(/[ \t]+#.*$/, "", v)
  return v
}

function val(k, key) { return ((k, key) in RAW) ? unquote(RAW[k, key]) : "" }

# The repo's GitHub base URL, from the map the shell built; "" leaves its links bare.
function url(repo) { return (repo in URL) ? URL[repo] : "" }

function pr_link(repo, pr,   u) {
  u = url(repo); if (u == "") BARE[repo] = 1
  return u == "" ? "#" pr : "[#" pr "](" u "/pull/" pr ")"
}

function sha_link(repo, sha,   u) {
  u = url(repo); return u == "" ? "`" sha "`" : "[`" sha "`](" u "/commit/" sha ")"
}

function fail(k, msg) { ERR[++nerr] = "wf-plan-ledger: " FILENAME ": node " ID[k] ": " msg }

function needs_list(k,   raw, parts, np, i, out) {
  raw = trim(val(k, "needs"))
  sub(/^\[/, "", raw); sub(/\]$/, "", raw)
  if (trim(raw) == "") return ""
  np = split(raw, parts, ","); out = ""
  for (i = 1; i <= np; i++) out = out (i > 1 ? ", " : "") "`" unquote(trim(parts[i])) "`"
  return out
}

# `# ---- Phase 1: pre-launch ----` -> `**Phase 1 — Pre-launch**`, for a phase whose
# heading nobody has written yet.
function derive(t,   i) {
  i = index(t, ": ")
  if (i) t = substr(t, 1, i - 1) " — " toupper(substr(t, i + 2, 1)) substr(t, i + 3)
  return "**" t "**"
}

function phrase(k,   status, pr, sha, repo, link, s, t) {
  status = val(k, "status"); repo = val(k, "repo"); pr = val(k, "pr"); sha = val(k, "sha")
  if (status == "open" || status == "draft-pr" || status == "merged") {
    if (pr == "") { fail(k, status " with no pr"); return "" }
    if (repo == "") { fail(k, status " with no repo"); return "" }
    link = pr_link(repo, pr)
  }
  if (status == "pending") {
    s = "not started"; t = needs_list(k)
    return t == "" ? s : s ", needs " t
  }
  if (status == "running") {
    t = val(k, "branch")
    return t == "" ? "in progress" : "in progress on `" t "`"
  }
  if (status == "open") return link " open, awaiting review"
  if (status == "draft-pr") return link " draft, waiting on the human"
  if (status == "merged") {
    if (sha == "") { fail(k, "merged with no sha"); return "" }
    t = val(k, "merged")
    return link " merged" (t == "" ? "" : " " t) ", squash " sha_link(repo, sha)
  }
  if (status == "blocked") {
    t = val(k, "reason")
    return t == "" ? "blocked" : "blocked: " t
  }
  if (status == "dropped") return "dropped"
  if (status == "done") {
    t = val(k, "kind")
    if (t != "setup" && t != "manual") { fail(k, "done on a pr node"); return "" }
    return "done"
  }
  fail(k, (status == "" ? "no status" : "unknown status `" status "`"))
  return ""
}

function bullet(k,   kind, title) {
  kind = val(k, "kind"); title = val(k, "title")
  if (title == "") { fail(k, "no title"); return "" }
  if (kind != "setup" && kind != "manual") title = "`" title "`"
  return "- **" ID[k] "** " title " — " phrase(k)
}

# ---- the block, one line at a time ----
function parse(s,   t, i, k, v, ind) {
  if (s ~ /^[ \t]*# ---- .* ----[ \t]*$/) {
    t = s; sub(/^[ \t]*# ---- /, "", t); sub(/ ----[ \t]*$/, "", t)
    pending = t; return
  }
  ind = indent(s)
  if (s ~ /^[ ]*- id:/) {
    n++; item = ind; field = ind + 2
    v = s; sub(/^[ ]*- id:[ \t]*/, "", v); ID[n] = unquote(v)
    if (pending != "") { HEAD[n] = pending; pending = "" }
    cur = ""; return
  }
  if (n == 0) return
  if (ind == field && s ~ /^[ ]*[A-Za-z_][A-Za-z0-9_-]*:/) {
    t = trim(s); i = index(t, ":"); k = substr(t, 1, i - 1); v = trim(substr(t, i + 1))
    # An empty value opens a list or a block scalar; nothing under it is a node field.
    if (v == "" || v == "|" || v == ">") { cur = ""; return }
    RAW[n, k] = v; cur = k; return
  }
  if (ind > field && cur != "") {          # a quoted scalar continued on the next line
    t = trim(s)
    if (t ~ /^- /) { cur = ""; return }
    RAW[n, cur] = RAW[n, cur] " " t; return
  }
  cur = ""
}

BEGIN {
  n = 0; e = 0; nerr = 0; pending = ""; cur = ""; item = 0; field = 0
  nu = split(ENVIRON["WF_LEDGER_URLS"], UL, "\n")
  for (i = 1; i <= nu; i++) if ((j = index(UL[i], "\t")) > 0) URL[substr(UL[i], 1, j - 1)] = substr(UL[i], j + 1)
}
{ L[NR] = $0 }
!first_h2 && /^## / { first_h2 = NR }
!status_line && /^\*\*Status:/ { status_line = NR }
/^## State[ \t]*$/ { in_state = 1; next }
in_state && !in_yaml && /^```yaml[ \t]*$/ { in_yaml = 1; next }
in_yaml && /^```[ \t]*$/ { in_yaml = 0; in_state = 0; block_seen = 1; next }
in_yaml { parse($0) }

END {
  if (!block_seen) { print "wf-plan-ledger: " FILENAME ": no `## State` block" > "/dev/stderr"; exit 1 }
  if (n == 0) { print "wf-plan-ledger: " FILENAME ": the block has no nodes" > "/dev/stderr"; exit 1 }
  if (!status_line) { print "wf-plan-ledger: " FILENAME ": no `**Status:` line" > "/dev/stderr"; exit 1 }
  lim = first_h2 ? first_h2 : NR + 1
  BULLET = "^- \\*\\*[a-z][a-z0-9-]*-[0-9]+[a-z]*\\*\\* "

  # The existing ledger: the run of bullets in the preamble, the heading lines among
  # them (a line at column 0 that is not a bullet -- an indented one is a bullet that
  # wrapped), and the heading above the first bullet when the block's first node opens
  # a phase. That last one must be a bold one-line paragraph and not the Status line.
  rs = 0; re = 0
  for (i = status_line + 1; i < lim; i++) if (L[i] ~ BULLET) { if (!rs) rs = i; re = i }
  # A wrapped bullet continues on indented lines, and the last bullet's tail is as much
  # the ledger as the rest; a region that stopped at its first line left that tail behind.
  if (re) while (re + 1 < lim && L[re + 1] ~ /^[ \t]+[^ \t]/) re++
  if (rs) {
    for (i = rs; i <= re; i++)
      if (L[i] !~ /^[ \t]*$/ && L[i] !~ BULLET && L[i] !~ /^[ \t]/) EX[++e] = L[i]
    if (1 in HEAD) {
      j = rs - 1
      while (j > status_line && L[j] ~ /^[ \t]*$/) j--
      if (j > status_line && L[j] ~ /^\*\*/ && L[j] !~ /^\*\*Status:/ && L[j - 1] ~ /^[ \t]*$/) {
        for (i = e; i >= 1; i--) EX[i + 1] = EX[i]
        EX[1] = L[j]; e++; rs = j
      }
    }
  }

  m = 0; hj = 0
  for (k = 1; k <= n; k++) {
    if (k in HEAD) {
      hj++
      if (m > 0) OUT[++m] = ""
      OUT[++m] = (hj <= e) ? EX[hj] : derive(HEAD[k])
      OUT[++m] = ""
    }
    OUT[++m] = bullet(k)
  }
  if (nerr) { for (i = 1; i <= nerr; i++) print ERR[i] > "/dev/stderr"; exit 1 }
  for (r in BARE)
    print "wf-plan-ledger: no GitHub checkout for `" r "` under " ENVIRON["WF_LEDGER_ROOT"] "; its links are left out" > "/dev/stderr"

  if (mode == "print") { for (i = 1; i <= m; i++) print OUT[i]; exit 0 }

  if (rs) {
    for (i = 1; i < rs; i++) print L[i]
    for (i = 1; i <= m; i++) print OUT[i]
    for (i = re + 1; i <= NR; i++) print L[i]
  } else {
    # No ledger yet: it goes after the Status paragraph, which ends at the first blank
    # line (or at the first `##`, in which case one is made).
    p = status_line
    while (p < lim && L[p] !~ /^[ \t]*$/) p++
    for (i = 1; i < p; i++) print L[i]
    print ""
    for (i = 1; i <= m; i++) print OUT[i]
    print ""
    for (i = (p < lim ? p + 1 : p); i <= NR; i++) print L[i]
  }
}
AWK
)

if $write; then
  tmp=$(mktemp) || exit 1
  trap 'rm -f "$tmp"' EXIT
  awk -v mode=write "$PROGRAM" "$plan" > "$tmp" || exit 1
  cmp -s "$tmp" "$plan" || cat "$tmp" > "$plan"
else
  awk -v mode=print "$PROGRAM" "$plan"
fi
