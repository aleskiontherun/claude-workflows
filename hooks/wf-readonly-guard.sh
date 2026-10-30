#!/usr/bin/env bash
# PreToolUse hook that keeps the wf read-only agents read-only.
#
#   wf-readonly-guard.sh < <hook input JSON>
#
# Claude Code runs it before every Bash call in a session where the plugin is enabled
# (hooks/hooks.json). It reads the hook input from stdin and acts only when `agent_type`
# names one of the agents this plugin defines as read-only -- reviewer, validator,
# plan-reviewer, plan-validator, fold-checker -- with or without the `ontherun:`
# namespace, since the docs leave open which form a plugin agent's calls carry; an agent of
# your own named `reviewer` or `validator` is therefore guarded too. For every other caller, and for input it can't parse, it exits 0 with no
# output: no decision, the normal permission flow applies.
#
# For those agents the command is split into segments on newlines, `;`, `|`, `&&` and
# `||`, and every segment's first word has to be on the allowlist below, with its own
# flags checked where a read-only program has a writing mode. A redirection to anywhere
# but /dev/null, a `$(...)` or backtick substitution, or a process substitution is denied
# outright: the guard can't see what runs inside one. A failing segment denies the whole
# call -- a `permissionDecision` of `deny` on stdout, with the reason -- and nothing runs.
#
#   git    diff log show grep rev-parse blame ls-files ls-tree ls-remote cat-file
#          merge-base rev-list status fetch describe shortlog name-rev for-each-ref
#          show-ref count-objects; `symbolic-ref` with one ref; `worktree list`;
#          `remote` with -v, show or get-url; `branch` and `tag` in their listing forms
#          only; `config` only with --get, --get-all, --get-regexp, --list or -l
#   gh     pr list|view|checks|diff|status; issue list|view; repo view; run list|view;
#          release list|view; auth status; api with no method other than GET and no body
#   curl   with no method other than GET or HEAD, no body, no output file but /dev/null
#   find   without -delete, -exec, -execdir, -ok, -okdir, -fls or -fprint*
#   sed    without -i or --in-place;  awk  without system()
#   and    ls cat head tail wc grep egrep fgrep rg sort uniq cut tr jq diff comm column
#          nl echo printf true false test [ date basename dirname realpath readlink pwd
#          which command type file stat du cd
#
# Quoted strings are masked before the split, so a `|` or `>` inside a grep pattern is not
# read as a pipe or a redirection; a flag value that is quoted (`-o "/dev/null"`) is not seen
# either, and is denied.
#
# Needs jq and perl. Always exits 0; the decision is the JSON, and a hook that exits non-zero for a
# parse error would block every Bash call in the session.

set -u

input=$(cat) || exit 0
agent=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null) || exit 0
[ -n "$agent" ] || exit 0
case ${agent#ontherun:} in
  reviewer|validator|plan-reviewer|plan-validator|fold-checker) ;;
  *) exit 0 ;;
esac
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

deny() { # reason
  jq -n --arg r "$agent is read-only: $1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Anything the guard can't look inside. Checked on the raw text: a substitution inside
# double quotes still runs.
# shellcheck disable=SC2016
case $cmd in
  *'$('*|*'`'*) deny "command substitution is not allowed; run the inner command on its own" ;;
  *'<('*|*'>('*) deny "process substitution is not allowed" ;;
esac

# Everything else is judged on the command with its quoted strings masked, so a `|` or `>`
# inside a grep pattern is not read as a pipe or a redirection.
masked=$(printf '%s' "$cmd" | perl -pe 's/"(?:[^"\\]|\\.)*"/"Q"/g; s/\x27[^\x27]*\x27/\x27Q\x27/g')
stripped=$(printf '%s' "$masked" | sed -E 's#[0-9]*&?>>?[[:space:]]*/dev/null##g; s#2>&1##g')
case $stripped in
  *'>'*) deny "redirecting output to a file is not allowed (only to /dev/null)" ;;
esac

# Count the words that are not flags. `--` ends the flags.
nonflags() { # words... -> count
  local n=0 w flags_done=false
  for w in "$@"; do
    if $flags_done; then n=$((n + 1)); continue; fi
    case $w in --) flags_done=true ;; -*) ;; *) n=$((n + 1)) ;; esac
  done
  printf '%s\n' "$n"
}

has_flag() { # pattern words... -> 0 when a word matches the glob pattern
  local pat=$1 w; shift
  for w in "$@"; do
    # shellcheck disable=SC2254
    case $w in $pat) return 0 ;; esac
  done
  return 1
}

