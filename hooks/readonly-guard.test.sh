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
  if [ "$got" = "$want" ]; then ok "$want  [$agent] $cmd"
  else bad "$want  [$agent] $cmd" "got: $got"; fi
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
expect allow $R 'git -C /work/acme-api fetch origin main'
expect allow $R 'git -C /work/acme-api status --porcelain'
expect allow $R 'git -C /work/acme-api ls-remote --heads origin "claude/api-1-*"'
expect allow $R 'git -C /work/acme-api merge-base --is-ancestor abc origin/main'
expect allow $R 'git -c core.pager=cat -C /work/acme-api log -3'
expect allow $R 'git -c color.ui=false -C /work/acme-api log -3'
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
expect deny  $R 'git grep -Ovim foo'
expect deny  $R 'git ls-remote --upload-pack=/tmp/x origin'
expect deny  $R 'git diff --ext-diff'
expect deny  $R 'git --config-env=core.pager=X log'
# Clustered and attached short options.
expect deny  $R 'git -C /work/acme-api branch -rd origin/foo'
expect deny  $R 'git -C /work/acme-api branch -vd foo'
expect deny  $R 'git -C /work/acme-api branch -v new-branch'
expect allow $R 'git -C /work/acme-api branch -vv'
expect allow $R 'git -C /work/acme-api branch -avv'
expect deny  $R 'git -C /work/acme-api tag -am msg v2'
expect deny  $R 'git -C /work/acme-api symbolic-ref -d refs/remotes/origin/HEAD'
expect deny  $R 'git -C /work/acme-api symbolic-ref --delete HEAD'
expect deny  $R 'git -C /work/acme-api symbolic-ref -q -d HEAD'
expect deny  $R 'git -C /work/acme-api grep -nO foo'

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
expect deny  $V 'gh api repos/acme/acme-api/issues -fbody=x'
expect deny  $V 'gh api repos/acme/acme-api/issues -XPOST'
expect allow $V 'gh api -XGET -H "Accept: application/json" repos/acme/acme-api/pulls/104'
expect allow $V 'gh api --paginate -q ".[].number" repos/acme/acme-api/pulls'
P=plan-reviewer
expect allow $P 'curl -sL https://example.com/pricing'
expect allow $P 'curl -sI https://example.com/'
expect allow $P 'curl -s -o /dev/null -w "%{http_code}" https://example.com/'
expect allow $P 'curl -s -o "/dev/null" https://example.com/'
expect allow $P 'curl -s -X GET -H "Accept: text/html" https://example.com/'
expect deny  $P 'curl -X POST -d x=1 https://example.com/'
expect deny  $P 'curl --data-urlencode q=1 https://example.com/'
expect deny  $P 'curl -o page.html https://example.com/'
expect deny  $P 'curl -O https://example.com/file.zip'
expect deny  $P 'curl -T file https://example.com/'
expect deny  $P 'curl -K /tmp/curlrc https://example.com/'
expect deny  $P 'curl --etag-save /tmp/etag https://example.com/'
expect deny  $P 'curl -sSo /tmp/x https://example.com/'
expect deny  $P 'curl -sOL https://example.com/file.zip'
expect deny  $P 'curl -sXPOST https://example.com/'
expect deny  $P 'curl -s -d@/etc/passwd https://example.com/'
expect deny  $P 'curl -sK /tmp/rc https://example.com/'
expect deny  $P 'curl -so/tmp/x https://example.com/'
expect allow $P 'curl -sSL https://example.com/'
expect allow $P 'curl -fsSL https://example.com/'
expect allow $P 'curl -XGET https://example.com/'
# Conservative by design: a cluster carrying X or o is denied even when its value is harmless.
expect deny  $P 'curl -sXGET https://example.com/'
expect deny  $P 'curl -so/dev/null -w "%{http_code}" https://example.com/'

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
expect deny  $R 'git -C /work/acme-api log -1 && rm -f notes.txt'
expect deny  $R 'ls & rm -rf /tmp/x'
expect deny  $R 'git -C /work/acme-api log & git -C /work/acme-api push'
expect deny  $R 'git -C /work/acme-api diff > /tmp/diff.txt'
expect deny  $R 'git -C /work/acme-api diff >> /tmp/diff.txt'
expect deny  $R 'echo hi > file.txt'
expect deny  $R 'echo "$(git -C /work/acme-api rev-parse HEAD)"'
expect deny  $R 'cat `ls`'
expect deny  $R 'diff <(git show a:f) <(git show b:f)'
expect deny  $R 'find /work -name "*.tmp" -delete'
expect deny  $R 'find /work -name "*.py" -exec rm {} \;'
expect deny  $R 'tee /tmp/out.txt'
expect deny  $R 'xargs rm'
expect deny  $R 'npm test'
expect deny  $R 'bash -c "rm -rf /tmp/x"'
expect deny  $R 'ls | python3'
expect deny  $R 'sudo ls'
expect deny  $R 'env GIT_SSH_COMMAND=/tmp/x git fetch'
expect deny  $R "ls '; rm -rf /tmp/x"
expect deny  $R 'sort -o /tmp/out /work/acme-api/words.txt'
expect deny  $R 'sort --compress-program=/tmp/x /work/acme-api/words.txt'
expect deny  $R 'uniq /work/acme-api/in /tmp/out'
expect deny  $R 'rg --pre /tmp/x pattern /work/acme-api'
expect deny  $R 'sort -uo /tmp/out /work/acme-api/in.txt'
expect allow $R 'sort -un /work/acme-api/in.txt'
expect deny  $R "awk -fprog.awk /work/acme-api/f"
# Escapes outside quotes, programs named by path, and the remaining curl file writers.
expect deny  $R "echo \\' ; rm -rf /tmp/x \\'"
expect deny  $R "ls \\' | tee /tmp/x \\'"
expect deny  $R 'echo \" ; rm -rf /tmp/x \"'
expect allow $R "grep -E 'a\\|b' /work/acme-api/f"
expect allow $R 'git -C /work/acme-api log --format="%h\\n" -3'
expect deny  $R './tools/git log'
expect deny  $R '/work/acme-api/node_modules/.bin/cat x'
expect deny  $R '/tmp/git log'
expect allow $R '/usr/bin/cat /work/acme-api/README.md'
expect allow $R '/usr/bin/grep -c "sentence" /work/acme-api/README.md'
expect deny  $R '/usr/bin/rm -rf /tmp/x'
expect deny  $R '/usr/bin/../../tmp/cat x'
expect deny  $R '/bin/../tmp/git log'
expect deny  $R 'git -C /work/acme-api fetch . HEAD:refs/heads/main'
expect deny  $R 'git -C /work/acme-api fetch -f origin x:main'
expect deny  $R 'git -C /work/acme-api fetch origin +refs/heads/x:refs/heads/x'
expect deny  $R 'git -C /work/acme-api fetch --prune origin'
expect deny  $R 'git -C /work/acme-api fetch -qp origin'
expect allow $R 'git -C /work/acme-api fetch -q origin'
expect allow $R 'git -C /work/acme-api fetch --all'
expect allow $R 'git -C /work/acme-api fetch origin main feature/x'
expect allow $R $'git -C /work/acme-api log \\\n  --oneline -3'
expect deny  $R $'git -C /work/acme-api log \\\n  --oneline -3 && rm -rf /tmp/x'
expect deny  $P 'curl -s --hsts /tmp/x -o /dev/null https://example.com/'
expect deny  $P 'curl -s --alt-svc=/tmp/x https://example.com/'
expect deny  $P 'curl -s -o /dev/null -w "%output{/tmp/x}rm -rf /" https://example.com/'
expect deny  $P 'curl -s -o /dev/null -sw "%output{/tmp/x}" https://example.com/'
expect deny  $P 'curl -s --write-out="%output{/tmp/x}" https://example.com/'
expect deny  $P 'curl -s -w @/tmp/fmt https://example.com/'
expect allow $P 'curl -s -o /dev/null -w "%{http_code} %{url_effective}" https://example.com/'

