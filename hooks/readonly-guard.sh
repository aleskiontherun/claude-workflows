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
# command are then taken from the unmasked text. A redirection to anywhere but /dev/null, a
# `$(...)` or backtick substitution, a process substitution, any other `$` outside single
# quotes, a brace expansion, an unquoted glob, a parenthesis other than a subshell around a
# whole command, or text the tokenizer can't account for is denied outright -- the checks
# read words as written, and bash must not get to rewrite them or define functions behind
# them. A failing command denies the whole call -- a `permissionDecision` of `deny` on
# stdout, with the reason -- and nothing runs.
#
# Every check is an allowlist, and options match exactly. A program is allowed by name, and
# where any option of its could write a file, change a ref or run a program, each option word
# it is given has to be on that program's list in the code below. An unlisted option is
# denied; so is any abbreviation of a listed one, since git, sort and their kin accept
# abbreviations and the lists name only the full spelling; and so is a separate value that
# starts with a dash, unless it is attached (`--sort=-committerdate`, `-L10,20`) or comes
# after `--`. A listed long option takes a `=value`; one that takes a separate value consumes
# the next word, which is then not an operand. git additionally takes any `--no-<option>`,
# which only ever switches something off.
#
#   NAME=value  before a command: only pager, locale and terminal variables; a pager's value
#               must be cat, less, more, true or false
#   git    diff log show rev-parse blame grep ls-files ls-tree ls-remote cat-file merge-base
#          rev-list status describe shortlog name-rev for-each-ref show-ref count-objects
#          check-ignore fetch symbolic-ref, `worktree list`, `remote` on its own or with -v,
#          show or get-url, and the listing forms of branch, tag and config -- each with the
#          options `check_git` lists for it. `fetch` also refuses any refspec with a
#          destination or a `+`; `branch` and `tag` take an operand only with a listing
#          option; `symbolic-ref` takes at most one ref; `config` needs a --get*, --list or
#          -l option, or the `get` or `list` subcommand. Before the subcommand: -C, -c with
#          pager, color, abbreviation and locale keys (pager values as above), --git-dir,
#          --work-tree, --namespace, --no-pager, -P, -p, --literal-pathspecs,
#          --no-optional-locks, --no-replace-objects, --bare
#   gh     pr list|view|checks|diff|status; issue list|view; repo view; run list|view;
#          release list|view; auth status; api with no method other than GET and no body.
#          Never -w / --web, which opens a browser
#   find   with its tests and the actions that only print: never -delete, -exec, -execdir,
#          -ok, -okdir, -fls, -fprint, -fprint0 or -fprintf
#   sort   never -o, --output, --compress-program, -T or --temporary-directory
#   uniq   with at most one operand;  rg  never --pre, --pre-glob or --hostname-bin
#   date   in its printing forms, never -s or --set
#   never  sed, awk, curl, wget or file: each hides write or exec modes in its program,
#          format or options, and the agents have Read, Grep and WebFetch for what those did
#   and    ls cat head tail wc grep egrep fgrep tr cut jq diff comm column nl echo printf
#          true false test [ basename dirname realpath readlink pwd which type stat du cd,
#          with any options: none of theirs writes a file or runs a program
#   and every command named bare or under /usr/bin, /bin, /usr/local/bin or
#          /opt/homebrew/bin: `./tools/git` or `node_modules/.bin/cat` is denied, since a
#          repository under review can ship a binary by any name
#
# Short options are read as clusters: `-avv` is `-a -v -v`, and a letter that takes a value
# takes the rest of its word (`-n5`, `-L10,20`) or, with nothing attached, the next word.
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
# other `>`, any expansion, any brace group and any unquoted glob, then split into simple
# commands and tokenize each from the raw text. One line per command, words separated by
# \x1f; the first line is OK, REDIRECT, EXPANSION, BRACE or GLOB; a line that is a lone \x1e
# marks text the tokenizer could not account for, and a lone \x1d a parenthesis that is not a
# subshell wrapper.
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
    # An unquoted glob is expanded against the working directory, where a repository under
    # review can plant a file named `-exec`; `[` and `]` on their own are the test command.
    for my $w (split /\s+/, $m) {
      next if $w eq "[" || $w eq "]";
      if ($w =~ /[*?\[]/) { print "GLOB\n"; exit 0 }
    }
    print "OK\n";
    my ($start, $len) = (0, length $m);
    for (my $i = 0; $i <= $len; $i++) {
      my $c = $i < $len ? substr($m, $i, 1) : "\n";
      next unless $c =~ /[\n;|&]/;
      my $seg = substr($raw, $start, $i - $start);
      my $mseg = substr($m, $start, $i - $start);
      $start = $i + 1;
      next unless $seg =~ /\S/;
      # A subshell is its command. The parens to strip are the ones the masked text shows
      # bare -- an escaped `\)` is QQ there -- and masking is length-preserving, so the same
      # positions come off the raw text.
      if ($mseg =~ /^(\s*\(+)/)  { my $n = length $1; substr($seg, 0, $n) = ""; substr($mseg, 0, $n) = "" }
      if ($mseg =~ /(\)+\s*)$/)  { my $n = length $1; substr($seg, -$n) = "";  substr($mseg, -$n) = "" }
      # Any other parenthesis is a function definition, a case pattern or arithmetic --
      # grammar the checks do not read.
      if ($mseg =~ /[()]/) { print "\x1d\n"; next }
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

# ----------------------------------------------------------------- option lists
# walk_opts reads one program's words against its option lists and leaves the operands in
# OPERANDS and every option it saw, normalized (`-a`, `--list`), space-separated in SEEN.
# The lists are strings: FLAGS and VALUES hold short-option letters, without and with a
# value; OPTIONAL holds letters whose value is only ever attached (`-M90%`); LONGS and
# LONGVALS hold long-option names without their dashes, without and with a separate value.
# A listed long option takes `=value` either way. DIGITS allows `-<number>` (`git log -3`),
# NEGATE allows any `--no-<name>`, which only ever switches something off, and NUMERIC
# allows a bare `-<number>...` word as a value (`find -mtime -1`); each is `yes` or `no`.
# `--` ends the options. Anything else that starts with a dash is denied: an unlisted
# option, any abbreviation of a listed one, a separate value that starts with a dash.
FLAGS="" VALUES="" OPTIONAL="" LONGS="" LONGVALS="" DIGITS=no NEGATE=no NUMERIC=no
OPERANDS=()
SEEN=""
lists() { # flags values optional longs longvals [digits]
  FLAGS=$1 VALUES=$2 OPTIONAL=$3 LONGS=${4//$'\n'/ } LONGVALS=${5//$'\n'/ } DIGITS=${6:-no}
}
walk_opts() { # label words...
  local label=$1; shift
  local w c run name need_value=""
  OPERANDS=(); SEEN=""
  while [ $# -gt 0 ]; do
    w=$1; shift
    if [ -n "$need_value" ]; then
      need_value=""
      # A separate value shaped like an option -- `--word`, or a dash and letters only -- is
      # one: a tool whose option takes an optional argument reads the next word as a new
      # option, so the guard must too. `-1`, `-label:x` or `-5,+3` are values.
      case $w in
        --[A-Za-z]*) deny "\`$label\` has an option value that looks like an option; write it as --option=value" ;;
        -[A-Za-z]*) [ -n "${w//[-A-Za-z]/}" ] || deny "\`$label\` has an option value that looks like an option; write it as --option=value or put the dash in brackets" ;;
      esac
      continue
    fi
    case $w in
      --) OPERANDS+=("$@"); return 0 ;;
      --*)
        name=${w#--}
        case $name in *=*) name=${name%%=*} ;; esac
        [ -n "$name" ] || deny "\`$label $w\` is not an option"
        case " $LONGS " in *" $name "*) SEEN="$SEEN --$name"; continue ;; esac
        case " $LONGVALS " in
          *" $name "*) SEEN="$SEEN --$name"; case $w in *=*) ;; *) need_value=1 ;; esac; continue ;;
        esac
        if [ "$NEGATE" = yes ]; then case $name in no-?*) SEEN="$SEEN --$name"; continue ;; esac; fi
        deny "\`$label --$name\` is not on the read-only allowlist of options" ;;
      -?*)
        run=${w#-}
        case $run in
          [0-9]*)
            if [ "$DIGITS" = yes ] && [ -z "${run//[0-9]/}" ]; then SEEN="$SEEN -$run"; continue; fi
            if [ "$NUMERIC" = yes ]; then OPERANDS+=("$w"); continue; fi
            deny "\`$label $w\` is not on the read-only allowlist of options" ;;
        esac
        while [ -n "$run" ]; do
          c=${run:0:1}; run=${run:1}
          case $FLAGS in *"$c"*) SEEN="$SEEN -$c"; continue ;; esac
          case $VALUES in *"$c"*) SEEN="$SEEN -$c"; [ -n "$run" ] || need_value=1; break ;; esac
          case $OPTIONAL in *"$c"*) SEEN="$SEEN -$c"; break ;; esac
          deny "\`$label -$c\` is not on the read-only allowlist of options"
        done ;;
      *) OPERANDS+=("$w") ;;
    esac
  done
  [ -z "$need_value" ] || deny "\`$label\` ends with an option that needs a value"
  return 0
}