check_git() { # words after `git`
  local -a w=("$@")
  local sub="" i=0
  while [ $i -lt ${#w[@]} ]; do
    case ${w[$i]} in
      -C|-c|--git-dir|--work-tree|--namespace) i=$((i + 2)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--no-pager|-P|--paginate|-p|--literal-pathspecs|--no-optional-locks|--no-replace-objects|--bare) i=$((i + 1)); continue ;;
      -*) deny "unknown git option \`${w[$i]}\` before the subcommand" ;;
      *) sub=${w[$i]}; i=$((i + 1)); break ;;
    esac
  done
  local -a rest=("${w[@]:$i}")
  case $sub in
    diff|log|show|grep|rev-parse|blame|ls-files|ls-tree|ls-remote|cat-file|merge-base|rev-list|status|fetch|describe|shortlog|name-rev|for-each-ref|show-ref|count-objects|check-ignore) ;;
    symbolic-ref)
      [ "$(nonflags "${rest[@]+"${rest[@]}"}")" -le 1 ] || deny "\`git symbolic-ref\` with two refs writes one" ;;
    worktree)
      [ "${rest[0]:-}" = list ] || deny "\`git worktree ${rest[0]:-}\` changes worktrees; only \`list\` is allowed" ;;
    remote)
      case ${rest[0]:-} in ''|-v|--verbose|show|get-url) ;; *) deny "\`git remote ${rest[0]}\` changes remotes" ;; esac ;;
    branch)
      if has_flag '-[dDmMcCuf]' "${rest[@]+"${rest[@]}"}" || has_flag '-[dDmMcCuf][a-zA-Z]*' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--delete' "${rest[@]+"${rest[@]}"}" || has_flag '--move' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--copy' "${rest[@]+"${rest[@]}"}" || has_flag '--force' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--set-upstream-to*' "${rest[@]+"${rest[@]}"}" || has_flag '--unset-upstream' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--edit-description' "${rest[@]+"${rest[@]}"}" || has_flag '--track' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--no-track' "${rest[@]+"${rest[@]}"}"; then
        deny "\`git branch\` with a flag that creates, moves or deletes a branch"
      fi
      if [ "$(nonflags "${rest[@]+"${rest[@]}"}")" -gt 0 ] \
         && ! { has_flag '-[arlv]*' "${rest[@]+"${rest[@]}"}" || has_flag '--list' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--merged' "${rest[@]+"${rest[@]}"}" || has_flag '--no-merged' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--contains' "${rest[@]+"${rest[@]}"}" || has_flag '--no-contains' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--points-at' "${rest[@]+"${rest[@]}"}" || has_flag '--show-current' "${rest[@]+"${rest[@]}"}"; }; then
        deny "\`git branch <name>\` creates a branch; list with -a, -r, --list, --merged, --contains or --points-at"
      fi ;;
    tag)
      if has_flag '-[dasfFm]' "${rest[@]+"${rest[@]}"}" || has_flag '-[dasfFm][a-zA-Z]*' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--delete' "${rest[@]+"${rest[@]}"}" || has_flag '--annotate' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--sign' "${rest[@]+"${rest[@]}"}" || has_flag '--force' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--message*' "${rest[@]+"${rest[@]}"}" || has_flag '--file*' "${rest[@]+"${rest[@]}"}"; then
        deny "\`git tag\` with a flag that creates or deletes a tag"
      fi
      if [ "$(nonflags "${rest[@]+"${rest[@]}"}")" -gt 0 ] \
         && ! { has_flag '-l' "${rest[@]+"${rest[@]}"}" || has_flag '--list' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--contains' "${rest[@]+"${rest[@]}"}" || has_flag '--no-contains' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--points-at' "${rest[@]+"${rest[@]}"}" || has_flag '--merged' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--no-merged' "${rest[@]+"${rest[@]}"}"; }; then
        deny "\`git tag <name>\` creates a tag; list with -l, --list, --contains or --points-at"
      fi ;;
    config)
      if has_flag '--unset*' "${rest[@]+"${rest[@]}"}" || has_flag '--add' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--replace-all' "${rest[@]+"${rest[@]}"}" || has_flag '--edit' "${rest[@]+"${rest[@]}"}" \
         || has_flag '-e' "${rest[@]+"${rest[@]}"}" || has_flag '--rename-section' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--remove-section' "${rest[@]+"${rest[@]}"}" || has_flag 'set' "${rest[@]+"${rest[@]}"}" \
         || has_flag 'unset' "${rest[@]+"${rest[@]}"}"; then
        deny "\`git config\` in a writing form"
      fi
      has_flag '--get' "${rest[@]+"${rest[@]}"}" || has_flag '--get-all' "${rest[@]+"${rest[@]}"}" \
        || has_flag '--get-regexp' "${rest[@]+"${rest[@]}"}" || has_flag '--list' "${rest[@]+"${rest[@]}"}" \
        || has_flag '-l' "${rest[@]+"${rest[@]}"}" || has_flag 'get' "${rest[@]+"${rest[@]}"}" || has_flag 'list' "${rest[@]+"${rest[@]}"}" \
        || deny "\`git config\` only with --get, --get-all, --get-regexp, --list or -l" ;;
    '') deny "\`git\` with no subcommand" ;;
    *) deny "\`git $sub\` is not on the read-only allowlist" ;;
  esac
}

