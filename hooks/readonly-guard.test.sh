#!/usr/bin/env bash
# Tests for readonly-guard.sh. No framework: each case feeds the guard one hook input on
# stdin and asserts whether it denied the call.
#
#   [GUARD_BASH=<bash>] readonly-guard.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs jq and perl. GUARD_BASH is the bash that
# runs the guard, `bash` from PATH by default; when the stock /bin/bash is a different
# version, the suite runs itself a second time with GUARD_BASH=/bin/bash, so every case
# also holds on the 3.2 that macOS ships.
# shellcheck disable=SC2016  # the cases are command text, not expressions to expand

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GUARD="$SCRIPT_DIR/readonly-guard.sh"
# Which bash runs the guard. The suite runs itself twice when the stock /bin/bash differs
# from the one on PATH: on macOS that is 3.2, where an empty array under `set -u` is unbound.
GUARD_BASH=${GUARD_BASH:-bash}
if [ -z "${GUARD_BASH_INNER:-}" ] && [ -x /bin/bash ] \
   && [ "$(/bin/bash -c 'echo "$BASH_VERSION"')" != "$(bash -c 'echo "$BASH_VERSION"')" ]; then
  GUARD_BASH=/bin/bash GUARD_BASH_INNER=1 "$0"; inner_rc=$?
else
  inner_rc=0
fi
guard() { "$GUARD_BASH" "$GUARD"; }

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }

decision() { # agent_type command -> allow | deny | <error>
  local out status
  out=$(jq -n --arg a "$1" --arg c "$2" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:$a,tool_input:{command:$c}} | if $a == "" then del(.agent_type) else . end' \
    | guard 2>&1); status=$?
  [ $status -eq 0 ] || { printf 'exit %s: %s\n' "$status" "$out"; return; }
  if [ -z "$out" ]; then printf 'allow\n'; return; fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || printf 'bad json: %s\n' "$out"
}

expect() { # allow|deny agent command
  local want=$1 agent=$2 cmd=$3 got
  got=$(decision "$agent" "$cmd")
  if [ "$got" = "$want" ]; then ok "$want  [$agent] ${cmd//$'\n'/ }"
  else bad "$want  [$agent] ${cmd//$'\n'/ }" "got: $got"; fi
}