seen() { # option -> 0 when walk_opts saw it
  case " $SEEN " in *" $1 "*) return 0 ;; *) return 1 ;; esac
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

# The diff options, shared by every subcommand that can print a patch. Not --output, which
# writes a file, --ext-diff, which runs the configured external diff, --show-signature, which
# runs gpg, or -O / --open-files-in-pager.
DIFF_FLAGS='pusabwWzRtrDc'
DIFF_VALUES='lISG'
DIFF_OPTIONAL='MCBXU'   # -U takes its number attached; a bare -U is followed by a new option
DIFF_LONGS='stat numstat shortstat name-only name-status summary patch no-patch raw patch-with-raw
  patch-with-stat compact-summary dirstat dirstat-by-file cumulative unified function-context
  minimal patience histogram indent-heuristic full-index abbrev binary text color color-moved
  color-moved-ws color-words word-diff ignore-all-space ignore-space-change ignore-space-at-eol
  ignore-cr-at-eol ignore-blank-lines find-renames find-copies find-copies-harder break-rewrites
  irreversible-delete pickaxe-all pickaxe-regex relative default-prefix submodule ignore-submodules
  textconv exit-code quiet check stat-width stat-name-width stat-count stat-graph-width
  rename-empty ita-invisible-in-index combined-all-paths cc dd diff-merges remerge-diff'
