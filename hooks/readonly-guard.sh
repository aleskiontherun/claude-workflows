#!/usr/bin/env bash
# PreToolUse hook that keeps ontherun's read-only agents from changing what they judge.
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
# It is a guardrail, not a sandbox. The agents it guards are cooperative; what it exists
# for is a reviewer that runs the tests, stashes or checks out to look at something, stages
# a file or formats one "to confirm", and so changes the branch it is judging. It denies
# those forms by name and lets everything else through. A command that gets past it only
# by being written to get past it -- a write smuggled through a format string, an option
# it reads differently from the program -- is outside its scope and not a defect in it: an
# agent that means to write is not what a hook on one tool stops. A finding against the
# guard is a write a well-meaning agent would plausibly reach for and the guard lets
# through; add it to the list below and to the test beside this file.
#
# Denied, in every simple command of the call (the pieces between `|`, `||`, `&&`, `;`,
# `&` and newlines, with quotes honoured):
#
#   - $(...), backticks, <(...) and >(...): they run a command the guard cannot see
#   - a redirection to anything but /dev/null or another descriptor (>&2, 2>&1)
#   - programs that write, move or delete files: rm rmdir mv cp ln touch mkdir tee dd chmod
#     chown chgrp install truncate shred mkfifo mknod patch rsync scp, and the archivers
#     unzip zip gzip gunzip bzip2 xz zstd; tar when it extracts, creates or changes an
#     archive (-t lists)
#   - in place: sed -i / --in-place, sort -o / --output, uniq with an output operand,
#     find -delete / -exec / -execdir / -ok / -okdir / -fprint* / -fls
#   - shells and interpreters, since nothing they run is read: bash sh zsh dash ksh fish
#     eval exec source . python python2 python3 node ruby perl php deno bun lua Rscript
#     osascript
#   - wrappers that run another program: sudo doas env xargs nohup setsid watch parallel
#   - editors and openers: vi vim nvim nano emacs ed ex code subl open xdg-open
#   - build, test, format and package runners -- the skill that spawned the agent ran the
#     checks and reports them: make cmake ninja npm npx yarn pnpm pip pip3 pipx poetry uv
#     cargo go rustup gradle gradlew mvn mvnw pytest tox nox jest vitest mocha tsc eslint
#     prettier black ruff rake bundle composer dotnet swift xcodebuild docker podman
#     kubectl helm terraform brew apt apt-get
#   - network and process control: curl wget ssh nc ncat telnet kill killall pkill crontab
#     launchctl systemctl
#   - git: the subcommands that change the checkout, the index, refs, config or the
#     remote (add am apply bisect checkout checkout-index cherry-pick clean clone commit
#     commit-tree daemon difftool fast-import fetch filter-branch filter-repo gc gui init
#     instaweb maintenance merge mergetool mktag mktree mv pack-refs prune pull push
#     read-tree rebase replace repack reset restore revert rm send-email sparse-checkout
#     switch update-index update-ref write-tree); format-patch without --stdout; the
#     writing forms of branch, tag, remote, config, reflog, notes, stash, worktree,
#     submodule, symbolic-ref, bundle and hash-object, while their listing forms pass; and
#     anywhere, --output (a file) and -O / --open-files-in-pager (a program)
#   - gh: an action that creates, changes or deletes something on GitHub (create edit
#     delete merge close reopen comment review lock unlock pin unpin transfer ready sync
#     fork clone rerun cancel download develop checkout set-default install upgrade remove
#     upload set import clear-cache archive unarchive rename add run enable disable ssh cp
#     rebuild stop jupyter code update-branch mark-template link unlink copy field-create
#     field-delete item-add item-create item-edit item-delete), auth login / logout /
#     refresh / setup-git / token, api with a method other than GET or with a body,
#     browse, and --web / -w
#
# A program named by path counts by its base name: /bin/rm is rm. A program from the tree
# -- a relative path, an absolute path outside /bin, /sbin, /usr/bin, /usr/sbin,
# /usr/local/bin, /usr/local/sbin, /opt/homebrew/bin, /opt/homebrew/sbin and
# /opt/local/bin, or a name ending in a script extension (.sh .bash .zsh .py .rb .js .mjs
# .cjs .ts .pl .php) -- is denied: `bin/run-tests.sh` or `./install.sh` is the project's
# own check, which the skill that spawned the agent ran.
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