check_gh() { # words after `gh`
  local sub=${1:-} act=${2:-}
  case "$sub $act" in
    'pr list'|'pr view'|'pr checks'|'pr diff'|'pr status'|'issue list'|'issue view'|'repo view'|'run list'|'run view'|'release list'|'release view'|'auth status') return 0 ;;
  esac
  if [ "$sub" = api ]; then
    shift
    local -a w=("$@")
    local i=0
    while [ $i -lt ${#w[@]} ]; do
      case ${w[$i]} in
        -X|--method)
          case ${w[$((i + 1))]:-} in GET|get) ;; *) deny "\`gh api\` with a method other than GET" ;; esac
          i=$((i + 2)); continue ;;
        -X*|--method=*)
          case ${w[$i]#*[X=]} in GET|get) ;; *) deny "\`gh api\` with a method other than GET" ;; esac ;;
        -f|-F|--field|--raw-field|--input|--field=*|--raw-field=*|--input=*)
          deny "\`gh api\` with a request body" ;;
      esac
      i=$((i + 1))
    done
    return 0
  fi
  deny "\`gh $sub $act\` is not on the read-only allowlist"
}

check_curl() { # words after `curl`
  local -a w=("$@")
  local i=0
  while [ $i -lt ${#w[@]} ]; do
    case ${w[$i]} in
      -X|--request)
        case ${w[$((i + 1))]:-} in GET|HEAD|get|head) ;; *) deny "\`curl\` with a method other than GET or HEAD" ;; esac
        i=$((i + 2)); continue ;;
      -X*|--request=*)
        case ${w[$i]#*[X=]} in GET|HEAD|get|head) ;; *) deny "\`curl\` with a method other than GET or HEAD" ;; esac ;;
      -d|--data|--data-*|-F|--form|--form-string|-T|--upload-file|--json|--data=*|--form=*|--json=*)
        deny "\`curl\` with a request body" ;;
      -o|--output)
        [ "${w[$((i + 1))]:-}" = /dev/null ] || deny "\`curl\` writing to a file; only -o /dev/null is allowed"
        i=$((i + 2)); continue ;;
      -o*|--output=*)
        [ "${w[$i]#*[o=]}" = /dev/null ] || deny "\`curl\` writing to a file; only -o /dev/null is allowed" ;;
      -O|--remote-name|--remote-name-all|-J|--remote-header-name|--create-dirs|-c|--cookie-jar|-D|--dump-header|--trace|--trace-ascii|--trace-ascii=*|--trace=*)
        deny "\`curl ${w[$i]}\` writes a file" ;;
    esac
    i=$((i + 1))
  done
}

check_segment() { # one command segment
  local seg=$1
  seg=${seg#"${seg%%[![:space:](]*}"}   # leading whitespace and subshell parens
  seg=${seg%"${seg##*[![:space:])]}"}   # trailing whitespace and parens
  [ -n "$seg" ] || return 0
  local -a words
  # shellcheck disable=SC2206
  words=($seg)
  # Leading VAR=value assignments and the harmless wrappers.
  while [ ${#words[@]} -gt 0 ]; do
    case ${words[0]} in
      [A-Za-z_]*=*|time|nice|command) words=("${words[@]:1}") ;;
      *) break ;;
    esac
  done
  [ ${#words[@]} -gt 0 ] || return 0
  local prog=${words[0]##*/}
  local -a rest=("${words[@]:1}")
  case $prog in
    git) check_git "${rest[@]+"${rest[@]}"}" ;;
    gh) check_gh "${rest[@]+"${rest[@]}"}" ;;
    curl) check_curl "${rest[@]+"${rest[@]}"}" ;;
    find)
      has_flag '-delete' "${rest[@]+"${rest[@]}"}" && deny "\`find -delete\` deletes"
      has_flag '-exec*' "${rest[@]+"${rest[@]}"}" && deny "\`find -exec\` runs arbitrary commands"
      has_flag '-ok*' "${rest[@]+"${rest[@]}"}" && deny "\`find -ok\` runs arbitrary commands"
      has_flag '-fprint*' "${rest[@]+"${rest[@]}"}" && deny "\`find -fprint\` writes a file"
      has_flag '-fls' "${rest[@]+"${rest[@]}"}" && deny "\`find -fls\` writes a file" ;;
    sed)
      has_flag '-i*' "${rest[@]+"${rest[@]}"}" && deny "\`sed -i\` edits in place"
      has_flag '--in-place*' "${rest[@]+"${rest[@]}"}" && deny "\`sed --in-place\` edits in place" ;;
    awk|gawk|mawk)
      case $cmd in *'system('*) deny "\`awk\` with system() runs arbitrary commands" ;; esac ;;
    ls|cat|head|tail|wc|grep|egrep|fgrep|rg|sort|uniq|cut|tr|jq|diff|comm|column|nl|echo|printf|true|false|test|'['|date|basename|dirname|realpath|readlink|pwd|which|type|file|stat|du|cd) ;;
    *) deny "\`$prog\` is not on the read-only allowlist" ;;
  esac
  return 0
}

# Split the masked command into segments. `||` and `&&` before single `|`.
segments=$(printf '%s\n' "$masked" | sed -E 's/\|\|/\n/g; s/&&/\n/g; s/;/\n/g; s/\|/\n/g')
while IFS= read -r seg; do
  check_segment "$seg"
done <<EOF
$segments
EOF

exit 0