echo "readonly-guard.sh under $("$GUARD_BASH" -c 'echo "${BASH_VERSION%%(*}"')"

# ------------------------------------------------------------- who it applies to
expect allow ""                   'rm -rf build'
expect allow "general-purpose"    'rm -rf build'
expect allow "implementer"        'git push -u origin HEAD'
expect allow "ontherun:implementer" 'git commit -m x'
expect allow "verifier"           'npm test'
expect deny  "reviewer"           'rm -rf build'
expect deny  "ontherun:reviewer"  'rm -rf build'
expect deny  "ontherun:validator" 'git commit -m x'
expect deny  "plan-reviewer"      'git push'
expect deny  "plan-validator"     'touch x'
expect deny  "fold-checker"       'python3 -c "print(1)"'

# Unparseable input is no decision.
out=$(printf 'not json' | guard 2>&1); status=$?
if [ $status -eq 0 ] && [ -z "$out" ]; then ok "non-JSON stdin -> no decision"; else bad "non-JSON stdin -> no decision" "exit $status: $out"; fi
out=$(jq -n '{tool_name:"Bash",agent_type:"reviewer",tool_input:{}}' | guard 2>&1); status=$?
if [ $status -eq 0 ] && [ -z "$out" ]; then ok "no command -> no decision"; else bad "no command -> no decision" "exit $status: $out"; fi

# ------------------------------------------------------------------ the grammar
# Words, quoted strings, separators and the /dev/null redirections; nothing bash would rewrite.
R=reviewer
expect allow $R 'ls -la /work/acme-api/src'
expect allow $R 'ls "a b"'
expect allow $R 'ls -a /work/acme-api | grep -i -E '"'"'^(agents|claude|contributing|decisions|readme)\.md$'"'"
expect allow $R 'git -C /work/acme-api show origin/main:README.md | tr "\n" " " | grep -oE "open at [^.]+"'
expect allow $R 'git -C /work/acme-api log --oneline -5 && git -C /work/acme-api status --porcelain'
expect allow $R 'git -C /work/acme-api grep -n foo origin/main -- src/ || true'
expect allow $R 'cat /work/acme-api/CONTRIBUTING.md | head -50; wc -l /work/acme-api/README.md'
expect allow $R 'git -C /work/acme-api diff origin/main...HEAD -- src/ 2>/dev/null | head -200'
expect allow $R 'git -C /work/acme-api log -1 2>&1'
expect allow $R 'ls /work/acme-api > /dev/null'
expect allow $R 'ls /work/acme-api >/dev/null 2>&1'
expect allow $R 'ls /work/acme-api &>/dev/null'
expect allow $R 'jq -r ".version" /work/acme-api/package.json'
expect allow $R 'grep -rn "->" /work/acme-api/src'
expect allow $R "git -C /work/acme-api log --format='%h -> %s' -5"
expect allow $R 'git -C /work/acme-api grep -n "a|b" origin/main -- src/'
expect allow $R "grep -E 'a\\|b' /work/acme-api/f"
expect allow $R 'git -C /work/acme-api log --format="%h\\n" -3'
expect allow $R 'grep -c "a\"b" /work/acme-api/f'                 # an escaped quote inside double quotes
expect allow $R "grep -c \"don't\" /work/acme-api/f"
expect allow $R "grep -c \"it's\" /work/acme-api/f | grep -v '\$x'"
expect allow $R "grep -c '^\$' /work/acme-api/f"
expect allow $R "grep -E 'a$|b' src/x.c"
expect allow $R "grep -n 'a'\"b\" /work/acme-api/f"
expect allow $R 'grep -E "(a|b)" /work/acme-api/f'
expect allow $R "git -C /work/acme-api log --format='%h {%an}' -3"
expect allow $R "grep '#include' src/main.c"
expect allow $R 'ls "*.md"'
expect allow $R "gh api 'repos/acme/acme-api/pulls?state=all'"
expect allow $R 'grep -c ">" /work/acme-api/f'
expect allow $R "grep -c '<' /work/acme-api/f 2>/dev/null"
expect allow $R 'test -d /work/acme-api/src'
expect deny  $R 'echo ~'                                           # bash expands it; write the path out
expect allow $R "echo '~'"
expect allow $R 'git -C /work/acme-api log HEAD~ HEAD~1..HEAD'
expect allow $R 'git -C /work/acme-api log --format=%h%n%s -3'
expect allow $R 'git -C /work/acme-api log --format=%h%x09%s -3'
expect allow $R 'GIT_PAGER=cat git -C /work/acme-api log -1'
expect allow $R 'LC_ALL=C sort /work/acme-api/words.txt | uniq -c'
expect allow $R '/usr/bin/cat /work/acme-api/README.md'
expect allow $R '/usr/bin/grep -c "sentence" /work/acme-api/README.md'
# Every other character outside quotes is a way for bash to run something other than the words.
expect deny  $R 'git -C /work/acme-api diff > /tmp/diff.txt'
expect deny  $R 'git -C /work/acme-api diff >> /tmp/diff.txt'
expect deny  $R 'echo hi > file.txt'
expect deny  $R 'ls 2>/tmp/x'
expect deny  $R 'ls &>/tmp/x'
expect deny  $R 'ls 1>&2'
expect deny  $R 'cat < /etc/passwd'
expect deny  $R "jq . <<< '{}'"
expect deny  $R $'cat <<EOF\nx\nEOF'
expect deny  $R 'echo "$(git -C /work/acme-api rev-parse HEAD)"'
expect deny  $R 'cat `ls`'
expect deny  $R 'diff <(git show a:f) <(git show b:f)'
expect deny  $R "git -C /work log \$'--output=/tmp/evil'"
expect deny  $R 'git -C ~+/fixtures/x.git diff HEAD~1 HEAD'
expect deny  $R 'git -C ~ log'
expect deny  $R 'echo a=~'
expect deny  $R 'echo PATH=a:~'
# The words reach the checks one simple command per line, \x1f between words: neither may
# sit inside a quoted word, or one checked command is not the one bash runs.
expect deny  $R $'git -C /work/repo log -1 --format=\'%h\necho\' --output=/tmp/x'
expect deny  $R $'git -C /work/repo log -1 --format="%h\necho" --output=/tmp/x'
expect deny  $R $'echo \'a\x1fb\''
expect deny  $R $'echo "a\x1fb"'
expect deny  $R $'echo \'a\x01b\''
expect deny  $R $'echo a\x1fb'
expect deny  $R $'echo "a\\\ncat"'                                  # a line continuation inside quotes
expect deny  $R $'git -C /work/repo log -1 --format="%h\\\necho" --output=/tmp/x'
expect deny  $R 'git -C /work log --{output=/tmp/evil,}'
expect deny  $R "printf evil | sort \$'-o'/tmp/evil"
expect deny  $R 'cat "$HOME/.ssh/id_rsa"'
expect deny  $R 'cat ${HOME}/x'
expect deny  $R 'ls /work/{a,b}'
expect deny  $R 'grep -E "foo$|bar$" /work/acme-api/f'           # a $ inside double quotes expands
expect deny  $R 'grep "foo$" src/x.c'
expect deny  $R 'grep foo$ src/x.c'
expect deny  $R 'grep -E "foo$HOME" /work/acme-api/f'
expect deny  $R 'find /work -name "*.py" $"-exec" rm -rf {} \;'
expect deny  $R "echo \"it's\" \"\$HOME\" 'x'"
expect deny  $R 'ls () ( rm -rf /tmp/x ); ls'
expect deny  $R 'f() { rm -rf /tmp/x; }; f'
expect deny  $R 'function ls { rm -rf /tmp/x; }; ls'
expect deny  $R 'ls $((1+1))'
expect deny  $R '((COLUMNS=PATH=0)); cat README.md'
expect deny  $R 'echo "$[PATH=0]"; git log -1'
expect deny  $R 'echo $[1+1]'
expect deny  $R '(git -C /work/acme-api log -1)'
expect deny  $R '(cd /work/acme-api && git log -1)'
expect deny  $R 'ls *.md'
expect deny  $R 'gh api repos/acme/acme-api/pulls?state=all'
expect deny  $R 'sort /work/f -[o] /tmp/x'
expect deny  $R '[ -f /work/acme-api/README.md ] && cat /work/acme-api/README.md'
expect deny  $R 'ls # list'
expect deny  $R 'ls a#b'
expect deny  $R $'true # it\'s\ntouch pwned\necho x #\''
expect deny  $R 'echo \$HOME'
expect deny  $R $'git -C /work/acme-api log \\\n  --oneline -3'
expect deny  $R "echo \\' ; rm -rf /tmp/x \\'"
expect deny  $R 'echo \" ; rm -rf /tmp/x \"'
expect deny  $R "ls '; rm -rf /tmp/x"
expect deny  $R 'grep "a /work/acme-api/f'
expect deny  $R 'ls !'
expect deny  $R 'ls & rm -rf /tmp/x'
expect deny  $R 'git -C /work/acme-api log & git -C /work/acme-api push'
expect deny  $R 'git -C /work/acme-api log -1 && rm -f notes.txt'
expect deny  $R "''; rm -rf /tmp/x"
expect deny  $R '"" ; rm -rf /tmp/x'
expect deny  $R "'' ls /work/acme-api"   # an empty command name; bash rejects it too
# A quoted operator is an argument, and the word after it is checked like any other.
expect deny  $R 'sort /work/f "2>" -o /tmp/x'
expect deny  $R 'git -C /work/repo log -r "<" --output=/tmp/x'

# --------------------------------------------------------------------- git
expect allow $R 'git -C /work/acme-api diff origin/main...HEAD'
expect allow $R 'git -C /work/acme-api log --oneline origin/main..HEAD'
expect allow $R 'git -C /work/acme-api show abc123:src/app.py'
expect allow $R 'git -C /work/acme-api grep -n useSession origin/main -- src/'
expect allow $R 'git -C /work/acme-api rev-parse HEAD'
expect allow $R 'git -C /work/acme-api rev-parse --abbrev-ref HEAD'
expect allow $R 'git -C /work/acme-api blame -L 10,20 src/app.py'
expect allow $R 'git -C /work/acme-api status --porcelain'
expect allow $R 'git -C /work/acme-api merge-base --is-ancestor abc origin/main'
expect allow $R 'git -c core.pager=cat -C /work/acme-api log -3'
expect allow $R 'git -c color.ui=false -C /work/acme-api log -3'
expect allow $R 'git --no-pager -C /work/acme-api diff --stat'
expect allow $R 'git -C /work/acme-api for-each-ref --format="%(refname:short)" --sort=-committerdate refs/heads/'
expect allow $R 'git -C /work/acme-api show-ref --heads'
expect allow $R 'git -C /work/acme-api cat-file -p HEAD:README.md'
expect allow $R 'git -C /work/acme-api check-ignore -q .claude/worktrees/x'
expect deny  $R 'git -C /work/acme-api checkout main'
expect deny  $R 'git -C /work/acme-api commit -m "fix"'
expect deny  $R 'git -C /work/acme-api push origin HEAD'
expect deny  $R 'git -C /work/acme-api add -A'
expect deny  $R 'git -C /work/acme-api reset --hard'
expect deny  $R 'git -C /work/acme-api stash'
expect deny  $R 'git -C /work/acme-api grep -Ovim foo'
expect deny  $R 'git -C /work/acme-api grep -nO foo'
expect deny  $R 'git -C /work/acme-api grep --open-files-in-pager foo'
expect deny  $R 'git'
expect deny  $R 'git -C /work/acme-api --exec-path=/tmp diff'
# The subcommands whose reading and writing forms differ by an operand or an option are out
# entirely, listing forms included.
expect deny  $R 'git -C /work/acme-api branch'
expect deny  $R 'git -C /work/acme-api branch -a'
expect deny  $R 'git -C /work/acme-api branch --show-current'
expect deny  $R 'git -C /work/acme-api branch new-branch'
expect deny  $R 'git -C /work/acme-api branch -D old'
expect deny  $R 'git -C /work/acme-api tag -l "v1.*"'
expect deny  $R 'git -C /work/acme-api tag v2'
expect deny  $R 'git -C /work/acme-api config --get remote.origin.url'
expect deny  $R 'git -C /work/acme-api config -l'
expect deny  $R 'git -C /work/acme-api config user.name me'
expect deny  $R 'git -C /work/acme-api remote -v'
expect deny  $R 'git -C /work/acme-api remote get-url origin'
expect deny  $R 'git -C /work/acme-api remote add up git@x:y/z'
expect deny  $R 'git -C /work/acme-api symbolic-ref --short refs/remotes/origin/HEAD'
expect allow $R 'git -C /work/acme-api rev-parse -q --verify --abbrev-ref origin/HEAD'   # workspace.md's default-branch step
expect allow $R 'git -C /work/acme-api show-ref --verify -q refs/remotes/origin/main'   # and its fallback
expect deny  $R 'git -C /work/acme-api symbolic-ref HEAD refs/heads/other'
expect deny  $R 'git -C /work/acme-api worktree list'
expect deny  $R 'git -C /work/acme-api worktree add ../x -b y'
expect deny  $R 'git -C /work/acme-api fetch origin main'
expect deny  $R 'git -C /work/acme-api fetch . HEAD:refs/heads/main'
expect deny  $R 'git -C /work/acme-api fetch --depth 1 origin main'
expect deny  $R 'git -C /work/acme-api ls-remote --heads origin "claude/api-1-*"'
expect deny  $R 'git ls-remote --upload-pack=/tmp/x origin'
# Configuration and environment that make an allowlisted subcommand run a program or write.
expect deny  $R 'git -c core.fsmonitor=/tmp/x status'
expect deny  $R 'git -c diff.external=/tmp/x diff'
expect deny  $R 'git -c "core.pager=less; rm -rf /tmp/x" log'
expect deny  $R 'git -ccore.pager=/tmp/x log'
expect deny  $R 'git -c alias.ro="!rm -rf x" ro'
expect deny  $R 'GIT_EXTERNAL_DIFF=/tmp/x git diff'
expect deny  $R 'GIT_PAGER="rm -rf /tmp/x" git log'
expect deny  $R 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=/tmp/x git status'
expect deny  $R 'PATH=/tmp/evil:/usr/bin git log'
expect deny  $R 'env GIT_SSH_COMMAND=/tmp/x git log'
expect deny  $R 'git diff --output=/tmp/x'
expect deny  $R 'git log --output /tmp/x'
expect deny  $R 'git diff --ext-diff'
expect deny  $R 'git --config-env=core.pager=X log'
# Options are an allowlist: the full spelling on the subcommand's list, or denied.
expect allow $R 'git -C /work/acme-api log --since="1 week ago" --until 2024-06-01 -5'
expect allow $R 'git -C /work/acme-api log -n 5 --author=me --format %h'
expect allow $R 'git -C /work/acme-api log -n5 -p -S useSession -- src/'
expect allow $R 'git -C /work/acme-api diff --no-color --name-status -M90% origin/main...HEAD'
expect allow $R 'git -C /work/acme-api diff --no-such-thing origin/main'   # --no-<anything> only switches off
expect allow $R 'git -C /work/acme-api show -s --format=%H HEAD'
expect allow $R 'git -C /work/acme-api rev-list --count origin/main..HEAD'
expect allow $R 'git -C /work/acme-api shortlog -sn origin/main..HEAD'
expect allow $R 'git -C /work/acme-api status -uno --porcelain'
expect allow $R 'git -C /work/acme-api log --stat -3'
expect allow $R 'git -C /work/acme-api diff --staged'
expect allow $R 'git -C /work/acme-api log --no-merges -3'
expect allow $R 'git -C /work/acme-api log -L10,20:src/a.py'
expect allow $R 'git -C /work/acme-api log -- src/'
expect allow $R 'git -C /work/acme-api show --stat HEAD'
expect deny  $R 'git -C /work/acme-api log --unknown-option -1'
expect deny  $R 'git -C /work/acme-api log --show-signature -1'
expect deny  $R 'git -C /work/acme-api log --help'   # opens the manual in a pager
expect deny  $R 'git -C /work/acme-api log -n'
expect deny  $R 'git -C /work/acme-api diff -O/tmp/order'
expect deny  $R 'git -C /work/acme-api for-each-ref --contains'
# Abbreviations, which git accepts, are not the full spelling.
expect deny  $R 'git -C /work/acme-api log --outp=/tmp/x'
expect deny  $R 'git -C /work/acme-api diff --ext-d'
expect deny  $R 'git -C /work/acme-api log --o=/tmp/x'
# A value shaped like an option is denied even after -e: `-U --stat` and `-e -foo` look alike.
expect deny  $R 'git -C /work/acme-api grep -A2 -B 2 -e -foo -- src/'
expect allow $R "git -C /work/acme-api grep -A2 -B 2 -e '[-]foo' -- src/"
expect allow $R 'git -C /work/acme-api grep -A2 -B 2 -e -foo:bar -- src/'
expect deny  $R 'git -C /work/acme-api grep -A2 -B 2 -e -foo=bar -- src/'
expect deny  $R 'git -C /work/acme-api for-each-ref --sort -committerdate refs/heads/'   # a separate value with a dash
# An option with an optional argument reads the next word as a new option; so does the guard.
expect deny  $R 'git -C /work/acme-api diff -U --output=/tmp/x origin/main'
expect deny  $R 'git -C /work/acme-api log -U --output=/tmp/x -p'
expect deny  $R 'git -C /work/acme-api log -1 --pretty --output=/tmp/x'
expect deny  $R 'git -C /work/acme-api log --show-linear-break --output=/tmp/x'
expect deny  $R 'git -C /work/acme-api log --author --output=/tmp/x'
expect allow $R 'git -C /work/acme-api diff -U3 origin/main'
expect allow $R 'git -C /work/acme-api diff -U0 --stat origin/main'
expect allow $R 'git -C /work/acme-api log --pretty=oneline -3'
expect allow $R 'git -C /work/acme-api log --pretty -3'
expect allow $R 'git -C /work/acme-api log --author "Ada" -3'
expect allow $R 'git -C /work/acme-api log -n -1'

# A bare repository committed in the diff carries a config git would obey; neither -C nor
# the hook's cwd may reach one, and --git-dir, --work-tree and --bare name one outright.
GUARD_TMP=$(mktemp -d)
mkdir -p "$GUARD_TMP/repo/.git" "$GUARD_TMP/repo/fixtures/x.git/objects" "$GUARD_TMP/repo/fixtures/x.git/refs" "$GUARD_TMP/repo/fixtures/x.git/sub"
: > "$GUARD_TMP/repo/fixtures/x.git/HEAD"
X=$GUARD_TMP/repo/fixtures/x.git
expect deny  $R "git -C $X diff HEAD~1 HEAD"
expect deny  $R "git -C $X/sub log"                          # discovery walks up into the bare repo
expect deny  $R "git -C $GUARD_TMP/repo -C fixtures/x.git log"   # a second -C is relative to the first
expect allow $R "git -C $GUARD_TMP/repo status"
expect allow $R "git -C $GUARD_TMP/repo -C . status"
expect allow $R 'git -C /work/acme-api status'              # a directory that does not exist is git's error
expect deny  $R "git --git-dir=$X --work-tree=. status"
expect deny  $R "git --git-dir $X status"
expect deny  $R "git --work-tree=. status"
expect deny  $R "git --bare -C $X log"
# A relative -C is read against the hook input's cwd, and against the guard's own when the
# input has none.
cwd_decision() { # cwd command -> allow | deny
  local out
  out=$(jq -n --arg d "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:"ontherun:reviewer",cwd:$d,tool_input:{command:$c}}' | guard 2>&1)
  if [ -z "$out" ]; then printf 'allow\n'; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
expect_cwd() { # allow|deny cwd command
  local got; got=$(cwd_decision "$2" "$3")
  if [ "$got" = "$1" ]; then ok "$1  [cwd] $3"; else bad "$1  [cwd] $3" "got: $got"; fi
}
expect_cwd deny  "$GUARD_TMP/repo" 'git -C fixtures/x.git log'
expect_cwd allow "$GUARD_TMP/repo" 'git -C fixtures log'
expect_cwd allow "$GUARD_TMP/repo" 'git -C nowhere log'      # git's own error, before any config is read
expect_cwd deny  "$GUARD_TMP/repo" 'git -C ~+/fixtures/x.git log'   # bash would expand ~+ to this cwd
expect_cwd deny  "$X" 'git log'                              # no -C at all
expect_cwd deny  "$X/sub" 'git status'
got=$(cd "$GUARD_TMP/repo" && decision $R 'git -C fixtures/x.git log')
if [ "$got" = deny ]; then ok "deny  [pwd] git -C fixtures/x.git log"; else bad "deny  [pwd] git -C fixtures/x.git log" "got: $got"; fi
rm -rf "$GUARD_TMP"

# ------------------------------------------------------------------------ gh
V=validator
expect allow $V 'gh pr checks claude/api-2-x -R acme/acme-api'
expect allow $V 'gh pr list -R acme/acme-api --head claude/api-2-x --state all --json number,state'
expect allow $V 'gh pr view 104 -R acme/acme-api --json mergeCommit,mergedAt'
expect allow $V 'gh pr view 104 -R acme/acme-api --comments'
expect allow $V 'gh pr list -R acme/acme-api --search "-label:wontfix" -L 50'
expect allow $V 'gh pr list --help'
expect allow $V 'gh run view 123 -R acme/acme-api --log'
expect allow $V 'gh api repos/acme/acme-api/pulls/104'
expect allow $V 'gh api -X GET repos/acme/acme-api/pulls/104'
expect allow $V 'gh api -XGET -H "Accept: application/json" repos/acme/acme-api/pulls/104'
expect allow $V 'gh api -i -H "Accept: application/json" repos/acme/acme-api/pulls/104'
expect allow $V 'gh api --paginate -q ".[].number" repos/acme/acme-api/pulls'
expect allow $V 'gh auth status -a'
expect allow $V 'gh auth status -h github.com'
expect deny  $V 'gh pr merge 104 -R acme/acme-api'
expect deny  $V 'gh pr edit 104 --body x'
expect deny  $V 'gh pr create --title t --body b'
expect deny  $V 'gh pr ready --undo 104'
expect deny  $V 'gh issue create --title x'
expect deny  $V 'gh pr view 104 -R acme/acme-api --web'
expect deny  $V 'gh pr view 104 -w'
expect deny  $V 'gh pr view 104 -R acme/acme-api -c -w'
expect deny  $V 'gh pr view 104 -R acme/acme-api -c -w=1'
expect deny  $V 'gh issue view 7 -c -w=true'
expect deny  $V 'gh pr view 104 -cw'                                 # gh splits a cluster of booleans
expect deny  $V 'gh issue view 7 -cw'
expect deny  $V 'gh pr status -cw'
expect deny  $V 'gh run list -aw x'
expect allow $V 'gh pr view 104 -c'
expect allow $V 'gh run list -R acme/acme-api -c abc123'              # -c takes a value here; the SHA is an operand
expect allow $V 'gh pr list -R acme/acme-api -a octocat'
expect deny  $V 'gh pr list -R acme/acme-api -a -- -w'               # gh takes -- as the assignee, then --web
expect deny  $V 'gh issue list -R acme/acme-api -a -- -w'
expect deny  $V 'gh pr checks 104 -i -- -w'
expect deny  $V 'gh pr view 104 -- -w'
expect deny  $V 'gh api -- repos/acme/acme-api'
expect deny  $V 'gh pr list -R acme/acme-api --unknown'
expect deny  $V 'gh auth status -t -a'
expect deny  $V 'gh auth status -t'
expect deny  $V 'gh auth status --show-token'
expect deny  $V 'gh api -X POST repos/acme/acme-api/issues'
expect deny  $V 'gh api repos/acme/acme-api/issues -XPOST'
expect deny  $V 'gh api -iXPOST repos/acme/acme-api/issues'
expect deny  $V 'gh api repos/acme/acme-api/issues -f title=x'
expect deny  $V 'gh api repos/acme/acme-api/issues -fbody=x'
expect deny  $V 'gh api repos/acme/acme-api/issues -F title=@body.json'
expect deny  $V 'gh api repos/acme/acme-api/issues --raw-field title=x'
expect deny  $V 'gh api repos/acme/acme-api/issues --input body.json'

# ---------------------------------------------------------- the other programs
expect allow $R 'sort -u /work/acme-api/words.txt'
expect allow $R 'sort -un /work/acme-api/in.txt'
expect allow $R 'sort -t: -k2,2n /work/f'
expect allow $R 'sort -k 2 -r /work/f'
expect allow $R 'uniq -f 1 /work/f'
expect allow $R 'uniq --skip-fields=1 /work/f'
expect deny  $R 'sort -o /tmp/out /work/acme-api/words.txt'
expect deny  $R 'sort -uo /tmp/out /work/acme-api/in.txt'
expect deny  $R 'sort --compress-program=/tmp/x /work/acme-api/words.txt'
expect deny  $R 'sort -T /tmp /work/f'
expect deny  $R 'sort --temporary-directory=/tmp /work/f'
expect deny  $R 'sort --out /tmp/x /work/acme-api/f'
expect deny  $R 'sort --o /tmp/out /work/acme-api/f'
expect deny  $R 'uniq /work/acme-api/in /tmp/out'
expect deny  $R 'uniq -f 1 /work/f /tmp/out'
# Out entirely: a write or exec mode hidden in a program, a format or an option, or a
# move of the shell; the Read, Grep, Glob and WebFetch tools do what they did.
P=plan-reviewer
expect deny  $R 'sed -n "10,20p" /work/acme-api/src/app.py'
expect deny  $R 'sed -i "s/a/b/" /work/acme-api/src/app.py'
expect deny  $R 'git -C /work/acme-api log -1 | sed -n 1p'
expect deny  $R "awk 'BEGIN{system (\"rm -rf /tmp/x\")}'"
expect deny  $P 'curl -sL https://example.com/pricing'
expect deny  $P 'wget -q https://example.com/file'
expect deny  $R 'file /work/acme-api/README.md'
expect deny  $R 'find /work/acme-api -maxdepth 3 -iname "decisions*" -not -path "*/node_modules/*" 2>/dev/null'
expect deny  $R 'find /work -name "*.tmp" -delete'
expect deny  $R 'rg -n "TODO" /work/acme-api/src'
expect deny  $R 'rg --pre /tmp/x pattern /work/acme-api'
expect deny  $R 'date -u'
expect deny  $R 'date -s "2020-01-01"'
expect deny  $R "printf '%s\n' x"
expect deny  $R 'printf -v PATH %s tools:/usr/bin; git status'
expect deny  $R 'cd /work/acme-api'
expect deny  $R 'cd /work/acme-api && git log --oneline -5'
expect deny  $R 'tee /tmp/out.txt'
expect deny  $R 'xargs rm'
expect deny  $R 'npm test'
expect deny  $R 'bash -c "rm -rf /tmp/x"'
expect deny  $R 'ls | python3'
expect deny  $R 'sudo ls'
# A program named by path: only under the system directories.
expect deny  $R './tools/git log'
expect deny  $R '/work/acme-api/node_modules/.bin/cat x'
expect deny  $R '/tmp/git log'
expect deny  $R '/usr/bin/rm -rf /tmp/x'
expect deny  $R '/usr/bin/../../tmp/cat x'
expect deny  $R '/bin/../tmp/git log'

# A checker that cannot run denies rather than falling through.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/perl"; chmod +x "$TMP/bin/perl"
out=$(jq -n '{tool_name:"Bash",agent_type:"reviewer",tool_input:{command:"ls /work"}}' | PATH="$TMP/bin:$PATH" guard 2>/dev/null)
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then ok "perl failing -> deny"; else bad "perl failing -> deny" "got: $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$inner_rc" -eq 0 ]