# Split the command into simple commands with quotes honoured. Prints one status line --
# OK; SUBST for a $(...), backtick, <(...) or >(...) outside single quotes; REDIRECT for a
# `>` to anything but /dev/null or a descriptor -- then, after OK, one line per simple
# command with its words, unquoted, separated by \x1f. An unclosed quote runs to the end
# of the command, which bash rejects anyway.
read_commands() {
  GUARD_CMD=$cmd perl -e '
    my $raw = $ENV{GUARD_CMD};
    my $len = length $raw;
    my $m = "";
    # Mask quoted text and escaped characters length for length, so every position of the
    # mask is the same position of the raw text.
    for (my $i = 0; $i < $len; ) {
      my $c = substr($raw, $i, 1);
      if ($c eq "\x27") {
        my $j = index($raw, "\x27", $i + 1); $j = $len if $j < 0;
        $m .= "\x27" . ("Q" x ($j - $i - 1)) . ($j < $len ? "\x27" : "");
        $i = $j + 1; next;
      }
      if ($c eq q(")) {
        my $j = $i + 1;
        while ($j < $len) {
          my $d = substr($raw, $j, 1);
          if ($d eq "\\") { $j += 2; next }
          last if $d eq q(");
          if ($d eq "`" || ($d eq "\$" && substr($raw, $j + 1, 1) eq "(")) { print "SUBST\n"; exit 0 }
          $j++;
        }
        $j = $len if $j > $len;
        $m .= q(") . ("Q" x ($j - $i - 1)) . ($j < $len ? q(") : "");
        $i = $j + 1; next;
      }
      if ($c eq "\\" && $i + 1 < $len) { $m .= "\\Q"; $i += 2; next }
      $m .= $c; $i++;
    }
    if ($m =~ /\$\(|`|<\(|>\(/) { print "SUBST\n"; exit 0 }
    (my $r = $m) =~ s/\d*>&(\d+|-)//g;
    $r =~ s/(\d|&)?>>?\s*\/dev\/null//g;
    if ($r =~ />/) { print "REDIRECT\n"; exit 0 }
    print "OK\n";
    my $start = 0;
    while ($m =~ /\|\||&&|[|;&\n]|\z/g) {
      my $end = $-[0];
      my $mseg = substr($m, $start, $end - $start);
      my $seg = substr($raw, $start, $end - $start);
      $start = $+[0];
      my @w;
      while ($mseg =~ /\S+/g) {
        my $w = substr($seg, $-[0], $+[0] - $-[0]);
        $w =~ s/\x27([^\x27]*)\x27?|"((?:[^"\\]|\\.)*)"?|\\(.)/ defined $1 ? $1 : defined $2 ? do { (my $u = $2) =~ s{\\([\\"\$`])}{$1}g; $u } : $3 /gse;
        $w =~ tr/\n\x1f/  /;
        push @w, $w;
      }
      print join("\x1f", @w), "\n" if @w;
      last if $end >= $len;
    }
  '
}

letters() { # option word -> its short-option letters; "" for a long option or an operand
  local y=${1#-}
  case $1 in --*|[!-]*) printf '' ;; *) printf '%s' "${y%%[^A-Za-z]*}" ;; esac
}

