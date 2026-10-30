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

# --------------------------------------------------------------------- git
R=reviewer
expect allow $R 'git -C /work/acme-api diff origin/main...HEAD'
expect allow $R 'git -C /work/acme-api log --oneline origin/main..HEAD'
expect allow $R 'git -C /work/acme-api show abc123:src/app.py'
expect allow $R 'git -C /work/acme-api grep -n useSession origin/main -- src/'
expect allow $R 'git -C /work/acme-api rev-parse HEAD'
expect allow $R 'git -C /work/acme-api blame -L 10,20 src/app.py'
expect allow $R 'git -C /work/acme-api status --porcelain'
expect allow $R 'git -C /work/acme-api ls-remote --heads origin "claude/api-1-*"'
expect allow $R 'git -C /work/acme-api merge-base --is-ancestor abc origin/main'
expect allow $R 'git -c core.pager=cat -C /work/acme-api log -3'
expect allow $R 'git -c color.ui=false -C /work/acme-api log -3'
expect allow $R 'git --no-pager -C /work/acme-api diff --stat'
expect allow $R 'git -C /work/acme-api branch'
expect allow $R 'git -C /work/acme-api branch -a'
expect allow $R 'git -C /work/acme-api branch -vv'
expect allow $R 'git -C /work/acme-api branch -avv'
expect allow $R 'git -C /work/acme-api branch --merged origin/main'
expect allow $R 'git -C /work/acme-api branch --show-current'
expect allow $R 'git -C /work/acme-api tag -l "v1.*"'
expect allow $R 'git -C /work/acme-api worktree list'
expect allow $R 'git -C /work/acme-api remote get-url origin'
expect allow $R 'git -C /work/acme-api remote -v'
expect allow $R 'git -C /work/acme-api symbolic-ref --short refs/remotes/origin/HEAD'
expect allow $R 'git -C /work/acme-api symbolic-ref --short refs/remotes/origin/HEAD 2>&1'
expect allow $R 'git -C /work/acme-api config --get remote.origin.url'
expect allow $R 'git -C /work/acme-api check-ignore -q .claude/worktrees/x'
expect deny  $R 'git -C /work/acme-api checkout main'
expect deny  $R 'git -C /work/acme-api commit -m "fix"'
expect deny  $R 'git -C /work/acme-api push origin HEAD'
expect deny  $R 'git -C /work/acme-api add -A'
expect deny  $R 'git -C /work/acme-api reset --hard'
expect deny  $R 'git -C /work/acme-api stash'
expect deny  $R 'git -C /work/acme-api branch new-branch'
expect deny  $R 'git -C /work/acme-api branch -D old'
expect deny  $R 'git -C /work/acme-api branch -m a b'
expect deny  $R 'git -C /work/acme-api branch -rd origin/foo'
expect deny  $R 'git -C /work/acme-api branch -vd foo'
expect deny  $R 'git -C /work/acme-api branch -v new-branch'
expect deny  $R 'git -C /work/acme-api tag v2'
expect deny  $R 'git -C /work/acme-api tag -d v1'
expect deny  $R 'git -C /work/acme-api tag -am msg v2'
expect deny  $R 'git -C /work/acme-api worktree add ../x -b y'
expect deny  $R 'git -C /work/acme-api worktree remove ../x'
expect deny  $R 'git -C /work/acme-api remote set-head origin --auto'
expect deny  $R 'git -C /work/acme-api remote add up git@x:y/z'
expect deny  $R 'git -C /work/acme-api symbolic-ref HEAD refs/heads/other'
expect deny  $R 'git -C /work/acme-api symbolic-ref -d refs/remotes/origin/HEAD'
expect deny  $R 'git -C /work/acme-api symbolic-ref --delete HEAD'
expect deny  $R 'git -C /work/acme-api symbolic-ref -q -d HEAD'
expect deny  $R 'git -C /work/acme-api config user.name me'
expect deny  $R 'git -C /work/acme-api config --unset user.name'
expect deny  $R 'git -C /work/acme-api grep -Ovim foo'
expect deny  $R 'git -C /work/acme-api grep -nO foo'
expect deny  $R 'git'
expect deny  $R 'git -C /work/acme-api --exec-path=/tmp diff'
# fetch: remote-tracking refs are fine; the checkout's own refs are not.
expect allow $R 'git -C /work/acme-api fetch origin main'
expect allow $R 'git -C /work/acme-api fetch -q origin'
expect allow $R 'git -C /work/acme-api fetch --all'
expect allow $R 'git -C /work/acme-api fetch origin main feature/x'
expect deny  $R 'git -C /work/acme-api fetch . HEAD:refs/heads/main'
expect deny  $R 'git -C /work/acme-api fetch -f origin x:main'
expect deny  $R 'git -C /work/acme-api fetch origin +refs/heads/x:refs/heads/x'
expect deny  $R 'git -C /work/acme-api fetch --prune origin'
expect deny  $R 'git -C /work/acme-api fetch -qp origin'
expect deny  $R "git -C /work/acme-api fetch --stdin . <<< 'HEAD:refs/heads/x'"
expect deny  $R "printf 'HEAD:refs/heads/x\\n' | git -C /work/acme-api fetch --stdin ."
expect deny  $R 'git ls-remote --upload-pack=/tmp/x origin'
# Configuration and environment that make an allowlisted subcommand run a program or write.
expect deny  $R 'git -c core.fsmonitor=/tmp/x status'
expect deny  $R 'git -c diff.external=/tmp/x diff'
expect deny  $R 'git -c core.sshCommand=/tmp/x fetch origin'
expect deny  $R 'git -c "core.pager=less; rm -rf /tmp/x" log'
expect deny  $R 'git -ccore.pager=/tmp/x log'
expect deny  $R 'git -c alias.ro="!rm -rf x" ro'
expect deny  $R 'GIT_SSH_COMMAND=/tmp/x git fetch origin'
expect deny  $R 'GIT_EXTERNAL_DIFF=/tmp/x git diff'
expect deny  $R 'GIT_PAGER="rm -rf /tmp/x" git log'
expect deny  $R 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=/tmp/x git status'
expect deny  $R 'PATH=/tmp/evil:/usr/bin git log'
expect deny  $R 'git diff --output=/tmp/x'
expect deny  $R 'git log --output /tmp/x'
expect deny  $R 'git diff --ext-diff'
expect deny  $R 'git --config-env=core.pager=X log'