# -------------------------------------------------------------- sed and awk
expect allow $R 'sed -n "10,20p" /work/acme-api/src/app.py'
expect allow $R "sed -n '/^## State/,/^## /p' /work/plans/x.md"
expect allow $R "sed -n '\$p' /work/acme-api/README.md"
expect allow $R "sed -E 's/(a|b)/x/g' /work/acme-api/f"
expect allow $R "sed 's/\\//_/g' /work/acme-api/f | head"
expect allow $R "sed -n '/foo/=' /work/acme-api/f"
expect allow $R "sed -e '1d' -e 's/a/b/' /work/acme-api/f"
expect allow $R "sed -n '/^x/{p;q;}' /work/acme-api/f"
expect deny  $R 'sed -i "s/a/b/" /work/acme-api/src/app.py'
expect deny  $R "sed 's/a/b/w /tmp/out' /work/acme-api/f"
expect deny  $R "sed 'e rm -rf /tmp/x' /work/acme-api/f"
expect deny  $R "sed '1r /etc/passwd' /work/acme-api/f"
expect deny  $R "sed -f /tmp/prog.sed /work/acme-api/f"
expect deny  $R "sed -n 's/a/b/e' /work/acme-api/f"
expect allow $R "awk '{print \$1}' /work/acme-api/data.txt"
expect allow $R "awk -F: '/foo/ {n++} END {print n}' /work/acme-api/f"
expect deny  $R "awk 'BEGIN{system(\"rm -rf /tmp/x\")}'"
expect deny  $R "awk 'BEGIN{system (\"rm -rf /tmp/x\")}'"
expect deny  $R "awk '@load \"filefuncs\"; BEGIN{print 1}'"
expect deny  $R "awk '{print > \"/tmp/out\"}' /work/acme-api/f"
expect deny  $R "awk 'BEGIN{print \"x\" | \"rm -rf /tmp/y\"}'"
expect deny  $R "awk -f /tmp/prog.awk /work/acme-api/f"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
