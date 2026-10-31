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
expect allow ""                     'rm -rf build'
expect allow "general-purpose"      'rm -rf build'
expect allow "implementer"          'git push -u origin HEAD'
expect allow "ontherun:implementer" 'git commit -m x'
expect allow "verifier"             'npm test'
expect deny  "reviewer"             'rm -rf build'
expect deny  "ontherun:reviewer"    'rm -rf build'
expect deny  "ontherun:validator"   'git commit -m x'
expect deny  "plan-reviewer"        'git stash'
expect deny  "ontherun:plan-validator" 'npm test'
expect deny  "fold-checker"         'sed -i s/a/b/ plan.md'
R=reviewer

# Malformed or empty input: no decision.
if [ -z "$(printf 'not json' | guard 2>/dev/null)" ]; then ok "not json -> no decision"; else bad "not json -> no decision"; fi
if [ -z "$(jq -n '{tool_name:"Bash",agent_type:"reviewer",tool_input:{}}' | guard 2>/dev/null)" ]; then ok "no command -> no decision"; else bad "no command -> no decision"; fi

# ------------------------------------------------------------- what a review reads
expect allow $R 'git diff origin/main...HEAD'
expect allow $R 'git -C /work/acme-api diff --stat origin/main...HEAD -- src/'
expect allow $R 'git log --oneline -20 origin/main..HEAD'
expect allow $R 'git log -S "needle" --format="%h %s" -- src/'
expect allow $R 'git show HEAD~1:src/app.ts | head -50'
expect allow $R 'git -C /work/acme-api -c core.pager=cat blame -L 10,20 src/app.ts'
expect allow $R 'GIT_PAGER=cat git status --porcelain'
expect allow $R 'git grep -n "TODO" -- "*.ts"'
expect allow $R 'git rev-parse -q --verify --abbrev-ref origin/HEAD'
expect allow $R 'git show-ref --verify -q refs/remotes/origin/main'
expect allow $R 'git branch -a --contains HEAD'
expect allow $R 'git branch --list "release/*"'
expect allow $R 'git tag -l "v*" --sort=-v:refname'
expect allow $R 'git remote -v'
expect allow $R 'git remote get-url origin'
expect allow $R 'git config --get remote.origin.url'
expect allow $R 'git config --list --show-origin'
expect allow $R 'git stash list'
expect allow $R 'git stash show -p stash@{0}'
expect allow $R 'git worktree list --porcelain'
expect allow $R 'git submodule status'
expect allow $R 'git reflog -n 5'
expect allow $R 'git notes show HEAD'
expect allow $R 'git symbolic-ref -q --short HEAD'
expect allow $R 'git format-patch -1 --stdout HEAD'
expect allow $R 'git ls-files src | wc -l'
expect allow $R 'git bundle verify x.bundle'
expect allow $R 'git fsck --no-dangling'
expect allow $R 'cd /work/acme-api && git log --oneline -5'
expect allow $R 'ls -la src/ && cat package.json'
expect allow $R 'grep -rn "fetchUser" src/ | head -20'
expect allow $R 'rg -n "fetchUser" src/'
expect allow $R 'find . -name "*.test.ts" -not -path "*/node_modules/*"'
expect allow $R 'sed -n "10,40p" src/app.ts'
expect allow $R 'sed -e "s/^/  /" src/app.ts'
expect allow $R 'awk -F: "{print \$1}" /etc/passwd | sort | uniq -c | sort -rn'
expect allow $R 'sort -u names.txt'
expect allow $R 'uniq -c sorted.txt'
expect allow $R 'tar -tf dist.tar'
expect allow $R 'tar --list -f dist.tar'
expect allow $R 'jq -r ".scripts" package.json'
expect allow $R 'wc -l src/*.ts'
expect allow $R 'test -f README.md && echo yes || echo no'
expect allow $R 'for f in src/*.ts; do wc -l "$f"; done'
expect allow $R 'if git diff --quiet; then echo clean; else echo dirty; fi'
expect allow $R '(cd src && ls)'
expect allow $R '{ ls a; ls b; }'
expect allow $R '! grep -q x f'
expect allow $R 'time git log --oneline | head'
expect allow $R 'ls >/dev/null 2>&1'
expect allow $R 'ls &>/dev/null'
expect allow $R 'ls 2> /dev/null'
expect allow $R 'echo "x" >&2'
expect allow $R 'cat <<EOF
two lines
of text
EOF'
expect allow $R 'cat <<< "$HOME"'
expect allow $R 'ls < /dev/null'
expect allow $R 'echo "it'"'"'s" done'
expect allow $R 'grep "git push" docs/*.md'
expect allow $R 'grep "rm -rf" install.sh'
expect allow $R "grep 'ls > out' notes.txt"
expect allow $R 'echo $HOME ${PATH} \$x'
expect allow $R 'gh pr list -R acme/api --state all --head feature/x'
expect allow $R 'gh pr checks 42 -R acme/api'
expect allow $R 'gh pr view 42 --json title,body'
expect allow $R 'gh run list --limit 5'
expect allow $R 'gh api repos/acme/api/pulls/42'
expect allow $R 'gh api -X GET repos/acme/api/pulls/42 --jq .title'
expect allow $R 'gh api --method GET repos/acme/api/pulls/42'
expect allow $R 'gh auth status'
expect allow $R 'gh issue list --label review'
expect allow $R 'gh search prs "guard" --repo acme/api'
expect allow $R 'which jq && jq --version'
expect allow $R 'pwd; date; printf "%s\n" a b'
expect allow $R 'file src/app.ts'
expect allow $R 'export FOO=1; FOO=2 ls'

