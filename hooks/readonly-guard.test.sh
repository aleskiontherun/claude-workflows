#!/usr/bin/env bash
# Tests for readonly-guard.sh. No framework: each case feeds the guard one hook input on
# stdin and asserts whether it denied the call.
#
#   readonly-guard.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs jq and perl.
# shellcheck disable=SC2016  # the cases are command text, not expressions to expand

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GUARD="$SCRIPT_DIR/readonly-guard.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }

decision() { # agent_type command -> allow | deny | <error>
  local out status
  out=$(jq -n --arg a "$1" --arg c "$2" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:$a,tool_input:{command:$c}} | if $a == "" then del(.agent_type) else . end' \
    | "$GUARD" 2>&1); status=$?
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

echo "readonly-guard.sh"

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
out=$(printf 'not json' | "$GUARD" 2>&1); status=$?
if [ $status -eq 0 ] && [ -z "$out" ]; then ok "non-JSON stdin -> no decision"; else bad "non-JSON stdin -> no decision" "exit $status: $out"; fi
out=$(jq -n '{tool_name:"Bash",agent_type:"reviewer",tool_input:{}}' | "$GUARD" 2>&1); status=$?
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
out=$(jq -n '{tool_name:"Bash",agent_type:"reviewer",tool_input:{command:"ls /work"}}' | PATH="$TMP/bin:$PATH" "$GUARD" 2>/dev/null)
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
expect deny  $R 'file --compile -m /work/repo/magic'
expect allow $R 'file /work/acme-api/README.md'
expect deny  $R './tools/git log'
expect deny  $R '/work/acme-api/node_modules/.bin/cat x'
expect deny  $R '/tmp/git log'
expect deny  $R '/usr/bin/rm -rf /tmp/x'
expect deny  $R '/usr/bin/../../tmp/cat x'
expect deny  $R '/bin/../tmp/git log'

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
[ "$fail" -eq 0 ]
