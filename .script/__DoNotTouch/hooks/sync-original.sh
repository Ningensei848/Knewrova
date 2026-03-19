#!/usr/bin/env bash
# sync-original.sh
# 親リポジトリをアップストリームと同期 (FETCH + MERGE)

set -eu
HOOK_DIR="$(dirname "$0")"
source "$HOOK_DIR/common.sh"

GIT_EXE="${1:-git}"
ROOT="$(resolve_root)"
cd "$ROOT"

MAIN_BRANCH="main"
SUBMODULE_JOBS="${GIT_SUBMODULE_JOBS:-4}"

# detached HEAD 等のチェック
BRANCH="$("$GIT_EXE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -z "$BRANCH" ] && log_warn "Detached HEAD. Skip original sync." && exit 0

if [ -d "$ROOT/.git/rebase-apply" ] || [ -d "$ROOT/.git/rebase-merge" ] || [ -f "$ROOT/.git/MERGE_HEAD" ]; then
    log_warn "Ongoing rebase/merge detected. Skip original sync." && exit 0
fi

if ! "$GIT_EXE" remote get-url upstream >/dev/null 2>&1; then
    log_warn "Remote 'upstream' is not configured. Skip." && exit 0
fi

log_info "Fetching upstream/$MAIN_BRANCH..."
if ! "$GIT_EXE" fetch --no-tags --prune upstream "$MAIN_BRANCH" >/dev/null 2>&1; then
    log_warn "Failed to fetch upstream/$MAIN_BRANCH. Skip." && exit 0
fi

COUNTS="$("$GIT_EXE" rev-list --left-right --count "HEAD...upstream/$MAIN_BRANCH" 2>/dev/null || true)"
[ -z "$COUNTS" ] && exit 0
BEHIND="$(echo "$COUNTS" | awk '{print $2}')"

[ "${BEHIND:-0}" -eq 0 ] && log_info "Already up-to-date with upstream/$MAIN_BRANCH." && exit 0

# stash処理
"$GIT_EXE" update-index -q --refresh || true
HAS_CHANGES=0
"$GIT_EXE" diff --quiet --ignore-submodules=all || HAS_CHANGES=1
"$GIT_EXE" diff --quiet --cached --ignore-submodules=all || HAS_CHANGES=1
[ -n "$("$GIT_EXE" ls-files --others --exclude-standard 2>/dev/null)" ] && HAS_CHANGES=1

STASH_REF=""
if [ "$HAS_CHANGES" -eq 1 ]; then
    STASH_NAME="precommit-autostash:$(date '+%Y%m%d-%H%M%S')"
    if "$GIT_EXE" stash push -u -q -m "$STASH_NAME"; then
        STASH_REF="$("$GIT_EXE" stash list | head -n1 | awk -F: '{print $1}')"
        log_info "Stash created: $STASH_REF"
    fi
fi

log_info "Merging upstream/$MAIN_BRANCH..."
if ! "$GIT_EXE" merge --ff --no-edit "upstream/$MAIN_BRANCH" >/dev/null 2>&1; then
    log_error "Merge failed. Resolve conflicts manually."
    exit 0 # フック自体は異常終了させない
fi

if [ -f ".gitmodules" ]; then
    "$GIT_EXE" submodule sync --recursive >/dev/null 2>&1 || true
    "$GIT_EXE" submodule update --init --remote --recursive --merge --checkout --jobs "$SUBMODULE_JOBS" >/dev/null 2>&1 || true
fi

if [ -n "$STASH_REF" ]; then
    log_info "Restoring stash..."
    "$GIT_EXE" stash pop --index "$STASH_REF" >/dev/null 2>&1 || log_warn "Stash pop resulted in conflicts."
fi

exit 0