# ------------------------------------------------------------- what runs a hidden command
expect deny  $R 'echo $(rm -rf build)'
expect deny  $R 'git log --format="%h $(touch x)"'
expect deny  $R 'echo `touch x`'
expect deny  $R 'diff <(ls a) <(ls b)'
expect deny  $R 'tee >(cat) < f'
expect allow $R "echo '\$(not run)'"
expect allow $R "grep '\`' f"
expect deny  $R 'bash -c "rm -rf /tmp/x"'
expect deny  $R 'sh -c ls'
expect deny  $R 'eval "ls"'
expect deny  $R 'exec ls'
expect deny  $R 'source ./env.sh'
expect deny  $R '. ./env.sh'
expect deny  $R 'ls | python3'
expect deny  $R 'python3 -c "print(1)"'
expect deny  $R 'node -e "1"'
expect deny  $R 'perl -e "1"'
expect deny  $R 'osascript -e "beep"'
expect deny  $R 'sudo ls'
expect deny  $R 'env FOO=1 ls'
expect deny  $R 'xargs rm'
expect deny  $R 'ls | xargs grep x'
expect deny  $R 'nohup ls &'
expect deny  $R 'command rm x'
expect deny  $R 'time rm x'

# ------------------------------------------------------------- what writes a file
expect deny  $R 'ls > out.txt'
expect deny  $R 'ls >> out.txt'
expect deny  $R 'ls 2> err.txt'
expect deny  $R 'ls &> all.txt'
expect deny  $R 'ls >| out.txt'
expect deny  $R 'git diff > /tmp/patch'
expect deny  $R 'rm -rf build'
expect deny  $R '/bin/rm -rf build'
expect deny  $R './node_modules/.bin/rm x'
expect deny  $R 'mv a b'
expect deny  $R 'cp a b'
expect deny  $R 'ln -s a b'
expect deny  $R 'touch x'
expect deny  $R 'mkdir -p out'
expect deny  $R 'ls | tee out.txt'
expect deny  $R 'dd if=a of=b'
expect deny  $R 'chmod +x x'
expect deny  $R 'patch -p1 < x.diff'
expect deny  $R 'rsync -a a/ b/'
expect deny  $R 'scp a host:b'
expect deny  $R 'unzip dist.zip'
expect deny  $R 'gzip f'
expect deny  $R 'tar xzf dist.tgz'
expect deny  $R 'tar -xf dist.tar'
expect deny  $R 'tar --extract -f dist.tar'
expect deny  $R 'tar cf dist.tar src'
expect deny  $R 'tar -c -f dist.tar src'
expect deny  $R 'sed -i s/a/b/ f'
expect deny  $R 'sed -i.bak s/a/b/ f'
expect deny  $R 'sed -ni "p" f'
expect deny  $R 'sed --in-place s/a/b/ f'
expect deny  $R 'sed --in-place=.bak s/a/b/ f'
expect deny  $R 'sort -o out f'
expect deny  $R 'sort -uo out f'
expect deny  $R 'sort --output=out f'
expect deny  $R 'uniq a b'
expect deny  $R 'find . -name "*.o" -delete'
expect deny  $R 'find . -name "*.sh" -exec rm {} \;'
expect deny  $R 'find . -execdir rm {} +'
expect deny  $R 'find . -fprint out'
expect deny  $R 'git diff --output=x.patch'
expect deny  $R 'git log --output x'
expect deny  $R 'git grep -O x'
expect deny  $R 'git grep --open-files-in-pager=vi x'
expect deny  $R 'git format-patch -1 HEAD'
expect deny  $R 'git hash-object -w f'
expect deny  $R 'vim f'
expect deny  $R 'code f'
expect deny  $R 'open f'