DIFF_LONGVALS='diff-algorithm anchored inter-hunk-context word-diff-regex ignore-matching-lines
  diff-filter find-object src-prefix dst-prefix line-prefix ws-error-highlight rotate-to skip-to
  output-indicator-new output-indicator-old output-indicator-context'
# The revision-walking options of log, show, rev-list and shortlog.
LOG_FLAGS='iEFPgmct'
LOG_VALUES='nL'
LOG_LONGS='all-match invert-grep regexp-ignore-case basic-regexp extended-regexp fixed-strings
  perl-regexp merges no-merges first-parent exclude-first-parent-only not all branches tags
  remotes exclude-hidden reflog alternate-refs single-worktree ignore-missing cherry-mark
  cherry-pick left-only right-only cherry walk-reflogs merge boundary simplify-by-decoration
  show-pulls full-history dense sparse simplify-merges ancestry-path date-order
  author-date-order topo-order reverse no-walk do-walk abbrev-commit no-abbrev-commit oneline
  expand-tabs no-expand-tabs notes no-notes show-notes standard-notes relative-date parents
  children left-right graph count objects objects-edge indexed-objects unpacked
  in-commit-order object-names no-object-names filter-print-omitted exclude-promisor-objects
  disk-usage use-bitmap-index progress header timestamp decorate clear-decorations source
  use-mailmap mailmap follow log-size full-diff bisect stdin since-as-filter
  pretty show-linear-break'
