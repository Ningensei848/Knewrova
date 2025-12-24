#!/usr/bin/env sh
# .script/__DoNotTouch/hooks/sync-original.sh
# Purpose:
#   Synchronize with the original repository (remote 'upstream') by FETCH + MERGE (no rebase).
#   - Prefer fast-forward: merge --ff --no-edit upstream/main
#   - If non-FF, perform a normal merge and rely on .gitattributes + merge-driver (ours/theirs) for auto-resolution.
#   - Explicitly stash local changes (including untracked), then restore after merge.
#   - After merge, always update submodules to the latest of their tracked branches (remote mode).
#   - Never open editor (use --no-edit). CLI-only hints/logs. Always exit 0 so pre-commit continues.
#   - Works in parent and submodule worktrees. MAIN_BRANCH is fixed to 'main'.

set -eu

# --- logging helpers (stderr) ---
log_cli() {
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[pre-commit][merge-upstream] %s %s\n' "$ts" "$*" 1>&2
}
warn() { printf '[pre-commit][merge-upstream] WARN: %s\n' "$*" 1>&2; }
err()  { printf '[pre-commit][merge-upstream] ERROR: %s\n' "$*" 1>&2; }
hint() { printf '[pre-commit][merge-upstream] HINT:\n%s\n' "$*" 1>&2; }

# --- args: prefer passed GIT_EXE, fallback to PATH ---
GIT_EXE="${1:-}"
if [ -z "${GIT_EXE:-}" ]; then
  if command -v git >/dev/null 2>&1; then
    GIT_EXE="$(command -v git)"
  else
    err "git executable not found. Skip."
    exit 0
  fi
fi
log_cli "GIT_EXE: $GIT_EXE"

# --- constants ---
MAIN_BRANCH="main"
SUBMODULE_JOBS="${GIT_SUBMODULE_JOBS:-4}"  # parallel update

# --- locate worktree root (parent or child) ---
SUPER="$($GIT_EXE rev-parse --show-superproject-working-tree 2>/dev/null || true)"
TOP="$($GIT_EXE rev-parse --show-toplevel 2>/dev/null || true)"
ROOT="${SUPER:-$TOP}"
if [ -z "${ROOT:-}" ]; then
  warn "Not inside a git worktree. Skip."
  exit 0
fi
cd "$ROOT" || { warn "Failed to cd $ROOT. Skip."; exit 0; }
log_cli "ROOT: $ROOT"

# submodule context info
SUPER_OUT="$($GIT_EXE rev-parse --show-superproject-working-tree 2>/dev/null || true)"
if [ -n "$SUPER_OUT" ]; then
  log_cli "Detected submodule worktree."
fi

# --- branch check (avoid detached HEAD) ---
BRANCH="$($GIT_EXE symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ -z "$BRANCH" ]; then
  warn "Detached HEAD. Skip original sync."
  hint "Switch to a branch (e.g. main):\n  git switch main\nThen:\n  git fetch upstream --prune --no-tags\n  git merge --ff --no-edit upstream/main"
  exit 0
fi
log_cli "Current branch: $BRANCH"

# ongoing rebase/merge?
if [ -d "$ROOT/.git/rebase-apply" ] || [ -d "$ROOT/.git/rebase-merge" ] || [ -f "$ROOT/.git/MERGE_HEAD" ]; then
  warn "Ongoing rebase/merge detected. Skip original sync."
  hint "Finish the ongoing operation:\n  git status\n  git rebase --continue   # or\n  git rebase --abort      # or\n  git merge --abort"
  exit 0
fi

# upstream remote exists?
if ! $GIT_EXE remote get-url upstream >/dev/null 2>&1; then
  warn "Remote 'upstream' is not configured. Skip."
  hint "Add upstream remote (example):\n  git remote add upstream <ORIGINAL_REPO_URL>\n  git fetch upstream --prune --no-tags"
  exit 0
fi

# fetch upstream MAIN_BRANCH
log_cli "Fetch upstream/$MAIN_BRANCH"
if ! $GIT_EXE fetch --no-tags --prune upstream "$MAIN_BRANCH" >/dev/null 2>&1; then
  warn "Failed to fetch upstream/$MAIN_BRANCH. Skip."
  hint "Fetch failed for upstream/$MAIN_BRANCH.\nCheck remote:\n  git remote -v\n  git ls-remote --heads upstream\n  git fetch upstream --prune --no-tags"
  exit 0
fi

# ensure upstream branch exists
if ! $GIT_EXE rev-parse --verify "refs/remotes/upstream/$MAIN_BRANCH" >/dev/null 2>&1; then
  warn "Upstream branch 'upstream/$MAIN_BRANCH' not found. Skip."
  hint "Upstream branch not found.\nTry:\n  git fetch upstream $MAIN_BRANCH\n  git merge --ff --no-edit upstream/$MAIN_BRANCH"
  exit 0
fi

# compare HEAD with upstream/MAIN_BRANCH
COUNTS="$($GIT_EXE rev-list --left-right --count "HEAD...upstream/$MAIN_BRANCH" 2>/dev/null || true)"
if [ -z "$COUNTS" ]; then
  warn "Failed to compare HEAD with upstream/$MAIN_BRANCH. Skip."
  hint "Comparison failed.\nTry:\n  git fetch upstream --prune --no-tags\n  git rev-list --left-right --count HEAD...upstream/$MAIN_BRANCH"
  exit 0
