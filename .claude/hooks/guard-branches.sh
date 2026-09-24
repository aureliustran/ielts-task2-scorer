#!/usr/bin/env bash
# PreToolUse hook for Bash: blocks commits/merges on master/dev and pushes to them.
# See AGENTS.md "Git workflow". Exit 2 = block, stderr is shown to Claude.
input=$(cat)
cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p')

printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]' || exit 0

branch=$(git -C "${CLAUDE_PROJECT_DIR:-.}" symbolic-ref --short HEAD 2>/dev/null)
protected='master|dev'

block() { echo "Blocked by AGENTS.md git workflow: $1. Work on a feature branch off dev and open a PR into dev." >&2; exit 2; }

if [[ "$branch" =~ ^($protected)$ ]] && printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+(commit|merge|rebase|cherry-pick|revert|push)([[:space:]]|$)'; then
  block "you are on '$branch'"
fi
# ponytail: regex on the command string; git aliases/scripts bypass it. GitHub branch protection is the real guard.
if printf '%s' "$cmd" | grep -Eq "git[[:space:]]+push([^;&|]*[[:space:]:+])($protected)([[:space:];&|]|$)"; then
  block "pushing to a protected branch"
fi
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^;&|]*(--mirror|--all)'; then
  block "--mirror/--all would push protected branches"
fi
exit 0
