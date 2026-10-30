#!/usr/bin/env bash
# PreToolUse hook that keeps ontherun's read-only agents read-only.
#
#   readonly-guard.sh < <hook input JSON>
#
# Claude Code runs it before every Bash call in a session where the plugin is enabled
# (hooks/hooks.json). It reads the hook input from stdin and acts only when `agent_type`
# names one of the agents this plugin defines as read-only -- reviewer, validator,
# plan-reviewer, plan-validator, fold-checker -- with or without the `ontherun:` namespace,
# since the docs leave open which form a plugin agent's calls carry; an agent of your own
# named `reviewer` or `validator` is therefore guarded too. For every other caller, and for
# input it can't parse, it exits 0 with no output: no decision, the normal permission flow
# applies.
#
# For those agents the command is split into simple commands on newlines, `;`, `|`, `&`,
# `&&` and `||`, and every one has to pass. Quoted strings are masked, length for length,
# before the split, so a `|` inside a grep pattern is not a pipe -- and the words of each
# command are then taken from the unmasked text, so a `sed` or `awk` program is inspected
# as written. A redirection to anywhere but /dev/null, a `$(...)` or backtick substitution,
# a process substitution, any other `$` outside single quotes, a brace expansion, or text the
# tokenizer can't account for is denied outright -- the checks read words as written, and
# bash must not get to rewrite them afterwards. A
# failing command denies the whole call -- a `permissionDecision` of `deny` on stdout, with
# the reason -- and nothing runs.
#
#   NAME=value  before a command: only pager, locale and terminal variables; a pager's value
#               must be cat, less, more, true or false
#   git    diff log show grep rev-parse blame ls-files ls-tree ls-remote cat-file merge-base
#          rev-list status describe shortlog name-rev for-each-ref show-ref count-objects
#          check-ignore; `fetch` without a refspec destination, --stdin, or a forcing,
#          pruning or upstream flag; `symbolic-ref` with one ref; `worktree list`;
#          `remote` with -v, show or get-url; `branch` and `tag` in their listing forms;
#          `config` only with --get, --get-all, --get-regexp, --list or -l. Global `-c`
#          only for pager, color, abbreviation and locale keys, with the pager values above.
#          Never --output, --ext-diff, --open-files-in-pager (-O), --upload-pack, --exec-path
#          or --config-env
#   gh     pr list|view|checks|diff|status; issue list|view; repo view; run list|view;
#          release list|view; auth status; api with no method other than GET and no body
#   find   without -delete, -exec, -execdir, -ok, -okdir, -fls or -fprint*
#   never  sed, awk, curl or wget: each hides write or exec modes in its program or format
#          text, and the agents have Read, Grep and WebFetch for what those did
#   and every command named bare or under /usr/bin, /bin, /usr/local/bin or
#          /opt/homebrew/bin: `./tools/git` or `node_modules/.bin/cat` is denied, since a
#          repository under review can ship a binary by any name
#   sort   without -o or --compress-program;  uniq  with at most one operand;  rg  without
#          --pre
#   and    ls cat head tail wc grep egrep fgrep tr cut jq diff comm column nl echo printf
#          true false test [ date basename dirname realpath readlink pwd which type file
#          stat du cd
#
# Short options are read as clusters: the run of letters after a lone dash is checked for a
# forbidden letter, so `git branch -rd` is `-d` and `gh api -fbody=x` is `-f`. The price is
# that a harmless attached value which happens to contain such a letter is denied too.
#
# What it cannot see: a command the repository's own git configuration runs (a textconv
# filter, core.fsmonitor set in .git/config) -- that is the human's checkout, not the
# agent's doing.
#
# Needs jq and perl. Always exits 0; the decision is the JSON, and a hook that exits
# non-zero for a parse error would block every Bash call in the session. Without jq the
# caller cannot be identified and nothing is decided; without perl a read-only agent's
# command is denied rather than let through unread.

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

