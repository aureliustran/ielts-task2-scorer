#!/usr/bin/env bash
# Self-check for guard-branches.sh: bash .claude/hooks/test-guard-branches.sh
hook="$(dirname "$0")/guard-branches.sh"
fail=0
t() { # expect branch command
  tmp=$(mktemp -d); git -C "$tmp" init -q -b "$2"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s","description":"x"}}' "$3" \
    | CLAUDE_PROJECT_DIR=$tmp bash "$hook" 2>/dev/null
  got=$([ $? -eq 2 ] && echo block || echo allow); rm -rf "$tmp"
  [ "$got" = "$1" ] && echo "ok   $1  [$2] $3" || { echo "FAIL want=$1 got=$got [$2] $3"; fail=1; }
}
t block master 'git commit -m x'
t block dev    'git add . && git commit -m \"x\"'
t block dev    'git merge feat/a'
t block dev    'git push'
t block feat/a 'git push origin master'
t block feat/a 'git push origin HEAD:dev'
t block feat/a 'git push origin --delete dev'
t block feat/a 'git push --force origin +master'
t block feat/a 'git push --all origin'
t allow feat/a 'git commit -m \"fix dev docs\"'
t allow feat/a 'git push -u origin feat/a'
t allow feat/a 'git push origin feat/dev-tools'
t allow feat/a 'git push --force-with-lease'
t allow feat/a 'git merge origin/dev'
t allow dev    'git pull'
t allow master 'git log --oneline'
t allow master 'git switch -c feat/b origin/dev'
t allow master 'ls -la'
exit $fail
