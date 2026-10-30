#!/usr/bin/env bash
# Tests for wf-readonly-guard.sh. No framework: each case feeds the guard one hook input on
# stdin and asserts whether it denied the call.
#
#   wf-readonly-guard.test.sh
#
# Exits 0 if every case passes, 1 otherwise. Needs jq.
# shellcheck disable=SC2016  # the cases are command text, not expressions to expand

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GUARD="$SCRIPT_DIR/wf-readonly-guard.sh"

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
  if [ "$got" = "$want" ]; then ok "$want  [$agent] $cmd"
  else bad "$want  [$agent] $cmd" "got: $got"; fi
}

echo "wf-readonly-guard.sh"

# ------------------------------------------------------------- who it applies to
expect allow ""                 'rm -rf build'
expect allow "general-purpose"  'rm -rf build'
expect allow "implementer"   'git push -u origin HEAD'
expect allow "ontherun:implementer" 'git commit -m x'
expect allow "verifier"      'npm test'
expect deny  "reviewer"      'rm -rf build'
expect deny  "ontherun:reviewer"   'rm -rf build'
expect deny  "ontherun:validator"  'git commit -m x'
expect deny  "plan-reviewer" 'git push'
expect deny  "plan-validator" 'touch x'
expect deny  "fold-checker"  'python3 -c "print(1)"'

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
expect allow $R 'git -C /work/acme-api fetch origin main'
expect allow $R 'git -C /work/acme-api status --porcelain'
expect allow $R 'git -C /work/acme-api ls-remote --heads origin "claude/api-1-*"'
expect allow $R 'git -C /work/acme-api merge-base --is-ancestor abc origin/main'
expect allow $R 'git -c core.pager=cat -C /work/acme-api log -3'
expect allow $R 'git --no-pager -C /work/acme-api diff --stat'
expect allow $R 'git -C /work/acme-api branch'
expect allow $R 'git -C /work/acme-api branch -a'
expect allow $R 'git -C /work/acme-api branch --merged origin/main'
expect allow $R 'git -C /work/acme-api branch --show-current'
expect allow $R 'git -C /work/acme-api tag -l "v1.*"'
expect allow $R 'git -C /work/acme-api worktree list'
expect allow $R 'git -C /work/acme-api remote get-url origin'
expect allow $R 'git -C /work/acme-api remote -v'
expect allow $R 'git -C /work/acme-api symbolic-ref --short refs/remotes/origin/HEAD'
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
expect deny  $R 'git -C /work/acme-api tag v2'
expect deny  $R 'git -C /work/acme-api tag -d v1'
expect deny  $R 'git -C /work/acme-api worktree add ../x -b y'
expect deny  $R 'git -C /work/acme-api worktree remove ../x'
expect deny  $R 'git -C /work/acme-api remote set-head origin --auto'
expect deny  $R 'git -C /work/acme-api remote add up git@x:y/z'
expect deny  $R 'git -C /work/acme-api symbolic-ref HEAD refs/heads/other'
expect deny  $R 'git -C /work/acme-api config user.name me'
expect deny  $R 'git -C /work/acme-api config --unset user.name'
expect deny  $R 'git'
expect deny  $R 'git -C /work/acme-api --exec-path=/tmp diff'

# --------------------------------------------------------------- gh and curl
V=validator
expect allow $V 'gh pr checks claude/api-2-x -R acme/acme-api'
expect allow $V 'gh pr list -R acme/acme-api --head claude/api-2-x --state all --json number,state'
expect allow $V 'gh pr view 104 -R acme/acme-api --json mergeCommit,mergedAt'
expect allow $V 'gh api repos/acme/acme-api/pulls/104'
expect allow $V 'gh api -X GET repos/acme/acme-api/pulls/104'
expect deny  $V 'gh pr merge 104 -R acme/acme-api'
expect deny  $V 'gh pr edit 104 --body x'
expect deny  $V 'gh pr create --title t --body b'
expect deny  $V 'gh pr ready --undo 104'
expect deny  $V 'gh api -X POST repos/acme/acme-api/issues'
expect deny  $V 'gh api repos/acme/acme-api/issues -f title=x'
expect deny  $V 'gh issue create --title x'
P=plan-reviewer
expect allow $P 'curl -sL https://example.com/pricing'
expect allow $P 'curl -sI https://example.com/'
expect allow $P 'curl -s -o /dev/null -w "%{http_code}" https://example.com/'
expect allow $P 'curl -s -X GET -H "Accept: text/html" https://example.com/'
expect deny  $P 'curl -X POST -d x=1 https://example.com/'
expect deny  $P 'curl --data-urlencode q=1 https://example.com/'
expect deny  $P 'curl -o page.html https://example.com/'
expect deny  $P 'curl -O https://example.com/file.zip'
expect deny  $P 'curl -T file https://example.com/'

# --------------------------------------------------------- shells, pipes, files
expect allow $R 'ls -la /work/acme-api/src'
expect allow $R 'find /work/acme-api -maxdepth 3 -iname "decisions*" -not -path "*/node_modules/*" 2>/dev/null'
expect allow $R 'git -C /work/acme-api show origin/main:README.md | tr "\n" " " | grep -oE "open at [^.]+"'
expect allow $R 'cd /work/acme-api && git log --oneline -5 && git status --porcelain'
expect allow $R 'ls -a /work/acme-api | grep -i -E "^(agents|claude|contributing|decisions|readme)\.md$"'
expect allow $R 'git -C /work/acme-api grep -n foo origin/main -- src/ || true'
expect allow $R 'cat /work/acme-api/CONTRIBUTING.md | head -50; wc -l /work/acme-api/README.md'
expect allow $R 'git -C /work/acme-api diff origin/main...HEAD -- src/ 2>/dev/null | head -200'
expect allow $R 'GIT_PAGER=cat git -C /work/acme-api log -1'
expect allow $R 'sed -n "10,20p" /work/acme-api/src/app.py'
expect allow $R "awk '{print \$1}' /work/acme-api/data.txt"
expect allow $R '(cd /work/acme-api && git log -1)'
expect allow $R 'jq -r ".version" /work/acme-api/package.json'
expect allow $R 'grep -rn "->" /work/acme-api/src'
expect allow $R "git -C /work/acme-api log --format='%h -> %s' -5"
expect allow $R 'git -C /work/acme-api grep -n "a|b" origin/main -- src/'
expect deny  $R 'curl -s -o "/dev/null" https://example.com/'
expect deny  $R 'git -C /work/acme-api log -1 && rm -f notes.txt'
expect deny  $R 'git -C /work/acme-api diff > /tmp/diff.txt'
expect deny  $R 'git -C /work/acme-api diff >> /tmp/diff.txt'
expect deny  $R 'echo hi > file.txt'
expect deny  $R 'echo "$(git -C /work/acme-api rev-parse HEAD)"'
expect deny  $R 'cat `ls`'
expect deny  $R 'diff <(git show a:f) <(git show b:f)'
expect deny  $R 'find /work -name "*.tmp" -delete'
expect deny  $R 'find /work -name "*.py" -exec rm {} \;'
expect deny  $R 'sed -i "s/a/b/" /work/acme-api/src/app.py'
expect deny  $R "awk 'BEGIN{system(\"rm -rf /tmp/x\")}'"
expect deny  $R 'tee /tmp/out.txt'
expect deny  $R 'xargs rm'
expect deny  $R 'npm test'
expect deny  $R 'bash -c "rm -rf /tmp/x"'
expect deny  $R 'ls | python3'
expect deny  $R 'sudo ls'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
