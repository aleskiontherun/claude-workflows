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
# For those agents the command has to fit a small grammar, and every simple command in it
# has to pass. The grammar is what the checks can read without bash rewriting any of it:
#
#   - words made of letters, digits and `_ . / : @ = , + % ^ ~ -`, single-quoted strings,
#     and double-quoted strings that contain no `$` and no backtick (a backslash inside them
#     escapes the next character, as in bash); neither kind of string spans a line, and no
#     control character but tab appears anywhere, since the checks hand each simple
#     command's words on as a line of their own;
#   - an unquoted `~` only inside a word (`HEAD~1`), never at its start or after `=` or `:`,
#     where bash expands it before git sees the path;
#   - the separators `|`, `||`, `&&`, `;`, `&` and newline, which split it into simple
#     commands;
#   - the redirections `>/dev/null`, `2>/dev/null`, `&>/dev/null` and `2>&1`, and no other.
#
# Any other character outside quotes is denied with a reason: a `$` or backtick would
# expand or substitute, `<` and `>` redirect, `(` `)` `{` `}` group or define a function,
# `*` `?` `[` expand against the working directory, `#` opens a comment and `\` escapes --
# each a way for bash to run something other than the words the checks read. Quoting the
# character is the way through. A failing command denies the whole call -- a
# `permissionDecision` of `deny` on stdout, with the reason -- and nothing runs.
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
#   git    diff log show rev-list shortlog blame grep status rev-parse ls-files ls-tree
#          cat-file merge-base describe name-rev for-each-ref show-ref count-objects
#          check-ignore -- the subcommands whose every invocation reads -- each with the
#          options `check_git` lists for it. Not branch, tag, config, remote, symbolic-ref,
#          worktree, fetch or ls-remote, whose writing and reading forms differ by an operand
#          or an option; for-each-ref, rev-parse and show-ref list what those listed. Before
#          the subcommand: -C, -c with pager, color, abbreviation and locale keys (pager
#          values as above), --namespace, --no-pager, -P, -p, --literal-pathspecs,
#          --no-optional-locks, --no-replace-objects. Not --git-dir, --work-tree or --bare,
#          and not a -C into a bare repository: a repository under review can commit one
#          whose config names a program to run
#   gh     pr list|view|checks|diff|status; issue list|view; repo view; run list|view;
#          release list|view; auth status; api with no method other than GET and no body.
#          Never -w / --web, which opens a browser
#   sort   never -o, --output, --compress-program, -T or --temporary-directory
#   uniq   with at most one operand
#   never  sed, awk, curl, wget or file: each hides write or exec modes in its program,
#          format or options, and the agents have Read, Grep and WebFetch for what those did.
#          Nor find, rg, date, printf or cd: Glob and Grep do the first two, and the rest
#          carried a write or a move each
#   and    ls cat head tail wc grep egrep fgrep tr cut jq diff comm column nl echo
#          true false test basename dirname realpath readlink pwd which type stat du,
#          with any options: none of theirs writes a file or runs a program
#   and every command named bare or under /usr/bin, /bin, /usr/local/bin or
#          /opt/homebrew/bin: `./tools/git` or `node_modules/.bin/cat` is denied, since a
#          repository under review can ship a binary by any name
#
# Short options are read as clusters: `-avv` is `-a -v -v`, and a letter that takes a value
# takes the rest of its word (`-n5`, `-L10,20`) or, with nothing attached, the next word.
#
# What it cannot see: a command the configuration of the checkout git is run in runs (a
# textconv filter, core.fsmonitor set in its .git/config) -- that is the human's checkout,
# not the agent's doing. A diff cannot commit a `.git` entry, so the checkout's own config
# is not the diff's to write; the bare repository it can commit is what the -C rule is for.
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
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || hook_cwd=""
[ -n "$hook_cwd" ] || hook_cwd=$PWD