# ------------------------------------------------------------------------ gh
V=validator
expect allow $V 'gh pr checks claude/api-2-x -R acme/acme-api'
expect allow $V 'gh pr list -R acme/acme-api --head claude/api-2-x --state all --json number,state'
expect allow $V 'gh pr view 104 -R acme/acme-api --json mergeCommit,mergedAt'
expect allow $V 'gh api repos/acme/acme-api/pulls/104'
expect allow $V 'gh api -X GET repos/acme/acme-api/pulls/104'
expect allow $V 'gh api -XGET -H "Accept: application/json" repos/acme/acme-api/pulls/104'
expect allow $V 'gh api --paginate -q ".[].number" repos/acme/acme-api/pulls'
expect deny  $V 'gh pr merge 104 -R acme/acme-api'
expect deny  $V 'gh pr edit 104 --body x'
expect deny  $V 'gh pr create --title t --body b'
expect deny  $V 'gh pr ready --undo 104'
expect deny  $V 'gh api -X POST repos/acme/acme-api/issues'
expect deny  $V 'gh api repos/acme/acme-api/issues -f title=x'
expect deny  $V 'gh api repos/acme/acme-api/issues -fbody=x'
expect deny  $V 'gh api repos/acme/acme-api/issues -XPOST'
expect deny  $V 'gh issue create --title x'
expect deny  $V 'gh pr view 104 -R acme/acme-api -c -w'
expect deny  $V 'gh pr view 104 -R acme/acme-api -c -w=1'
expect deny  $V 'gh issue view 7 -c -w=true'
expect deny  $V 'gh auth status -t -a'
expect deny  $V 'gh auth status -t'
expect deny  $V 'gh auth status --show-token'
expect allow $V 'gh auth status -a'
expect allow $V 'gh auth status -h github.com'
expect allow $V 'gh pr view 104 -R acme/acme-api --comments'