# ------------------------------------------------------------- what changes the branch under review
expect deny  $R 'git add -A'
expect deny  $R 'git commit -m x'
expect deny  $R 'git checkout main'
expect deny  $R 'git switch -c x'
expect deny  $R 'git restore f'
expect deny  $R 'git reset --hard'
expect deny  $R 'git stash'
expect deny  $R 'git stash push -m x'
expect deny  $R 'git stash pop'
expect deny  $R 'git rebase -i HEAD~3'
expect deny  $R 'git merge x'
expect deny  $R 'git cherry-pick abc'
expect deny  $R 'git revert HEAD'
expect deny  $R 'git clean -fd'
expect deny  $R 'git rm f'
expect deny  $R 'git mv a b'
expect deny  $R 'git apply x.patch'
expect deny  $R 'git am x.patch'
expect deny  $R 'git push'
expect deny  $R 'git pull'
expect deny  $R 'git fetch origin'
expect deny  $R 'git clone x'
expect deny  $R 'git init'
expect deny  $R 'git -C /work/acme-api --no-pager commit -m x'
expect deny  $R 'git -c user.name=x commit -m x'
expect deny  $R 'git branch -d x'
expect deny  $R 'git branch -D x'
expect deny  $R 'git branch -m x y'
expect deny  $R 'git branch -f x HEAD'
expect deny  $R 'git branch --set-upstream-to=origin/x'
expect deny  $R 'git branch -u origin/x'
expect deny  $R 'git tag -a v1 -m x'
expect deny  $R 'git tag -d v1'
expect deny  $R 'git tag -f v1'
expect deny  $R 'git remote add x url'
expect deny  $R 'git remote set-url origin url'
expect deny  $R 'git remote set-head origin --auto'
expect deny  $R 'git remote prune origin'
expect deny  $R 'git config user.name x'
expect deny  $R 'git config --unset user.name'
expect deny  $R 'git config --global core.pager cat'
expect deny  $R 'git reflog expire --all'
expect deny  $R 'git reflog delete HEAD@{1}'
expect deny  $R 'git notes add -m x'
expect deny  $R 'git worktree add ../x'
expect deny  $R 'git worktree remove ../x'
expect deny  $R 'git submodule update --init'
expect deny  $R 'git submodule foreach ls'
expect deny  $R 'git symbolic-ref HEAD refs/heads/x'
expect deny  $R 'git symbolic-ref -d refs/remotes/origin/HEAD'
expect deny  $R 'git update-ref refs/heads/x abc'
expect deny  $R 'git bundle create x.bundle HEAD'
expect deny  $R 'git gc'
expect deny  $R 'git bisect start'
expect deny  $R 'git difftool HEAD~1'
expect deny  $R 'git filter-branch --all'