check_git() { # words after `git`
  local -a w=("$@")
  local i=0 sub='' act='' x n=0
  # The global options first; these take their value in the next word.
  while [ $i -lt ${#w[@]} ]; do
    x=${w[$i]}
    case $x in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) sub=$x; i=$((i + 1)); break ;;
    esac
  done
  local -a rest=("${w[@]:$i}")
  for x in ${rest[@]+"${rest[@]}"}; do
    case $x in
      --output|--output=*) deny "\`git $sub --output\` writes a file; let the output come back on stdout" ;;
      -O|-O?*|--open-files-in-pager|--open-files-in-pager=*) deny "\`git grep -O\` opens the matches in a program" ;;
      -*) ;;
      *) n=$((n + 1)); [ -n "$act" ] || act=$x ;;
    esac
  done
  case $sub in
    add|am|apply|bisect|checkout|checkout-index|cherry-pick|clean|clone|commit|commit-tree|daemon|difftool|fast-import|fetch|filter-branch|filter-repo|gc|gui|init|instaweb|maintenance|merge|mergetool|mktag|mktree|mv|pack-refs|prune|pull|push|read-tree|rebase|replace|repack|reset|restore|revert|rm|send-email|sparse-checkout|switch|update-index|update-ref|write-tree)
      deny "\`git $sub\` changes the checkout, its refs or the remote; a read-only agent reads the branch as it is" ;;
    format-patch)
      for x in ${rest[@]+"${rest[@]}"}; do [ "$x" = --stdout ] && return 0; done
      deny "\`git format-patch\` writes patch files; add --stdout" ;;
    branch)
      # A bare operand creates the branch (`git branch tmp origin/x`); with a listing option
      # it is a pattern or a commit to filter by.
      local listing=no
      for x in ${rest[@]+"${rest[@]}"}; do case $x in
        -d|-D|-m|-M|-c|-C|-f|-u|--delete|--move|--copy|--force|--set-upstream-to|--set-upstream-to=*|--unset-upstream|--edit-description|--track|--no-track)
          deny "\`git branch $x\` changes a branch; list with \`git branch\` or \`--list\`" ;;
        -l|--list|-a|--all|-r|--remotes|--contains|--no-contains|--merged|--no-merged|--points-at|--show-current|--contains=*|--no-contains=*|--merged=*|--no-merged=*|--points-at=*) listing=yes ;;
      esac; done
      [ $n -eq 0 ] || [ $listing = yes ] || deny "\`git branch $act\` creates a branch; list with \`git branch\` or \`--list\`" ;;
    tag)
      local listing=no
      for x in ${rest[@]+"${rest[@]}"}; do case $x in
        -a|-s|-u|-d|-f|-m|-F|-e|--annotate|--sign|--local-user|--local-user=*|--delete|--force|--message|--message=*|--file|--file=*|--edit)
          deny "\`git tag $x\` creates or deletes a tag; list with \`git tag\` or \`--list\`" ;;
        -l|--list|-n|-n?*|--contains|--no-contains|--merged|--no-merged|--points-at|--contains=*|--no-contains=*|--merged=*|--no-merged=*|--points-at=*) listing=yes ;;
      esac; done
      [ $n -eq 0 ] || [ $listing = yes ] || deny "\`git tag $act\` creates a tag; list with \`git tag\` or \`--list\`" ;;
    remote)
      case $act in add|remove|rm|rename|set-url|set-head|set-branches|prune|update)
        deny "\`git remote $act\` changes the remotes; \`git remote -v\`, \`show\` and \`get-url\` read them" ;;
      esac ;;
    config)
      for x in ${rest[@]+"${rest[@]}"}; do case $x in
        --get|--get-all|--get-regexp|--get-urlmatch|--list|-l|--get-color|--get-colorbool) return 0 ;;
      esac; done
      deny "\`git config\` without --get or --list writes; read a key with \`git config --get <key>\`" ;;
    reflog)
      case $act in expire|delete) deny "\`git reflog $act\` rewrites the reflog; \`git reflog\` lists it" ;; esac ;;
    notes)
      case $act in add|append|copy|edit|merge|prune|remove) deny "\`git notes $act\` writes notes; \`git notes list\` and \`show\` read them" ;; esac ;;
    stash)
      case $act in list|show) ;; *) deny "\`git stash${act:+ $act}\` moves changes aside; only \`git stash list\` and \`show\` read them" ;; esac ;;
    worktree)
      [ "$act" = list ] || deny "\`git worktree${act:+ $act}\` changes the worktrees; \`git worktree list\` reads them" ;;
    submodule)
      case $act in add|init|deinit|update|set-branch|set-url|sync|absorbgitdirs|foreach) deny "\`git submodule $act\` changes the submodules or runs a command in each; \`git submodule status\` reads them" ;; esac ;;
    symbolic-ref)
      for x in ${rest[@]+"${rest[@]}"}; do case $x in -d|--delete) deny "\`git symbolic-ref $x\` deletes a ref" ;; esac; done
      [ $n -le 1 ] || deny "\`git symbolic-ref <ref> <target>\` writes the ref; give the ref alone to read it" ;;
    bundle)
      case $act in list-heads|verify) ;; *) deny "\`git bundle${act:+ $act}\` writes a bundle or refs; \`list-heads\` and \`verify\` read one" ;; esac ;;
    hash-object)
      for x in ${rest[@]+"${rest[@]}"}; do case $x in -w) deny "\`git hash-object -w\` writes an object" ;; esac; done ;;
  esac
  return 0
}