# --------------------------------------------------------- shells, pipes, files
expect allow $R 'ls -la /work/acme-api/src'
expect allow $R 'ls "a b"'
expect allow $R 'find /work/acme-api -maxdepth 3 -iname "decisions*" -not -path "*/node_modules/*" 2>/dev/null'
expect allow $R 'git -C /work/acme-api show origin/main:README.md | tr "\n" " " | grep -oE "open at [^.]+"'
expect allow $R 'cd /work/acme-api && git log --oneline -5 && git status --porcelain'
expect allow $R 'ls -a /work/acme-api | grep -i -E "^(agents|claude|contributing|decisions|readme)\.md$"'
expect allow $R 'git -C /work/acme-api grep -n foo origin/main -- src/ || true'
expect allow $R 'cat /work/acme-api/CONTRIBUTING.md | head -50; wc -l /work/acme-api/README.md'
expect allow $R 'git -C /work/acme-api diff origin/main...HEAD -- src/ 2>/dev/null | head -200'
expect allow $R 'GIT_PAGER=cat git -C /work/acme-api log -1'
expect allow $R 'LC_ALL=C sort /work/acme-api/words.txt | uniq -c'
expect allow $R '(cd /work/acme-api && git log -1)'
expect allow $R 'jq -r ".version" /work/acme-api/package.json'
expect allow $R 'grep -rn "->" /work/acme-api/src'
expect allow $R "git -C /work/acme-api log --format='%h -> %s' -5"
expect allow $R 'git -C /work/acme-api grep -n "a|b" origin/main -- src/'
expect allow $R 'sort -u /work/acme-api/words.txt'
expect allow $R 'sort -un /work/acme-api/in.txt'
expect allow $R "grep -E 'a\\|b' /work/acme-api/f"
expect allow $R 'git -C /work/acme-api log --format="%h\\n" -3'
expect allow $R '/usr/bin/cat /work/acme-api/README.md'
expect allow $R '/usr/bin/grep -c "sentence" /work/acme-api/README.md'
expect allow $R $'git -C /work/acme-api log \\\n  --oneline -3'
expect deny  $R $'git -C /work/acme-api log \\\n  --oneline -3 && rm -rf /tmp/x'
expect deny  $R 'git -C /work/acme-api log -1 && rm -f notes.txt'
expect deny  $R 'ls & rm -rf /tmp/x'
expect deny  $R 'git -C /work/acme-api log & git -C /work/acme-api push'
expect deny  $R 'git -C /work/acme-api diff > /tmp/diff.txt'
expect deny  $R 'git -C /work/acme-api diff >> /tmp/diff.txt'
expect deny  $R 'echo hi > file.txt'
expect deny  $R 'echo "$(git -C /work/acme-api rev-parse HEAD)"'
expect deny  $R 'cat `ls`'
expect deny  $R 'diff <(git show a:f) <(git show b:f)'
# Expansions bash would perform after the guard has read the words.
expect deny  $R "find /work -name '*.py' \$'-exec' rm -rf {} \\;"
expect deny  $R 'find /work -name "*.py" ${HOME:0:0}-exec rm -rf {} \;'
expect deny  $R 'TERM=-exec; find /work -name "*.py" $TERM rm -rf {} \;'
expect deny  $R "find /work -name '*.py' \$'-delete'"
expect deny  $R "git -C /work log \$'--output=/tmp/evil'"
expect deny  $R 'git -C /work log --{output=/tmp/evil,}'
expect deny  $R "printf evil | sort \$'-o'/tmp/evil"
expect deny  $R 'cat "$HOME/.ssh/id_rsa"'
expect deny  $R 'cat ${HOME}/x'
expect deny  $R 'ls /work/{a,b}'
expect allow $R "grep -c '^\$' /work/acme-api/f"
expect allow $R 'grep -E "foo$|bar$" /work/acme-api/f'
expect allow $R 'git -C /work/acme-api grep -nE "TODO$" origin/main -- src/'
expect deny  $R 'grep -E "foo$HOME" /work/acme-api/f'
expect deny  $R 'find /work -name "*.py" $"-exec" rm -rf {} \;'
expect deny  $R "TERM=-exec; find /work -name \"'\" -o -name \"*.py\" \"\$TERM\" rm -rf {} \\; -o -name \"'\""
expect deny  $R "echo \"it's\" \"\$HOME\" 'x'"
expect allow $R "grep -c \"don't\" /work/acme-api/f"
expect allow $R "grep -c \"it's\" /work/acme-api/f | grep -v '\$x'"
# Function definitions, and parentheses that are not a subshell wrapper.
expect deny  $R 'ls () ( rm -rf /tmp/x ); ls'
expect deny  $R 'f() { rm -rf /tmp/x; }; f'
expect deny  $R 'function ls { rm -rf /tmp/x; }; ls'
expect deny  $R 'ls $((1+1))'
expect allow $R 'grep -E "(a|b)" /work/acme-api/f'
expect allow $R 'find /work \( -name "a*" -o -name "b*" \) -print'
# Unquoted globs are expanded against the working directory, so they are denied.
expect deny  $R 'find /work -name "*.py" -exe[c] rm -rf {} \;'
expect deny  $R 'sort /work/f -[o] /tmp/x'
expect deny  $R 'git -C /work/repo branch -[D] feature -a'
expect deny  $R 'ls *.md'
expect deny  $R 'gh api repos/acme/acme-api/pulls?state=all'
expect allow $R 'ls "*.md"'
expect allow $R "gh api 'repos/acme/acme-api/pulls?state=all'"
expect allow $R '[ -f /work/acme-api/README.md ] && cat /work/acme-api/README.md'
expect allow $R 'test -d /work/acme-api/src'
# git config read forms only.
expect allow $R 'git -C /work/acme-api config get remote.origin.url'
expect allow $R 'git -C /work/acme-api config list'
expect allow $R 'git -C /work/acme-api config -l'
expect deny  $R 'git -C /work/acme-api config rename-section remote.origin get'
expect deny  $R 'git -C /work/acme-api config remove-section get'
expect deny  $R 'git -C /work/acme-api config edit get'
expect deny  $R 'git -C /work/acme-api config set user.name get'
expect deny  $R 'git -C /work/acme-api config -e'
# A quoted operator is an argument, and the word after it is checked like any other.
expect deny  $R 'find /work ! -name "<" -delete'
expect deny  $R 'rg x /work ">" --pre /work/repo/tools/evil.sh'
expect deny  $R 'sort /work/f "2>" -o /tmp/x'
expect deny  $R 'git -C /work/repo branch -r "<" -D origin/feature'
expect allow $R 'grep -c ">" /work/acme-api/f'
expect allow $R "grep -c '<' /work/acme-api/f 2>/dev/null"