fi
AHEAD="$(printf '%s' "$COUNTS" | awk '{print $1}')"
BEHIND="$(printf '%s' "$COUNTS" | awk '{print $2}')"
log_cli "ahead=$AHEAD behind=$BEHIND vs upstream/$MAIN_BRANCH"
if [ "${BEHIND:-0}" -eq 0 ]; then
  log_cli "Already up-to-date with upstream/$MAIN_BRANCH. Nothing to do."
  exit 0
fi

# --- explicit stash (save & untracked) with index refresh ---
$GIT_EXE update-index -q --refresh || true

HAS_CHANGES="0"
if ! $GIT_EXE diff --quiet --ignore-submodules=all; then HAS_CHANGES="1"; fi
if ! $GIT_EXE diff --quiet --cached --ignore-submodules=all; then HAS_CHANGES="1"; fi
UNTRACKED="$($GIT_EXE ls-files --others --exclude-standard 2>/dev/null || true)"
if [ -n "$UNTRACKED" ]; then HAS_CHANGES="1"; fi

STASH_REF=""
STASH_NAME="precommit-autostash:$(date '+%Y%m%d-%H%M%S')"
if [ "$HAS_CHANGES" = "1" ]; then
  log_cli "Local changes detected; creating explicit stash: $STASH_NAME"
  STASH_ERR=""
  if ! STASH_ERR="$($GIT_EXE stash push -u -m "$STASH_NAME" 2>&1 >/dev/null)"; then
    warn "Failed to create stash. stderr: ${STASH_ERR:-<empty>}"
    hint "If merge fails due to local changes, stash manually:\n  git stash push -u -m \"$STASH_NAME\""
  else
    STASH_REF="$($GIT_EXE stash list | head -n1 | awk -F: '{print $1}')"
    log_cli "Stash created: ${STASH_REF:-<unknown>} ($STASH_NAME)"
  fi
else
  log_cli "No local changes; explicit stash not needed."
fi

# --- Decide FF or normal merge ---
UPSTREAM_REF="upstream/$MAIN_BRANCH"
FF_POSSIBLE=1
if $GIT_EXE merge-base --is-ancestor HEAD "$UPSTREAM_REF"; then
  FF_POSSIBLE=0
fi

# --- perform merge (no editor) ---
log_cli "Start: git merge --ff --no-edit $UPSTREAM_REF"
MERGE_ERR=""
if ! MERGE_ERR="$($GIT_EXE merge --ff --no-edit "$UPSTREAM_REF" 2>&1 >/dev/null)"; then
  err "git merge failed. stderr: ${MERGE_ERR:-<empty>}"
  hint "Merge failed.\nCheck:\n  - .gitattributes（merge=ours/theirs）\n  - .git/config [merge \"ours\"/\"theirs\"] driver\n  - ongoing operations（git status）\n  - try: git merge --abort"
  [ -n "$STASH_REF" ] && warn "Explicit stash remains. You can restore later:\n  git stash pop --index \"$STASH_REF\""
  exit 0
fi

# --- Submodules: always remote tracking update (recursive) ---
if [ -f ".gitmodules" ]; then
  log_cli "Submodules detected. Sync URLs from .gitmodules (recursive)."
  if ! $GIT_EXE submodule sync --recursive >/dev/null 2>&1; then
    warn "submodule sync failed."
    hint "Try:\n  git submodule sync --recursive\n  git config -f .gitmodules --list"
  fi

  log_cli "Update submodules to remote tracked branches (recursive, jobs=$SUBMODULE_JOBS)."
  if ! $GIT_EXE submodule update --init --remote --recursive --checkout --jobs "$SUBMODULE_JOBS" >/dev/null 2>&1; then
    warn "submodule update --remote failed."
    hint "Try:\n  git submodule update --recursive --remote --progress\nIf branches are missing in .gitmodules:\n  git config -f .gitmodules --list | findstr /C:branch\n  # Set: git config -f .gitmodules submodule.<name>.branch main\n  git submodule sync --recursive"
  fi
else
  log_cli "No .gitmodules. Skipping submodule sync/update."
fi

# --- success path: restore explicit stash if it exists ---
if [ -n "$STASH_REF" ]; then
  log_cli "Restoring stash: $STASH_REF"
  if $GIT_EXE stash pop --index "$STASH_REF" >/dev/null 2>&1; then
    log_cli "Stash restored successfully."
    exit 0
  else
    warn "Stash pop resulted in conflicts or failed."
    CONFLICTS="$($GIT_EXE diff --name-only --diff-filter=U 2>/dev/null || true)"
    if [ -n "$CONFLICTS" ]; then
      hint "Conflicts after stash restore in:\n$CONFLICTS\nResolve and continue:\n  git status\n  # edit files\n  git add <files>"
    else
      hint "Stash restore failed.\nTry:\n  git stash apply --index \"$STASH_REF\""
    fi
    exit 0
  fi
else
  log_cli "Merge completed (FF=${FF_POSSIBLE}) and submodules updated (remote)."
  exit 0
fi