check_gh() { # words after `gh`
  local -a pos=()
  local i=0 x
  # The subcommand and its action are the first two operands, past -R / --repo / --hostname
  # and their values.
  while [ $i -lt $# ] && [ ${#pos[@]} -lt 2 ]; do
    x=${*:$((i + 1)):1}
    case $x in
      -R|--repo|--hostname) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) pos+=("$x"); i=$((i + 1)) ;;
    esac
  done
  local a=${pos[0]:-} b=${pos[1]:-}
  for x in "$@"; do case $x in -w|--web) deny "\`gh $a $x\` opens a browser" ;; esac; done
  case $a in
    browse) deny "\`gh browse\` opens a browser" ;;
    api)
      local prev=''
      for x in "$@"; do
        case $prev in -X|--method) [ "$x" = GET ] || deny "\`gh api\` with method $x changes something on GitHub; only GET reads" ;; esac
        case $x in
          -X?*|--method=*) [ "${x#-X}" = GET ] || [ "${x#--method=}" = GET ] || deny "\`gh api\` with method ${x#-X} changes something on GitHub; only GET reads" ;;
          -f|-F|--field|--field=*|--raw-field|--raw-field=*|--input|--input=*) deny "\`gh api $x\` sends a body, which writes; a read takes no fields" ;;
        esac
        prev=$x
      done ;;
    auth)
      case $b in login|logout|refresh|setup-git|token) deny "\`gh auth $b\` changes or exposes the login; \`gh auth status\` reads it" ;; esac ;;
    *)
      case $b in
        create|edit|delete|merge|close|reopen|comment|review|lock|unlock|pin|unpin|transfer|ready|sync|fork|clone|rerun|cancel|download|develop|checkout|set-default|install|upgrade|remove|upload|set|import|clear-cache|archive|unarchive|rename|add|run|enable|disable|ssh|cp|rebuild|stop|jupyter|code|update-branch|mark-template|link|unlink|copy|field-create|field-delete|item-add|item-create|item-edit|item-delete)
          deny "\`gh $a $b\` creates, changes or deletes something on GitHub; list and view read it" ;;
      esac ;;
  esac
  return 0
}

