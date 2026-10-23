#!/bin/bash
# PreToolUse hook for Bash: Block PR creation if branch is stale
#
# Intercepts `gh pr create` and checks branch freshness against the
# base branch. Unlike git hooks, this cannot be bypassed with --no-verify.

# Read JSON from stdin
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Only check gh pr create commands
if [[ "$COMMAND" != *"gh pr create"* ]]; then
    exit 0
fi

# Editors that load every workspace root's hooks run this one from the OpenEnv
# root for commands aimed at other repos, so find the repo the command runs in:
# the hook input's cwd (else the hook's own directory), moved by each `cd <dir>`
# that runs before `gh pr create`.
TARGET=$(echo "$INPUT" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null)
TARGET="${TARGET:-$PWD}"
PREFIX="${COMMAND%%gh pr create*}"
CD_PATTERN='(^|[;&|(])[[:space:]]*cd[[:space:]]+([^[:space:];&|)]+)(.*)'
while [[ "$PREFIX" =~ $CD_PATTERN ]]; do
    DIR="${BASH_REMATCH[2]}"
    PREFIX="${BASH_REMATCH[3]}"
    DIR="${DIR//\"/}"
    DIR="${DIR//\'/}"
    DIR="${DIR/#\~/$HOME}"
    [[ "$DIR" == /* ]] || DIR="$TARGET/$DIR"
    TARGET="$DIR"
done

# Only enforce for OpenEnv itself, including its worktrees
HOOK_REPO=$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
TARGET_REPO=$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [[ -z "$TARGET_REPO" || "$TARGET_REPO" != "$HOOK_REPO" ]]; then
    exit 0
fi

# Determine base branch (default: main)
BASE="main"
BASE_PATTERN='--base[[:space:]=]+([^[:space:]]+)'
if [[ "$COMMAND" =~ $BASE_PATTERN ]]; then
    BASE="${BASH_REMATCH[1]}"
fi

# Fetch latest base and check freshness
git -C "$TARGET" fetch origin "$BASE" --quiet 2>/dev/null || true
BEHIND=$(git -C "$TARGET" rev-list --count HEAD.."origin/$BASE" 2>/dev/null || echo "?")

if [[ "$BEHIND" != "0" && "$BEHIND" != "?" ]]; then
    cat >&2 << EOF

===================================================================
  PR BLOCKED: Branch is $BEHIND commit(s) behind $BASE
===================================================================

  Your PR will show "out of date with base branch" on GitHub.

  Fix with:
    git fetch origin $BASE
    git rebase origin/$BASE
    git push --force-with-lease

  Then retry gh pr create.

===================================================================

EOF
    exit 2
fi

# Check we're not on main/master
BRANCH=$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    cat >&2 << EOF

===================================================================
  PR BLOCKED: Cannot create PR from $BRANCH
===================================================================

  Create a feature branch first:
    git checkout -b <branch-name>
    git push -u origin <branch-name>

===================================================================

EOF
    exit 2
fi

exit 0