# A checker that cannot run denies rather than falling through.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/perl"; chmod +x "$TMP/bin/perl"
out=$(jq -n '{tool_name:"Bash",agent_type:"reviewer",tool_input:{command:"ls /work"}}' | PATH="$TMP/bin:$PATH" guard 2>/dev/null)
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then ok "perl failing -> deny"; else bad "perl failing -> deny" "got: $out"; fi
expect allow $R 'echo \$HOME'
expect allow $R 'git -C /work/acme-api log -L10,20:src/a.py'
expect allow $R 'find /work -name "*.py" -newer /work/x'
expect allow $R "git -C /work/acme-api log --format='%h {%an}' -3"
expect deny  $R "echo \\' ; rm -rf /tmp/x \\'"
expect deny  $R "ls \\' | tee /tmp/x \\'"
expect deny  $R 'echo \" ; rm -rf /tmp/x \"'
expect deny  $R "ls '; rm -rf /tmp/x"
expect deny  $R 'find /work -name "*.tmp" -delete'
expect deny  $R 'find /work -name "*.py" -exec rm {} \;'
expect deny  $R 'tee /tmp/out.txt'
expect deny  $R 'xargs rm'
expect deny  $R 'npm test'
expect deny  $R 'bash -c "rm -rf /tmp/x"'
expect deny  $R 'ls | python3'
expect deny  $R 'sudo ls'
expect deny  $R 'env GIT_SSH_COMMAND=/tmp/x git fetch'
expect deny  $R 'sort -o /tmp/out /work/acme-api/words.txt'
expect deny  $R 'sort -uo /tmp/out /work/acme-api/in.txt'
expect deny  $R 'sort --compress-program=/tmp/x /work/acme-api/words.txt'
expect deny  $R 'uniq /work/acme-api/in /tmp/out'
expect deny  $R 'rg --pre /tmp/x pattern /work/acme-api'
expect deny  $R 'rg --color=always --hostname-bin=/work/repo/tools/evil.sh x /work'
expect deny  $R 'rg --hostname-bin /work/repo/tools/evil.sh x /work'
expect allow $R 'rg -n "TODO" /work/acme-api/src'
expect deny  $R 'file -C -m /work/repo/magic'
expect deny  $R 'file --comp -m /work/repo/magic'
expect deny  $R 'file /work/acme-api/README.md'
# Long options abbreviated the way getopt_long and git accept them.
expect deny  $R 'git -C /work/acme-api log --outp=/tmp/x'
expect deny  $R 'git -C /work/acme-api diff --ext-d'
expect deny  $R 'git -C /work/acme-api fetch --pru origin'
expect deny  $R 'git -C /work/acme-api fetch --std .'
expect deny  $R 'git -C /work/acme-api fetch --forc origin x:y'
expect deny  $R 'git -C /work/acme-api branch --del foo'
expect deny  $R 'git -C /work/acme-api symbolic-ref --del HEAD'
expect deny  $R 'git -C /work/acme-api tag --ann v2'
expect deny  $R 'git -C /work/acme-api config --uns user.name'
expect deny  $R 'git -C /work/acme-api ls-remote --upload-p=/tmp/x origin'
expect deny  $R 'sort --out /tmp/x /work/acme-api/f'
expect deny  $R 'sort --compress-prog=/tmp/x /work/acme-api/f'
expect deny  $R 'rg --hostname-b=/tmp/x pattern /work'
expect allow $R 'git -C /work/acme-api log --stat -3'
expect allow $R 'git -C /work/acme-api diff --staged'
expect allow $R 'git -C /work/acme-api log --no-merges -3'
expect deny  $R 'git -C /work/acme-api fetch --depth 1 origin main'   # shallows the human's clone
expect deny  $R 'git -C /work/acme-api fetch --shallow-since=2026-01-01 origin'
expect deny  $R 'git -C /work/acme-api fetch --filter=blob:none origin'   # makes the clone partial
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
expect allow $R 'find /work \( -name "a*" -o -name "b*" \)'
expect allow $R '(find /work \( -name "a*" -o -name "b*" \))'
expect allow $R 'git -C /work/acme-api log --format="%h %s" -3'
expect allow $R 'git -C /work/acme-api show --stat HEAD'
expect deny  $R 'sort --o /tmp/out /work/acme-api/f'
expect deny  $R 'git -C /work/acme-api symbolic-ref --d refs/remotes/origin/HEAD'
expect deny  $R "git -C /work/acme-api ls-remote --u='touch /tmp/pwned' file:///work/acme-api"
expect deny  $R 'git -C /work/acme-api log --o=/tmp/x'
expect allow $R 'git -C /work/acme-api log -- src/'
# An empty word must not crash the guard: bash 3.2 treats an empty array as unbound.
expect deny  $R "''; rm -rf /tmp/x"
expect deny  $R '"" ; rm -rf /tmp/x'
expect deny  $R "'' ls /work/acme-api"   # an empty command name; bash rejects it too
expect deny  $R './tools/git log'
expect deny  $R '/work/acme-api/node_modules/.bin/cat x'
expect deny  $R '/tmp/git log'
expect deny  $R '/usr/bin/rm -rf /tmp/x'
expect deny  $R '/usr/bin/../../tmp/cat x'
expect deny  $R '/bin/../tmp/git log'