check_segment() { # the words of one simple command, unquoted
  local -a words=("$@")
  local x y n=0
  # Assignments, harmless wrappers and the shell's own keywords before the program.
  while [ ${#words[@]} -gt 0 ]; do
    case ${words[0]} in
      [A-Za-z_]*=*) ;;
      time|nice|command|builtin|if|then|else|elif|while|until|do|for|case|'!'|'{'|'}'|'('|')') ;;
      *) break ;;
    esac
    words=("${words[@]:1}")
  done
  [ ${#words[@]} -gt 0 ] || return 0
  local prog=${words[0]}
  prog=${prog#"${prog%%[!(]*}"}; prog=${prog%"${prog##*[!)]}"}   # (cd x && ls) -> cd, ls
  # A program from the tree -- `bin/run-tests.sh`, `./install.sh`, `scripts/lint` -- is the
  # project's own check or tool, which the skill that spawned the agent ran. By a relative
  # path, by an absolute path outside the system's bin directories, or by a script
  # extension, it is denied; /bin/rm and /usr/bin/grep count by their base name.
  case $prog in
    [\<\>]*|[0-9][\<\>]*) ;;   # a redirection word, left standing when its `&` split the segment
    */*)
      case $prog in
        /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*|/opt/homebrew/bin/*|/opt/homebrew/sbin/*|/opt/local/bin/*) ;;
        *) deny "\`$prog\` runs a program from the tree; the skill that spawned you ran the checks and reports them" ;;
      esac ;;
  esac
  case $prog in
    *.sh|*.bash|*.zsh|*.py|*.rb|*.js|*.mjs|*.cjs|*.ts|*.pl|*.php)
      deny "\`$prog\` runs a script; the skill that spawned you ran the checks and reports them" ;;
  esac
  prog=${prog##*/}                                               # /bin/rm -> rm
  local -a rest=("${words[@]:1}")
  case $prog in
    git) check_git ${rest[@]+"${rest[@]}"} ;;
    gh) check_gh ${rest[@]+"${rest[@]}"} ;;
    rm|rmdir|mv|cp|ln|touch|mkdir|tee|dd|chmod|chown|chgrp|install|truncate|shred|mkfifo|mknod|patch|rsync|scp|unzip|zip|gzip|gunzip|bzip2|xz|zstd)
      deny "\`$prog\` writes, moves or deletes files" ;;
    tar)
      # The first word carries the mode, with or without its dash.
      for x in ${rest[@]+"${rest[@]}"}; do
        case $x in --extract|--get|--create|--append|--update|--delete|--concatenate) deny "\`tar $x\` writes files or an archive; \`tar -tf\` lists one" ;; esac
        y=${x#-}; y=${y%%[^A-Za-z]*}
        case $x in --*) ;; *) case $y in *[xcrudA]*) deny "\`tar $x\` writes files or an archive; \`tar -tf\` lists one" ;; esac; break ;; esac
      done ;;
    sed)
      for x in ${rest[@]+"${rest[@]}"}; do
        case $x in --in-place*) deny "\`sed $x\` edits the file in place; drop it and read the result on stdout" ;; esac
        case $(letters "$x") in *i*) deny "\`sed $x\` edits the file in place; drop it and read the result on stdout" ;; esac
      done ;;
    sort)
      for x in ${rest[@]+"${rest[@]}"}; do
        case $x in --output*) deny "\`sort $x\` writes a file; let the output come back on stdout" ;; esac
        case $(letters "$x") in *o*) deny "\`sort $x\` writes a file; let the output come back on stdout" ;; esac
      done ;;
    uniq)
      for x in ${rest[@]+"${rest[@]}"}; do case $x in -*) ;; *) n=$((n + 1)) ;; esac; done
      [ $n -le 1 ] || deny "\`uniq\` with two operands writes the second" ;;
    find)
      for x in ${rest[@]+"${rest[@]}"}; do case $x in
        -delete|-exec|-execdir|-ok|-okdir|-fprint*|-fls) deny "\`find $x\` deletes, runs a program or writes a file; print the matches and act on them yourself" ;;
      esac; done ;;
    bash|sh|zsh|dash|ksh|fish|eval|exec|source|.|python|python2|python3|node|ruby|perl|php|deno|bun|lua|Rscript|osascript)
      deny "\`$prog\` runs code, and nothing it runs is read; write the commands out" ;;
    sudo|doas|env|xargs|nohup|setsid|watch|parallel)
      deny "\`$prog\` runs another program; call the program directly" ;;
    vi|vim|nvim|nano|emacs|ed|ex|code|subl|open|xdg-open)
      deny "\`$prog\` opens an editor or application; use the Read tool" ;;
    make|cmake|ninja|npm|npx|yarn|pnpm|pip|pip3|pipx|poetry|uv|cargo|go|rustup|gradle|gradlew|mvn|mvnw|pytest|tox|nox|jest|vitest|mocha|tsc|eslint|prettier|black|ruff|rake|bundle|composer|dotnet|swift|xcodebuild|docker|podman|kubectl|helm|terraform|brew|apt|apt-get)
      deny "\`$prog\` builds, tests, formats or installs, and leaves its output in the tree; the skill that spawned you ran the checks and reports them" ;;
    curl|wget|ssh|nc|ncat|telnet)
      deny "\`$prog\` reaches the network; use WebFetch for a page and gh for GitHub" ;;
    kill|killall|pkill|crontab|launchctl|systemctl)
      deny "\`$prog\` changes running processes or the system" ;;
  esac
  return 0
}

first=true
while IFS= read -r line; do
  if $first; then
    first=false
    case $line in
      OK) ;;
      SUBST) deny "a \$(...), backtick, <(...) or >(...) runs a command this guard cannot see; write it out as a command of its own" ;;
      REDIRECT) deny "a redirection to a file; only >/dev/null, 2>/dev/null, &>/dev/null and >&2 pass" ;;
      *) deny "the command could not be read" ;;
    esac
    continue
  fi
  IFS=$'\x1f' read -r -a words <<< "$line"
  check_segment "${words[@]+"${words[@]}"}"   # guarded: bash 3.2 calls an empty array unbound
done < <(read_commands)

# The splitter always prints a status line for a non-empty command, so silence means it did
# not run -- perl missing, or a crash -- and a read-only agent's command must not pass unread.
$first && deny "the command could not be checked (is perl installed?)"

exit 0