deny() { # reason
  jq -n --arg r "$agent is read-only: $1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Read the command against the grammar above and split it into simple commands. Prints one
# status line -- OK, or QUOTE for an unbalanced quote, EXPANSION for a `$` or backtick inside
# double quotes, CONTROL for a control character other than tab or newline, NEWLINE for a
# newline inside quotes, TILDE for a `~` bash would expand, CHAR <c> for the first character
# outside the grammar -- then, after OK, one line per simple command with its words,
# unquoted, separated by \x1f. The output framing is a newline per command and \x1f per
# word, which is why neither may occur inside a word.
read_commands() {
  GUARD_CMD=$cmd perl -e '
    my $raw = $ENV{GUARD_CMD};
    my $len = length $raw;
    if ($raw =~ /[\x00-\x08\x0b-\x1f\x7f]/) { print "CONTROL\n"; exit 0 }
    # Mask the quoted strings length for length, so that every position of the mask is the
    # same position of the raw text: a quote inside the other kind of quote is text, and
    # the only `$` or backtick a double-quoted string may hold is an escaped one.
    my $m = "";
    for (my $i = 0; $i < $len; ) {
      my $c = substr($raw, $i, 1);
      if ($c eq "\x27") {
        my $j = index($raw, "\x27", $i + 1);
        if ($j < 0) { print "QUOTE\n"; exit 0 }
        if (index(substr($raw, $i, $j - $i), "\n") >= 0) { print "NEWLINE\n"; exit 0 }
        $m .= "\x27" . ("Q" x ($j - $i - 1)) . "\x27"; $i = $j + 1; next;
      }
      if ($c eq q(")) {
        my $j = $i + 1;
        while ($j < $len) {
          my $d = substr($raw, $j, 1);
          if ($d eq "\\") { $j += 2; next }
          last if $d eq q(");
          if ($d eq "\$" || $d eq "`") { print "EXPANSION\n"; exit 0 }
          if ($d eq "\n") { print "NEWLINE\n"; exit 0 }
          $j++;
        }
        if ($j >= $len) { print "QUOTE\n"; exit 0 }
        $m .= q(") . ("Q" x ($j - $i - 1)) . q("); $i = $j + 1; next;
      }
      $m .= $c; $i++;
    }
    # The allowed redirections are whole words; blank them, then every `<`, `>` and `&`
    # left is outside the grammar, except the `&` of a separator.
    $m =~ s/(?<![^\s])([0-9]?&?>>?\s*\/dev\/null|2>&1)(?![^\s;|&])/ " " x length($1) /ge;
    (my $t = $m) =~ s/\|\||&&|[|;&\n]/ /g;
    if ($t =~ /([^A-Za-z0-9 \t_.\/:@=,+%^~\x27"Q-])/) { print "CHAR $1\n"; exit 0 }
    # bash expands a `~` that starts a word, or follows the `=` or a `:` of an assignment.
    if ($m =~ /(?:^|[\s;|&=:])~/) { print "TILDE\n"; exit 0 }
    print "OK\n";
    # Split on the separators; each piece of the mask is the same piece of the raw text, and
    # its words sit where the mask shows non-blank runs.
    my $start = 0;
    while ($m =~ /\|\||&&|[|;&\n]|\z/g) {
      my $end = $-[0];
      my $mseg = substr($m, $start, $end - $start);
      my $seg = substr($raw, $start, $end - $start);
      $start = $+[0];
      my @w;
      while ($mseg =~ /\S+/g) {
        my $w = substr($seg, $-[0], $+[0] - $-[0]);
        $w =~ s/\x27([^\x27]*)\x27|"((?:[^"\\]|\\.)*)"/ defined $1 ? $1 : do { (my $u = $2) =~ s{\\([\\"\$`\n])}{$1}gs; $u } /gse;
        push @w, $w;
      }
      print join("\x1f", @w), "\n" if @w;
      last if $end >= $len;
    }'
}

# ----------------------------------------------------------------- option lists
# walk_opts reads one program's words against its option lists and leaves the operands in
# OPERANDS and every option it saw, normalized (`-a`, `--list`), space-separated in SEEN.
# The lists are strings: FLAGS and VALUES hold short-option letters, without and with a
# value; OPTIONAL holds letters whose value is only ever attached (`-M90%`); LONGS and
# LONGVALS hold long-option names without their dashes, without and with a separate value.
# A listed long option takes `=value` either way. DIGITS allows `-<number>` (`git log -3`)
# and NEGATE any `--no-<name>`, which only ever switches something off; each is `yes` or
# `no`. `--` ends the options. Anything else that starts with a dash is denied: an unlisted
# option, any abbreviation of a listed one, a separate value that starts with a dash.
FLAGS="" VALUES="" OPTIONAL="" LONGS="" LONGVALS="" DIGITS=no NEGATE=no
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
      # A separate value shaped like an option -- `--word`, a dash and letters only, or a dash,
      # letters and `=value` -- is one: a tool whose option takes an optional argument reads
      # the next word as a new option, so the guard must too, and gh's parser reads `-w=1` as
      # `--web=true`. `-1`, `-label:x` or `-5,+3` are values.
      case $w in
        --[A-Za-z]*) deny "\`$label\` has an option value that looks like an option; write it as --option=value" ;;
        -[A-Za-z]*=*) deny "\`$label\` has an option value that looks like an option; write it as --option=value or put the dash in brackets" ;;
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

# Where git runs is the hook input's `cwd` moved by each -C. A diff cannot commit a `.git`
# entry, but it can commit a bare repository -- `HEAD` beside `objects/` -- whose config names
# a program to run, and git's discovery walks up from its directory until it meets one.
resolve_dir() { # dir base -> the canonical directory on stdout; 1 if it is not a directory
  local d=$1
  case $d in /*) ;; *) d=$2/$d ;; esac
  (cd -P -- "$d" 2>/dev/null && pwd -P)
}
reaches_bare_repo() { # canonical dir -> 0 if git's discovery from it meets a bare repository first
  local d=$1
  while :; do
    [ -e "$d/.git" ] && return 1
    [ -e "$d/HEAD" ] && [ -d "$d/objects" ] && return 0
    [ "$d" = / ] && return 1
    d=${d%/*}; [ -n "$d" ] || d=/
  done
}

check_git() { # words after `git`
  local -a w=("$@")
  local sub="" i=0 dir=$hook_cwd v new walk=yes
  while [ $i -lt ${#w[@]} ]; do
    case ${w[$i]} in
      -c) check_git_config "${w[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
      -c?*) check_git_config "${w[$i]#-c}"; i=$((i + 1)); continue ;;
      -C)
        # Each -C moves git, a relative one from where the previous left it. One that does
        # not resolve is git's own error, before it reads any config.
        v=${w[$((i + 1))]:-}
        if [ -n "$v" ]; then                      # git ignores an empty -C
          if new=$(resolve_dir "$v" "$dir"); then dir=$new; else walk=no; fi
        fi
        i=$((i + 2)); continue ;;
      --namespace) i=$((i + 2)); continue ;;
      --git-dir|--git-dir=*|--work-tree|--work-tree=*|--bare) deny "\`git ${w[$i]%%=*}\` points git at a repository of the command's choosing, whose config can run a program; use -C on a checkout" ;;
      --namespace=*|--no-pager|-P|--paginate|-p|--literal-pathspecs|--no-optional-locks|--no-replace-objects) i=$((i + 1)); continue ;;
      -*) deny "unknown git option \`${w[$i]}\` before the subcommand" ;;
      *) sub=${w[$i]}; i=$((i + 1)); break ;;
    esac
  done
  if [ $walk = yes ] && reaches_bare_repo "$dir"; then
    deny "git would run in a bare repository ($dir), whose config can run a program; use -C on a checkout"
  fi
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
      lists 'dsq' '' '' 'head heads branches tags dereference hash verify exists abbrev quiet exclude-existing' '' ;;
    count-objects)
      lists 'vH' '' '' 'verbose human-readable' '' ;;
    check-ignore)
      lists 'qvzn' '' '' 'quiet verbose stdin non-matching no-index' '' ;;
    branch|tag)
      deny "\`git $sub\` creates as readily as it lists; list with \`for-each-ref refs/heads/\` or \`refs/tags/\`, or \`rev-parse --abbrev-ref HEAD\` for the current branch" ;;
    config|remote)
      deny "\`git $sub\` writes as readily as it reads; Read .git/config instead" ;;
    fetch|ls-remote)
      deny "\`git $sub\` talks to the remote and writes refs; the skill that spawned you fetched before the round" ;;
    '') deny "\`git\` with no subcommand" ;;
    *) deny "\`git $sub\` is not on the read-only allowlist" ;;
  esac
  walk_opts "git $sub" "${rest[@]+"${rest[@]}"}"
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
  NEGATE=no
  case $prog in
    git) check_git "${rest[@]+"${rest[@]}"}" ;;
    gh) check_gh "${rest[@]+"${rest[@]}"}" ;;
    sed|awk|gawk|mawk|nawk|curl|wget|file)
      deny "\`$prog\` is not allowed for a read-only agent; read files with the Read and Grep tools and pages with WebFetch" ;;
    find|rg)
      deny "\`$prog\` is not allowed for a read-only agent; use the Glob and Grep tools" ;;
    cd)
      deny "\`cd\` is not allowed for a read-only agent; use \`git -C <dir>\` or a path" ;;
    sort)
      # Not -o / --output, --compress-program, or -T / --temporary-directory.
      lists 'bdfghiMnrRsuVzcCm' 'ktS' '' 'ignore-leading-blanks dictionary-order ignore-case general-numeric-sort human-numeric-sort ignore-nonprinting month-sort numeric-sort random-sort reverse version-sort stable unique zero-terminated check merge debug help version' 'key field-separator buffer-size batch-size parallel files0-from'
      walk_opts sort "${rest[@]+"${rest[@]}"}" ;;
    uniq)
      lists 'cdDiuz' 'fsw' '' 'count repeated all-repeated ignore-case unique zero-terminated group help version' 'skip-fields skip-chars check-chars'
      walk_opts uniq "${rest[@]+"${rest[@]}"}"
      [ ${#OPERANDS[@]} -le 1 ] || deny "\`uniq\` with two operands writes the second" ;;
    ls|cat|head|tail|wc|grep|egrep|fgrep|tr|cut|jq|diff|comm|column|nl|echo|true|false|test|basename|dirname|realpath|readlink|pwd|which|type|stat|du) ;;
    '') deny "an empty command name" ;;
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
      QUOTE) deny "a quote is not closed" ;;
      EXPANSION) deny "a \$ or backtick inside double quotes would expand or substitute; single-quote it" ;;
      CONTROL) deny "a control character is not allowed; write the command with printable characters and tabs" ;;
      NEWLINE) deny "a quoted string spans lines; keep each word on one line (a git format takes %n)" ;;
      TILDE) deny "an unquoted ~ at the start of a word, or after = or :, is expanded by bash; write the path out, or quote the ~" ;;
      'CHAR $'|'CHAR `') deny "a \$ or backtick outside quotes would expand or substitute; write the value out, or single-quote it" ;;
      'CHAR <'|'CHAR >') deny "redirecting to or from a file is not allowed (only >/dev/null, 2>/dev/null, &>/dev/null and 2>&1)" ;;
      'CHAR ('|'CHAR )'|'CHAR {'|'CHAR }') deny "a subshell, group, brace expansion or function definition is not allowed; write the commands out, joined by && or |" ;;
      'CHAR *'|'CHAR ?'|'CHAR [') deny "an unquoted *, ? or [ would be expanded against the working directory; quote the pattern (and use test, not [)" ;;
      'CHAR #') deny "a # comment is not allowed; drop it" ;;
      "CHAR \\") deny "a backslash outside quotes is not allowed; quote the word instead, and keep the command on one line" ;;
      'CHAR '*) deny "the character \`${line#CHAR }\` is not allowed outside quotes; quote it" ;;
      *) deny "the command could not be parsed" ;;
    esac
    continue
  fi
  IFS=$'\x1f' read -r -a words <<< "$line"
  check_segment "${words[@]+"${words[@]}"}"   # guarded: bash 3.2 calls an empty array unbound
done < <(read_commands)

# The checker always prints a status line for a non-empty command, so silence means it did
# not run -- perl missing, or a crash -- and a read-only agent's command must not pass unread.
$first && deny "the command could not be checked (is perl installed?)"

exit 0