# Mask quoted strings length for length, drop the redirections that are allowed, refuse any
# other `>`, any expansion and any brace group, then split into simple commands and tokenize
# each from the raw text. One line per command, words separated by \x1f; the first line is
# OK, REDIRECT, EXPANSION or BRACE; a line that is a lone \x1e marks text the tokenizer could
# not account for.
read_commands() {
  GUARD_CMD=$cmd perl -e '
    my $raw = $ENV{GUARD_CMD};
    my $m = $raw;
    # A backslash escape outside quotes is consumed first, so `\x27` is a literal quote and
    # `\<newline>` a continuation, not the start of a string or a separator.
    $m =~ s/(\\.|"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)/ length($1) == 2 && substr($1,0,1) eq "\\" ? "QQ" : substr($1,0,1) . ("Q" x (length($1)-2)) . substr($1,0,1) /gse;
    $m =~ s/([0-9]*&?>>?[ \t]*\/dev\/null|[0-9]*>&[0-9]+)/ " " x length($1) /ge;
    if ($m =~ />/) { print "REDIRECT\n"; exit 0 }
    # Anything bash would expand into a word the checks never saw: a `$` outside single
    # quotes (a variable, `${...}`, `$\x27...\x27`), or a brace group outside quotes.
    # Same three-way walk as the mask above, so a quote of one kind inside the other is
    # text, not a delimiter; a double-quoted string keeps its content, since `$` expands
    # there, with only its backslash escapes masked.
    my $sq = $raw;
    $sq =~ s/(\\.|"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)/ my $t = $1; substr($t,0,1) eq q(") ? do { (my $u = $t) =~ s{\\.}{QQ}gs; $u } : ("Q" x length($t)) /gse;
    # A `$` expands only when a name, digit, brace, paren or special character follows,
    # or -- outside any quotes -- when it opens `$\x27...\x27` or `$"..."`; a trailing `$`
    # or one before `"`, `|` or `)` is a literal regex anchor.
    if ($m =~ /\$(?=[\x27"])/) { print "EXPANSION\n"; exit 0 }
    if ($sq =~ /\$(?=[A-Za-z0-9_{(@#?*!\$-])/) { print "EXPANSION\n"; exit 0 }
    if ($m =~ /\{[^{}\s]*(?:,|\.\.)[^{}\s]*\}/) { print "BRACE\n"; exit 0 }
    print "OK\n";
    my ($start, $len) = (0, length $m);
    for (my $i = 0; $i <= $len; $i++) {
      my $c = $i < $len ? substr($m, $i, 1) : "\n";
      next unless $c =~ /[\n;|&]/;
      my $seg = substr($raw, $start, $i - $start);
      $start = $i + 1;
      next unless $seg =~ /\S/;
      $seg =~ s/^\s*\(+//; $seg =~ s/\)+\s*$//;   # a subshell is its command
      $seg =~ s/\\\n//g;                           # a continued line is one line
      my @w;
      my $after_redirect = 0;
      pos($seg) = 0;
      while ($seg =~ /\G\s*((?:[^\s"\x27\\]|\\.|"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)+)/gc) {
        my $w = $1;
        # A redirection is an operator only when written bare; a quoted ">" is an argument.
        if ($w =~ /^[0-9]*(?:<<?<?|&?>>?)(?:\/dev\/null|&[0-9]+)?$/) { $after_redirect = ($w !~ /\/dev\/null|&[0-9]+$/); next }
        if ($after_redirect) { $after_redirect = 0; next }   # the file a bare `2>` or `<` names
        $w =~ s/"((?:[^"\\]|\\.)*)"|\x27([^\x27]*)\x27|\\(.)/defined $1 ? $1 : defined $2 ? $2 : $3/gse;
        $w =~ s/\n/ /g;
        push @w, $w;
      }
      my $rest = substr($seg, pos($seg) // 0);
      if ($rest =~ /\S/) { print "\x1e\n"; next }
      print join("\x1f", @w), "\n" if @w;
    }'
}

nonflags() { # words... -> count of words that are not flags; `--` ends the flags
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

# Short options cluster (`-sSo`) and take attached values (`-XPOST`, `-fbody=x`), so a flag
# is never just a word. cluster_has looks at the run of letters after a lone dash and says
# whether any of the given letters is in it; a caller that allows one attached form (`-XGET`)
# checks that word first and skips it.
cluster_has() { # letters words... -> 0 when a short-option word carries one of the letters
  local letters=$1 w run; shift
  for w in "$@"; do
    case $w in --*|-) continue ;; -*) ;; *) continue ;; esac
    run=${w#-}; run=${run%%[^A-Za-z]*}
    # shellcheck disable=SC2254
    case $run in *[$letters]*) return 0 ;; esac
  done
  return 1
}

pager_value_ok() { # value -> 0 when it is a pager git or gh may run
  case $1 in cat|less|more|true|false|'') return 0 ;; *) return 1 ;; esac
}

check_assignment() { # NAME=value
  local name=${1%%=*} value=${1#*=}
  case $name in
    GIT_PAGER|PAGER|GH_PAGER)
      pager_value_ok "$value" || deny "\`$name=$value\` would run that as a pager; use cat, or git --no-pager" ;;
    LANG|LC_*|TZ|TERM|COLUMNS|LINES|NO_COLOR|CLICOLOR|CLICOLOR_FORCE|FORCE_COLOR|GIT_TERMINAL_PROMPT|GIT_OPTIONAL_LOCKS|GH_NO_UPDATE_NOTIFIER|GH_FORCE_TTY|GIT_CONFIG_NOSYSTEM) ;;
    *) deny "setting \`$name\` is not allowed before a command" ;;
  esac
}

check_git_config() { # key=value from -c
  local key=${1%%=*} value=${1#*=}
  [ "$key" = "$1" ] && value=""
  local lkey; lkey=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  case $lkey in
    core.pager|pager.*)
      pager_value_ok "$value" || deny "\`git -c $1\` would run that as a pager; use cat, or --no-pager" ;;
    color.*|core.quotepath|core.abbrev|advice.*|log.abbrevcommit|log.date|log.decorate|diff.noprefix|diff.renames|diff.renamelimit|grep.linenumber|i18n.logoutputencoding|safe.directory) ;;
    *) deny "\`git -c $key\` is not on the read-only allowlist of config keys" ;;
  esac
}

check_git() { # words after `git`
  local -a w=("$@")
  local sub="" i=0
  while [ $i -lt ${#w[@]} ]; do
    case ${w[$i]} in
      -c) check_git_config "${w[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
      -c?*) check_git_config "${w[$i]#-c}"; i=$((i + 1)); continue ;;
      -C|--git-dir|--work-tree|--namespace) i=$((i + 2)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--no-pager|-P|--paginate|-p|--literal-pathspecs|--no-optional-locks|--no-replace-objects|--bare) i=$((i + 1)); continue ;;
      -*) deny "unknown git option \`${w[$i]}\` before the subcommand" ;;
      *) sub=${w[$i]}; i=$((i + 1)); break ;;
    esac
  done
  local -a rest=("${w[@]:$i}")
  has_flag '--output*' "${rest[@]+"${rest[@]}"}" && deny "\`git $sub --output\` writes a file"
  has_flag '--ext-diff' "${rest[@]+"${rest[@]}"}" && deny "\`git $sub --ext-diff\` runs the configured external diff"
  has_flag '--open-files-in-pager*' "${rest[@]+"${rest[@]}"}" && deny "\`git $sub --open-files-in-pager\` runs a program"
  has_flag '--upload-pack*' "${rest[@]+"${rest[@]}"}" && deny "\`git $sub --upload-pack\` runs a program"
  has_flag '--exec*' "${rest[@]+"${rest[@]}"}" && deny "\`git $sub --exec\` runs a program"
  has_flag '--config-env*' "${rest[@]+"${rest[@]}"}" && deny "\`git $sub --config-env\` injects configuration"
  case $sub in
    diff|log|show|rev-parse|blame|ls-files|ls-tree|ls-remote|cat-file|merge-base|rev-list|status|describe|shortlog|name-rev|for-each-ref|show-ref|count-objects|check-ignore) ;;
    fetch)
      # A fetch updates remote-tracking refs, which is fine; a refspec with a destination, or
      # a forcing or pruning flag, writes or deletes the checkout's own branches.
      if cluster_has fpPu "${rest[@]+"${rest[@]}"}" || has_flag '--force' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--prune*' "${rest[@]+"${rest[@]}"}" || has_flag '--update-head-ok' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--set-upstream' "${rest[@]+"${rest[@]}"}" || has_flag '--refmap*' "${rest[@]+"${rest[@]}"}"; then
        deny "\`git fetch\` with a flag that forces, prunes or rewrites refs"
      fi
      has_flag '--stdin' "${rest[@]+"${rest[@]}"}" && deny "\`git fetch --stdin\` reads refspecs the guard cannot see"
      local r
      for r in "${rest[@]+"${rest[@]}"}"; do
        case $r in -*) ;; *:*|+*) deny "\`git fetch\` with a refspec destination writes a local ref; fetch the remote and read origin/<branch>" ;; esac
      done ;;
    grep)
      cluster_has O "${rest[@]+"${rest[@]}"}" && deny "\`git grep -O\` runs a program" ;;
    symbolic-ref)
      if cluster_has dm "${rest[@]+"${rest[@]}"}" || has_flag '--delete' "${rest[@]+"${rest[@]}"}"; then
        deny "\`git symbolic-ref -d\` deletes a ref"
      fi
      [ "$(nonflags "${rest[@]+"${rest[@]}"}")" -le 1 ] || deny "\`git symbolic-ref\` with two refs writes one" ;;
    worktree)
      [ "${rest[0]:-}" = list ] || deny "\`git worktree ${rest[0]:-}\` changes worktrees; only \`list\` is allowed" ;;
    remote)
      case ${rest[0]:-} in ''|-v|--verbose|show|get-url) ;; *) deny "\`git remote ${rest[0]}\` changes remotes" ;; esac ;;
    branch)
      if cluster_has dDmMcCuf "${rest[@]+"${rest[@]}"}" \
         || has_flag '--delete' "${rest[@]+"${rest[@]}"}" || has_flag '--move' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--copy' "${rest[@]+"${rest[@]}"}" || has_flag '--force' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--set-upstream-to*' "${rest[@]+"${rest[@]}"}" || has_flag '--unset-upstream' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--edit-description' "${rest[@]+"${rest[@]}"}" || has_flag '--track' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--no-track' "${rest[@]+"${rest[@]}"}"; then
        deny "\`git branch\` with a flag that creates, moves or deletes a branch"
      fi
      # -v is verbosity, not list mode: `git branch -v new` creates `new`.
      if [ "$(nonflags "${rest[@]+"${rest[@]}"}")" -gt 0 ] \
         && ! { cluster_has arl "${rest[@]+"${rest[@]}"}" || has_flag '--list' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--merged' "${rest[@]+"${rest[@]}"}" || has_flag '--no-merged' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--contains' "${rest[@]+"${rest[@]}"}" || has_flag '--no-contains' "${rest[@]+"${rest[@]}"}" \
                || has_flag '--points-at' "${rest[@]+"${rest[@]}"}" || has_flag '--show-current' "${rest[@]+"${rest[@]}"}"; }; then
        deny "\`git branch <name>\` creates a branch; list with -a, -r, --list, --merged, --contains or --points-at"
      fi ;;
    tag)
      if cluster_has dasfFmu "${rest[@]+"${rest[@]}"}" \
         || has_flag '--delete' "${rest[@]+"${rest[@]}"}" || has_flag '--annotate' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--sign' "${rest[@]+"${rest[@]}"}" || has_flag '--force' "${rest[@]+"${rest[@]}"}" \
         || has_flag '--message*' "${rest[@]+"${rest[@]}"}" || has_flag '--file*' "${rest[@]+"${rest[@]}"}"; then
        deny "\`git tag\` with a flag that creates or deletes a tag"
      fi
      if [ "$(nonflags "${rest[@]+"${rest[@]}"}")" -gt 0 ] \
         && ! { cluster_has l "${rest[@]+"${rest[@]}"}" || has_flag '--list' "${rest[@]+"${rest[@]}"}" \
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
    local -a w=("$@") others=()
    local i=0
    while [ $i -lt ${#w[@]} ]; do
      case ${w[$i]} in
        -X|--method)
          case ${w[$((i + 1))]:-} in GET|get) ;; *) deny "\`gh api\` with a method other than GET" ;; esac
          i=$((i + 2)); continue ;;
        -XGET|-Xget|--method=GET|--method=get) ;;
        --method=*) deny "\`gh api\` with a method other than GET" ;;
        --field|--raw-field|--input|--field=*|--raw-field=*|--input=*)
          deny "\`gh api\` with a request body" ;;
        *) others+=("${w[$i]}") ;;
      esac
      i=$((i + 1))
    done
    cluster_has X "${others[@]+"${others[@]}"}" && deny "\`gh api\` with a method other than GET"
    cluster_has fF "${others[@]+"${others[@]}"}" && deny "\`gh api\` with a request body"
    return 0
  fi
  deny "\`gh $sub $act\` is not on the read-only allowlist"
}