# ------------------------------------------------- options are an allowlist
# An option is allowed by its full spelling on its program's list, or not at all.
expect allow $R 'git -C /work/acme-api log --since="1 week ago" --until 2024-06-01 -5'
expect allow $R 'git -C /work/acme-api log -n 5 --author=me --format %h'
expect allow $R 'git -C /work/acme-api log -n5 -p -S useSession -- src/'
expect allow $R 'git -C /work/acme-api diff --no-color --name-status -M90% origin/main...HEAD'
expect allow $R 'git -C /work/acme-api diff --no-such-thing origin/main'   # --no-<anything> only switches off
expect allow $R 'git -C /work/acme-api show -s --format=%H HEAD'
expect allow $R 'git -C /work/acme-api rev-list --count origin/main..HEAD'
expect allow $R 'git -C /work/acme-api shortlog -sn origin/main..HEAD'
expect allow $R 'git -C /work/acme-api status -uno --porcelain'
# A value shaped like an option is denied even after -e: `-U --stat` and `-e -foo` look alike.
expect deny  $R 'git -C /work/acme-api grep -A2 -B 2 -e -foo -- src/'
expect allow $R "git -C /work/acme-api grep -A2 -B 2 -e '[-]foo' -- src/"
expect allow $R 'git -C /work/acme-api grep -A2 -B 2 -e -foo:bar -- src/'
expect deny  $R 'git -C /work/acme-api grep -A2 -B 2 -e -foo=bar -- src/'
expect allow $R 'git -C /work/acme-api branch --merged'
expect allow $R 'git -C /work/acme-api branch -r --sort=-committerdate'
expect allow $R 'git -C /work/acme-api tag -n3 "v1.*"'
expect allow $R 'git -C /work/acme-api config --file /tmp/cfg --get a.b'
expect allow $R 'git -C /work/acme-api fetch --jobs 4 origin'
expect allow $R 'git -C /work/acme-api remote show -n origin'
expect allow $R 'git -C /work/acme-api remote get-url --push origin'
expect allow $R 'git -C /work/acme-api cat-file -p HEAD:README.md'
expect allow $R 'git -C /work/acme-api for-each-ref --format="%(refname:short)" --sort=-committerdate refs/heads/'
expect deny  $R 'git -C /work/acme-api log --unknown-option -1'
expect deny  $R 'git -C /work/acme-api log --show-signature -1'
expect deny  $R 'git -C /work/acme-api log --help'
expect deny  $R 'git -C /work/acme-api log -n'
expect deny  $R 'git -C /work/acme-api diff -O/tmp/order'
expect deny  $R 'git -C /work/acme-api branch --sort -committerdate -r'   # a separate value with a dash