LOG_LONGVALS='max-count skip since after until before author committer grep grep-reflog
  min-parents max-parents glob exclude format encoding date
  decorate-refs decorate-refs-exclude filter missing max-age min-age default'

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
  NEGATE=yes
  case $sub in
    diff)
      lists "$DIFF_FLAGS" "$DIFF_VALUES" "$DIFF_OPTIONAL" "$DIFF_LONGS base ours theirs cached staged merge-base no-index" "$DIFF_LONGVALS" yes ;;
    log|show|rev-list)
      lists "$DIFF_FLAGS$LOG_FLAGS" "$DIFF_VALUES$LOG_VALUES" "$DIFF_OPTIONAL" "$DIFF_LONGS $LOG_LONGS" "$DIFF_LONGVALS $LOG_LONGVALS" yes ;;
    shortlog)
      lists "${LOG_FLAGS}sne" "$LOG_VALUES" "" "$LOG_LONGS summary numbered email committer group" "$LOG_LONGVALS" yes ;;
    blame)
      lists 'btsenplcfw' 'LS' 'MC' 'root show-stats porcelain line-porcelain incremental progress color-lines color-by-age minimal show-email show-name show-number first-parent abbrev' 'contents date ignore-rev ignore-revs-file since encoding reverse' ;;
    grep)
      lists 'aiIrwvhHEGPFnlLzocpqW' 'efABCm' '' 'cached no-index untracked no-exclude-standard exclude-standard recurse-submodules text ignore-case textconv no-textconv recursive word-regexp invert-match full-name extended-regexp basic-regexp perl-regexp fixed-strings line-number column files-with-matches name-only files-without-match null only-matching count color no-color break heading show-function function-context and or not all-match quiet' 'max-depth after-context before-context context threads max-count' ;;
    status)
      lists 'sbvz' '' 'u' 'short branch show-stash porcelain long verbose untracked-files ignore-submodules ignored column no-column ahead-behind renames no-renames find-renames no-lock-index' '' ;;
    rev-parse)
      lists 'q' '' '' 'verify short abbrev-ref symbolic symbolic-full-name quiet revs-only no-revs flags no-flags sq sq-quote not all branches tags remotes glob exclude show-toplevel show-prefix show-cdup show-superproject-working-tree git-dir git-common-dir is-inside-git-dir is-inside-work-tree is-bare-repository is-shallow-repository absolute-git-dir shared-index-path show-object-format show-ref-format local-env-vars since until after before' 'default prefix disambiguate git-path resolve-git-dir path-format' ;;
    ls-files)
      lists 'cdoisztvfmku' 'xX' '' 'cached deleted others ignored stage directory no-empty-directory unmerged killed modified exclude-standard error-unmatch full-name recurse-submodules abbrev debug deduplicate eol sparse' 'exclude exclude-from exclude-per-directory with-tree format' ;;
    ls-tree)
      lists 'drtlz' '' '' 'long name-only name-status object-only full-name full-tree abbrev' 'format' ;;
    ls-remote)
      lists 'htq' '' '' 'heads tags refs quiet exit-code get-url symref branches' 'sort' ;;
    cat-file)
      lists 'tsepz' '' '' 'textconv filters batch batch-check batch-command batch-all-objects buffer follow-symlinks unordered allow-unknown-type' 'path' ;;
    merge-base)
      lists 'a' '' '' 'all octopus independent is-ancestor fork-point' '' ;;
    describe)
      lists '' '' '' 'dirty broken all tags contains abbrev exact-match debug long always first-parent' 'candidates match exclude' ;;
    name-rev)
      lists '' '' '' 'tags all annotate-stdin stdin name-only no-undefined always' 'refs exclude' ;;
    for-each-ref)
      lists '' '' '' 'shell perl python tcl color ignore-case omit-empty include-root-refs stdin' 'count sort format points-at merged no-merged contains no-contains exclude' ;;
    show-ref)
      lists 'dsq' '' '' 'head branches tags dereference hash verify exists abbrev quiet exclude-existing' '' ;;
    count-objects)
      lists 'vH' '' '' 'verbose human-readable' '' ;;
    check-ignore)
      lists 'qvzn' '' '' 'quiet verbose stdin non-matching no-index' '' ;;
    fetch)
      # A fetch updates remote-tracking refs, which is fine. Not a forcing, pruning or upstream
      # option, not --stdin, --upload-pack or anything that runs maintenance; not --depth,
      # --deepen or --shallow-*, which turn the human's full clone into a shallow one, nor
      # --filter, which turns it into a partial one; and no refspec with a destination or a
      # `+`, which writes or deletes the checkout's own branches.
      lists 'qvtnk46' 'j' '' 'quiet verbose all tags dry-run no-tags recurse-submodules no-recurse-submodules progress no-progress atomic porcelain ipv4 ipv6 keep multiple prefetch' 'jobs negotiation-tip' ;;
    symbolic-ref)
      lists 'q' '' '' 'quiet short recurse no-recurse' '' ;;
    worktree)
      [ "${rest[0]:-}" = list ] || deny "\`git worktree ${rest[0]:-}\` changes worktrees; only \`list\` is allowed"
      rest=("${rest[@]:1}")
      lists 'vz' '' '' 'porcelain verbose' 'expire' ;;
    remote)
      case ${rest[0]:-} in
        ''|-v|--verbose) [ ${#rest[@]} -le 1 ] || deny "\`git remote\` lists remotes only on its own or with -v"; return 0 ;;
        show) rest=("${rest[@]:1}"); lists 'n' '' '' '' '' ;;
        get-url) rest=("${rest[@]:1}"); lists '' '' '' 'push all' '' ;;
        *) deny "\`git remote ${rest[0]}\` changes remotes" ;;
      esac ;;
    branch)
      lists 'arvliq' '' '' 'all remotes verbose list merged no-merged contains no-contains points-at show-current sort format color no-color ignore-case column no-column abbrev no-abbrev quiet' '' ;;
    tag)
      lists 'li' '' 'n' 'list contains no-contains merged no-merged points-at sort format color ignore-case column no-column' '' ;;
    config)
      lists 'lz' 'f' '' 'get get-all get-regexp get-urlmatch get-color get-colorbool list show-origin show-scope name-only null includes no-includes global system local worktree bool int bool-or-int path expiry-date fixed-value all regexp value' 'file blob default type' ;;
    '') deny "\`git\` with no subcommand" ;;
    *) deny "\`git $sub\` is not on the read-only allowlist" ;;
  esac
  walk_opts "git $sub" "${rest[@]+"${rest[@]}"}"
  case $sub in
    fetch)
      local r
      for r in "${OPERANDS[@]+"${OPERANDS[@]}"}"; do
        case $r in *:*|+*) deny "\`git fetch\` with a refspec destination writes a local ref; fetch the remote and read origin/<branch>" ;; esac
      done ;;
    symbolic-ref)
      [ ${#OPERANDS[@]} -le 1 ] || deny "\`git symbolic-ref\` with two refs writes one" ;;
    branch)
      # -v is verbosity, not list mode: `git branch -v new` creates `new`.
      if [ ${#OPERANDS[@]} -gt 0 ] && ! { seen -a || seen -r || seen -l || seen --all || seen --remotes || seen --list \
           || seen --merged || seen --no-merged || seen --contains || seen --no-contains || seen --points-at || seen --show-current; }; then
        deny "\`git branch <name>\` creates a branch; list with -a, -r, --list, --merged, --contains or --points-at"
      fi ;;
    tag)
      if [ ${#OPERANDS[@]} -gt 0 ] && ! { seen -l || seen -n || seen --list || seen --contains || seen --no-contains \
           || seen --merged || seen --no-merged || seen --points-at; }; then
        deny "\`git tag <name>\` creates a tag; list with -l, --list, --contains or --points-at"
      fi ;;
    config)
      # A read form is required: `git config <key>` alone reads, but `git config <key> <value>`
      # writes, and the two differ only in operand count.
      seen --get || seen --get-all || seen --get-regexp || seen --get-urlmatch || seen --get-color || seen --get-colorbool \
        || seen --list || seen -l || [ "${OPERANDS[0]:-}" = get ] || [ "${OPERANDS[0]:-}" = list ] \
        || deny "\`git config\` only in a read form: --get, --get-all, --get-regexp, --list, -l, or the get and list subcommands" ;;
  esac
  return 0
}