check_segment() { # the words of one simple command, unquoted
  local -a words=("$@")
  # Leading NAME=value assignments and the harmless wrappers.
  while [ ${#words[@]} -gt 0 ]; do
    case ${words[0]} in
      [A-Za-z_]*=*) check_assignment "${words[0]}"; words=("${words[@]:1}") ;;
      time|nice|command) words=("${words[@]:1}") ;;
      *) break ;;
    esac
  done
  [ ${#words[@]} -gt 0 ] || return 0
  # A program named by path is allowed only under the system directories a repository under
  # review cannot write to; `./tools/git` or `node_modules/.bin/cat` would be its code.
  local prog=${words[0]}
  case $prog in
    */../*|*/..) deny "\`$prog\` climbs out of its directory with \`..\`" ;;
    /usr/bin/*|/bin/*|/usr/local/bin/*|/opt/homebrew/bin/*) prog=${prog##*/} ;;
    */*) deny "\`$prog\` names a program by path; use the bare name, or a path under /usr/bin, /bin, /usr/local/bin or /opt/homebrew/bin" ;;
  esac
  local -a rest=("${words[@]:1}")
  case $prog in
    git) check_git "${rest[@]+"${rest[@]}"}" ;;
    gh) check_gh "${rest[@]+"${rest[@]}"}" ;;
    sed|awk|gawk|mawk|nawk|curl|wget)
      deny "\`$prog\` is not allowed for a read-only agent; read files with the Read and Grep tools and pages with WebFetch" ;;
    find)
      has_flag '-delete' "${rest[@]+"${rest[@]}"}" && deny "\`find -delete\` deletes"
      has_flag '-exec*' "${rest[@]+"${rest[@]}"}" && deny "\`find -exec\` runs arbitrary commands"
      has_flag '-ok*' "${rest[@]+"${rest[@]}"}" && deny "\`find -ok\` runs arbitrary commands"
      has_flag '-fprint*' "${rest[@]+"${rest[@]}"}" && deny "\`find -fprint\` writes a file"
      has_flag '-fls' "${rest[@]+"${rest[@]}"}" && deny "\`find -fls\` writes a file" ;;
    sort)
      cluster_has o "${rest[@]+"${rest[@]}"}" && deny "\`sort -o\` writes a file"
      has_flag '--output*' "${rest[@]+"${rest[@]}"}" && deny "\`sort --output\` writes a file"
      has_flag '--compress-program*' "${rest[@]+"${rest[@]}"}" && deny "\`sort --compress-program\` runs a program" ;;
    uniq)
      [ "$(nonflags "${rest[@]+"${rest[@]}"}")" -le 1 ] || deny "\`uniq\` with two operands writes the second" ;;
    rg)
      has_flag '--pre*' "${rest[@]+"${rest[@]}"}" && deny "\`rg --pre\` runs a program on every file" ;;
    ls|cat|head|tail|wc|grep|egrep|fgrep|tr|cut|jq|diff|comm|column|nl|echo|printf|true|false|test|'['|date|basename|dirname|realpath|readlink|pwd|which|type|file|stat|du|cd) ;;
    *) deny "\`$prog\` is not on the read-only allowlist" ;;
  esac
  return 0
}

first=true
while IFS= read -r line; do
  if $first; then
    first=false
    case $line in
      OK) ;;
      REDIRECT) deny "redirecting output to a file is not allowed (only to /dev/null)" ;;
      EXPANSION) deny "a \$ outside single quotes would expand into text the guard cannot check; write the value out, or single-quote it" ;;
      BRACE) deny "a brace expansion would expand into text the guard cannot check; write the words out" ;;
      *) deny "the command could not be parsed" ;;
    esac
    continue
  fi
  [ "$line" = $'\x1e' ] && deny "part of the command could not be parsed (an unbalanced quote?)"
  IFS=$'\x1f' read -r -a words <<< "$line"
  check_segment "${words[@]}"
done < <(read_commands)

# The checker always prints a status line for a non-empty command, so silence means it did
# not run -- perl missing, or a crash -- and a read-only agent's command must not pass unread.
$first && deny "the command could not be checked (is perl installed?)"

exit 0