# A `#` comment and a here-document: bash reads no quote inside either, the mask would, and
# the two would disagree about where the next command starts.
expect deny  $R $'true # it\'s\ntouch pwned\necho x #\''
expect deny  $R 'ls # list'
expect allow $R "grep '#include' src/main.c"
expect allow $R 'ls a#b'
expect deny  $R $'cat <<EOF\nx\nEOF'
expect deny  $R $'cat <<-\'EOF\'\nx\nEOF'
expect allow $R "jq . <<< '{}'"

# printf -v assigns a variable; with PATH, the next command runs from the repository.
expect deny  $R 'printf -v PATH %s tools:/usr/bin; git status'
expect deny  $R 'printf -vPATH %s tools:/usr/bin; git status'
expect allow $R "printf '%s\n' x"
expect allow $R 'printf -- -v'

# A bare repository committed in the diff carries a config git would obey; -C may not reach
# one, and --git-dir, --work-tree and --bare name one outright.
GUARD_TMP=$(mktemp -d)
mkdir -p "$GUARD_TMP/x.git/objects" "$GUARD_TMP/x.git/refs" "$GUARD_TMP/x.git/sub" "$GUARD_TMP/repo/.git"
: > "$GUARD_TMP/x.git/HEAD"
expect deny  $R "git -C $GUARD_TMP/x.git diff HEAD~1 HEAD"
expect deny  $R "git -C $GUARD_TMP/x.git/sub log"           # discovery walks up into the bare repo
expect deny  $R "git -C $GUARD_TMP/repo -C ../x.git log"    # a second -C is relative to the first
expect allow $R "git -C $GUARD_TMP/repo status"
expect allow $R "git -C $GUARD_TMP/repo -C . status"
expect allow $R 'git -C /work/acme-api status'              # a directory that does not exist is git's error
expect deny  $R "git --git-dir=$GUARD_TMP/x.git --work-tree=. status"
expect deny  $R "git --git-dir $GUARD_TMP/x.git status"
expect deny  $R "git --work-tree=. status"
expect deny  $R "git --bare -C $GUARD_TMP/x.git log"
# A relative -C resolves against the hook input's cwd, and against the guard's own when it has none.
cwd_decision() { # cwd command -> allow | deny
  local out
  out=$(jq -n --arg d "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:"ontherun:reviewer",cwd:$d,tool_input:{command:$c}}' | guard 2>&1)
  if [ -z "$out" ]; then printf 'allow\n'; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
expect_cwd() { # allow|deny cwd command
  local got; got=$(cwd_decision "$2" "$3")
  if [ "$got" = "$1" ]; then ok "$1  [cwd] $3"; else bad "$1  [cwd] $3" "got: $got"; fi
}
expect_cwd deny  "$GUARD_TMP" 'git -C x.git log'
expect_cwd allow "$GUARD_TMP" 'git -C repo log'
got=$(cd "$GUARD_TMP" && decision $R 'git -C x.git log')
if [ "$got" = deny ]; then ok "deny  [pwd] git -C x.git log"; else bad "deny  [pwd] git -C x.git log" "got: $got"; fi
rm -rf "$GUARD_TMP"
expect deny  $R 'git -C /work/acme-api fetch --auto-maintenance origin'
expect deny  $R 'git -C /work/acme-api fetch --write-commit-graph origin'
expect deny  $R 'git -C /work/acme-api remote -v add up git@x:y/z'
expect deny  $R 'git -C /work/acme-api remote get-url --add origin'
expect deny  $R 'git -C /work/acme-api grep --open-files-in-pager foo'
expect deny  $R 'git -C /work/acme-api for-each-ref --contains'
expect deny  $V 'gh pr view 104 -R acme/acme-api --web'
expect deny  $V 'gh pr view 104 -w'
expect deny  $V 'gh pr list -R acme/acme-api --unknown'
expect allow $V 'gh pr list -R acme/acme-api --search "-label:wontfix" -L 50'
expect allow $V 'gh run view 123 -R acme/acme-api --log'
expect allow $V 'gh api -i -H "Accept: application/json" repos/acme/acme-api/pulls/104'
expect deny  $V 'gh api -iXPOST repos/acme/acme-api/issues'
expect deny  $V 'gh api repos/acme/acme-api/issues --input body.json'
expect deny  $V 'gh api repos/acme/acme-api/issues -F title=@body.json'
expect deny  $V 'gh api repos/acme/acme-api/issues --raw-field title=x'
expect allow $R 'find /work -mtime -1 -size +1M -print'
expect allow $R 'find /work -type f -name "*.md" -print0'
expect deny  $R 'find /work -name "*.log" -fprintf /tmp/x "%p"'
expect deny  $R 'find /work -name x -fprint0 /tmp/x'
expect deny  $R 'find /work -unknown'
expect allow $R 'sort -t: -k2,2n /work/f'
expect allow $R 'sort -k 2 -r /work/f'
expect deny  $R 'sort -T /tmp /work/f'
expect deny  $R 'sort --temporary-directory=/tmp /work/f'
expect allow $R 'uniq -f 1 /work/f'
expect allow $R 'uniq --skip-fields=1 /work/f'
expect deny  $R 'uniq -f 1 /work/f /tmp/out'
expect allow $R 'rg -tpy -g "!vendor" -C 2 x /work'
expect allow $R 'rg --color always -n x /work'
expect deny  $R 'rg --pre-glob "*.pdf" x /work'
expect deny  $R 'rg --unknown x /work'
expect allow $R 'date -u'
expect allow $R 'date -Iseconds'
expect deny  $R 'date -s "2020-01-01"'
expect deny  $R 'date --set=2020-01-01'
expect allow $R 'rg --help | grep -n hyperlink'
expect allow $V 'gh pr list --help'
expect deny  $R 'git -C /work/acme-api diff --help'   # opens the manual in a pager

# ------------------------------------------- sed, awk, curl and wget are out entirely
P=plan-reviewer
expect deny  $R 'sed -n "10,20p" /work/acme-api/src/app.py'
expect deny  $R 'sed -i "s/a/b/" /work/acme-api/src/app.py'
expect deny  $R "awk '{print \$1}' /work/acme-api/data.txt"
expect deny  $R "awk 'BEGIN{system (\"rm -rf /tmp/x\")}'"
expect deny  $P 'curl -sL https://example.com/pricing'
expect deny  $P 'curl -s -o /dev/null -w "%output{/tmp/x}rm -rf /" https://example.com/'
expect deny  $P 'curl -sSo /tmp/x https://example.com/'
expect deny  $P 'wget -q https://example.com/file'
expect deny  $R 'git -C /work/acme-api log -1 | sed -n 1p'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$inner_rc" -eq 0 ]