check_gh() { # words after `gh`
  local sub=${1:-} act=${2:-}
  local -a rest=()
  [ $# -ge 2 ] && rest=("${@:3}")
  NEGATE=no
  case "$sub $act" in
    'auth status')
      # Its own list: -t / --show-token prints the account's token, and -c is not an option here.
      lists 'a' 'h' '' 'active help' 'hostname'
      walk_opts "gh auth status" "${rest[@]+"${rest[@]}"}"
      return 0 ;;
    'pr list'|'pr view'|'pr checks'|'pr diff'|'pr status'|'issue list'|'issue view'|'repo view'|'run list'|'run view'|'release list'|'release view')
      # Not -w / --web, which opens a browser.
      lists 'vdi' 'RLsaABHlSqtjbeumc' '' 'draft comments required fail-fast watch log log-failed exit-status verbose patch name-only help' 'json jq template limit state assignee author base head label search app milestone mention order sort interval job branch workflow event status user commit repo color'
      walk_opts "gh $sub $act" "${rest[@]+"${rest[@]}"}"
      return 0 ;;
    'api '*)
      shift
      local -a w=("$@")
      local i=0
      while [ $i -lt ${#w[@]} ]; do
        case ${w[$i]} in
          -X|--method)
            case ${w[$((i + 1))]:-} in GET|get) ;; *) deny "\`gh api\` with a method other than GET" ;; esac
            i=$((i + 2)); continue ;;
          -XGET|-Xget|--method=GET|--method=get) ;;
          --method=*|-X*|-[!-]*X*) deny "\`gh api\` with a method other than GET" ;;
        esac
        i=$((i + 1))
      done
      # Not -f, -F, --field, --raw-field or --input, which send a body.
      lists 'i' 'XHqtp' '' 'paginate slurp include silent verbose help' 'method header jq template hostname cache preview'
      walk_opts "gh api" "${w[@]+"${w[@]}"}"
      return 0 ;;
  esac
  deny "\`gh $sub $act\` is not on the read-only allowlist"
}