# ------------------------------------------------------------- what builds, runs or reaches out
expect deny  $R 'npm test'
expect deny  $R 'npm run lint'
expect deny  $R 'npx prettier --write .'
expect deny  $R 'yarn build'
expect deny  $R 'pnpm install'
expect deny  $R 'make'
expect deny  $R 'cargo test'
expect deny  $R 'go test ./...'
expect deny  $R 'pytest -q'
expect deny  $R 'pip install x'
expect deny  $R 'tsc --noEmit'
expect deny  $R 'eslint src'
expect deny  $R 'black .'
expect deny  $R 'ruff check .'
expect deny  $R 'docker ps'
expect deny  $R 'brew install x'
expect deny  $R 'curl -s https://example.com'
expect deny  $R 'wget https://example.com'
expect deny  $R 'ssh host ls'
expect deny  $R 'kill -9 1234'
expect deny  $R 'pkill node'

# ------------------------------------------------------------- gh writes
expect deny  $R 'gh pr create -t x -b y'
expect deny  $R 'gh pr -R acme/api create -t x'
expect deny  $R 'gh pr edit 42 --body x'
expect deny  $R 'gh pr merge 42'
expect deny  $R 'gh pr close 42'
expect deny  $R 'gh pr comment 42 -b x'
expect deny  $R 'gh pr review 42 --approve'
expect deny  $R 'gh pr checkout 42'
expect deny  $R 'gh pr ready 42'
expect deny  $R 'gh issue create -t x'
expect deny  $R 'gh issue delete 1'
expect deny  $R 'gh repo clone acme/api'
expect deny  $R 'gh repo fork acme/api'
expect deny  $R 'gh repo delete acme/api'
expect deny  $R 'gh release create v1'
expect deny  $R 'gh release upload v1 x.tgz'
expect deny  $R 'gh run rerun 1'
expect deny  $R 'gh run cancel 1'
expect deny  $R 'gh run download 1'
expect deny  $R 'gh workflow run ci.yml'
expect deny  $R 'gh label create x'
expect deny  $R 'gh secret set X'
expect deny  $R 'gh gist create f'
expect deny  $R 'gh alias set x y'
expect deny  $R 'gh config set editor vi'
expect deny  $R 'gh extension install x'
expect deny  $R 'gh codespace create'
expect deny  $R 'gh project item-add 1'
expect deny  $R 'gh auth login'
expect deny  $R 'gh auth logout'
expect deny  $R 'gh auth token'
expect deny  $R 'gh auth refresh'
expect deny  $R 'gh api repos/acme/api/pulls -X POST'
expect deny  $R 'gh api repos/acme/api/pulls -XPOST'
expect deny  $R 'gh api --method DELETE repos/acme/api'
expect deny  $R 'gh api --method=PATCH repos/acme/api'
expect deny  $R 'gh api repos/acme/api/issues -f title=x'
expect deny  $R 'gh api repos/acme/api/issues -F title=x'
expect deny  $R 'gh api repos/acme/api/issues --field title=x'
expect deny  $R 'gh api repos/acme/api/issues --input body.json'
expect deny  $R 'gh pr view 42 --web'
expect deny  $R 'gh pr view 42 -w'
expect deny  $R 'gh browse'

# ------------------------------------------------------------- one bad piece denies the whole call
expect deny  $R 'git log --oneline; rm -rf build'
expect deny  $R 'ls && git stash'
expect deny  $R 'ls || npm test'
expect deny  $R 'ls | tee out'
expect deny  $R 'ls &
rm x'
expect deny  $R 'for f in a b; do rm "$f"; done'
expect deny  $R 'if true; then git checkout x; fi'
expect deny  $R '(cd src && make)'
expect deny  $R '{ ls; rm x; }'

# A splitter that cannot run denies rather than falling through.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/perl"; chmod +x "$TMP/bin/perl"
out=$(jq -n '{tool_name:"Bash",agent_type:"reviewer",tool_input:{command:"ls /work"}}' | PATH="$TMP/bin:$PATH" guard 2>/dev/null)
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then ok "perl failing -> deny"; else bad "perl failing -> deny" "got: $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$inner_rc" -eq 0 ]