# find's tests and the actions that only print. Not -delete, -exec, -execdir, -ok, -okdir,
# -fls, -fprint, -fprint0 or -fprintf. A numeric word (`-mtime -1`) is a value.
FIND_WORDS='-name -iname -path -ipath -wholename -iwholename -regex -iregex -lname -ilname -type
  -xtype -maxdepth -mindepth -depth -mtime -mmin -atime -amin -ctime -cmin -newer -anewer -cnewer
  -newermt -newerct -newerat -newermm -newerBm -newerBt -size -empty -not -o -or -a -and -prune
  -print -print0 -printf -ls -true -false -perm -user -group -uid -gid -nouser -nogroup -links
  -inum -samefile -readable -writable -executable -xdev -mount -follow -L -H -P -E -s -x -d -f
  -quit -regextype -daystart -noleaf -ignore_readdir_race -noignore_readdir_race -fstype -used
  -flags -acl -Bmin -Btime -Bnewer -mnewer'
check_find() { # words after `find`
  local w
  for w in "$@"; do
    case $w in
      -[0-9]*|+[0-9]*) ;;
      -*) case " ${FIND_WORDS//$'\n'/ } " in *" $w "*) ;; *) deny "\`find $w\` is not on the read-only allowlist of find tests and actions" ;; esac ;;
    esac
  done
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
  NEGATE=no NUMERIC=no
  case $prog in
    git) check_git "${rest[@]+"${rest[@]}"}" ;;
    gh) check_gh "${rest[@]+"${rest[@]}"}" ;;
    sed|awk|gawk|mawk|nawk|curl|wget|file)
      deny "\`$prog\` is not allowed for a read-only agent; read files with the Read and Grep tools and pages with WebFetch" ;;
    find) check_find "${rest[@]+"${rest[@]}"}" ;;
    sort)
      # Not -o / --output, --compress-program, or -T / --temporary-directory.
      lists 'bdfghiMnrRsuVzcCm' 'ktS' '' 'ignore-leading-blanks dictionary-order ignore-case general-numeric-sort human-numeric-sort ignore-nonprinting month-sort numeric-sort random-sort reverse version-sort stable unique zero-terminated check merge debug help version' 'key field-separator buffer-size batch-size parallel files0-from'
      walk_opts sort "${rest[@]+"${rest[@]}"}" ;;
    uniq)
      lists 'cdDiuz' 'fsw' '' 'count repeated all-repeated ignore-case unique zero-terminated group help version' 'skip-fields skip-chars check-chars'
      walk_opts uniq "${rest[@]+"${rest[@]}"}"
      [ ${#OPERANDS[@]} -le 1 ] || deny "\`uniq\` with two operands writes the second" ;;
    rg)
      # Not --pre, --pre-glob or --hostname-bin, which run a program.
      lists 'nNiSsvwxlcHhoqFPUzaLu0' 'efgtTmMrdABCjE' '' 'line-number no-line-number ignore-case smart-case case-sensitive invert-match word-regexp line-regexp files-with-matches files-without-match count count-matches no-filename with-filename only-matching quiet fixed-strings pcre2 multiline multiline-dotall search-zip text follow type-list max-count-only no-max-count include-zero color heading no-heading json vimgrep column no-column byte-offset null null-data files hidden no-ignore no-ignore-vcs no-ignore-global no-ignore-parent no-ignore-dot no-ignore-files no-messages no-config debug trace stats trim passthru one-file-system line-buffered block-buffered unrestricted crlf mmap no-mmap no-unicode no-require-git no-search-zip sort-files auto-hybrid-regex no-pcre2-unicode no-context-separator version help' 'glob iglob type type-not type-add max-count max-columns max-depth max-filesize after-context before-context context context-separator colors encoding engine regexp file replace sort sortr threads ignore-file dfa-size-limit regex-size-limit field-context-separator field-match-separator path-separator'
      walk_opts rg "${rest[@]+"${rest[@]}"}" ;;
    date)
      # Printing forms only: not -s / --set.
      lists 'uRj' 'dvrf' 'I' 'utc universal iso-8601 rfc-3339 rfc-email debug help version' 'date reference file'
      walk_opts date "${rest[@]+"${rest[@]}"}" ;;
    ls|cat|head|tail|wc|grep|egrep|fgrep|tr|cut|jq|diff|comm|column|nl|echo|printf|true|false|test|'['|basename|dirname|realpath|readlink|pwd|which|type|stat|du|cd) ;;
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
      GLOB) deny "an unquoted *, ? or [ would be expanded against the working directory; quote the pattern" ;;
      *) deny "the command could not be parsed" ;;
    esac
    continue
  fi
  [ "$line" = $'\x1e' ] && deny "part of the command could not be parsed (an unbalanced quote?)"
  [ "$line" = $'\x1d' ] && deny "parentheses other than a subshell around a whole command are not allowed (a function definition?)"
  IFS=$'\x1f' read -r -a words <<< "$line"
  check_segment "${words[@]+"${words[@]}"}"   # guarded: bash 3.2 calls an empty array unbound
done < <(read_commands)

# The checker always prints a status line for a non-empty command, so silence means it did
# not run -- perl missing, or a crash -- and a read-only agent's command must not pass unread.
$first && deny "the command could not be checked (is perl installed?)"

exit 0
