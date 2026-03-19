#!/usr/bin/env bash
# handle-images.sh
# 責務: Gitフックのオーケストレーション。設定のロード、対象ファイルの特定、各処理スクリプトの呼び出しを行う。

set -eu
HOOK_DIR="$(dirname "$0")"
source "$HOOK_DIR/common.sh"

# --- 初期化 ---
ROOT="$(resolve_root)"
cd "$ROOT"
load_env "$ROOT/.env"

GIT_CMD="${GIT_EXE:-git}"
DRY_RUN="${DRY_RUN:-false}"
LOG_PATH="${LOG_PATH:-uploads.log}"
REWRITE_MD="${REWRITE_MD:-true}"
EXIT_SUCCESS=0
EXIT_FAILURE=1
UPLOAD_FAIL_COUNT=0


# --- index.lock の解放待ち & 安全な git add ---
wait_for_index_unlock() {
    local lock="$ROOT/.git/index.lock"
    local tries=20
    local sleep_s=0.2
    for ((i=0; i<tries; i++)); do
        [ ! -e "$lock" ] && return 0
        sleep "$sleep_s"
    done
    return 1
}

safe_git_add() {
    local target="$1"
    if wait_for_index_unlock; then
        "$GIT_CMD" add -- "$target"
        return $?
    else
        log_error "Index lock persists; skip staging for: $target"
        return 1
    fi
}

get_staged_markdowns() {
    if "$GIT_CMD" rev-parse --verify HEAD >/dev/null 2>&1; then
        "$GIT_CMD" diff-index --cached --name-only --diff-filter=ACMR HEAD | grep -E '\.md$' || true
    else
        "$GIT_CMD" diff --cached --name-only --diff-filter=ACMR | grep -E '\.md$' || true
    fi
}

process_single_file() {
    local file="$1"
    log_info "Processing: $file"

    # Step 1: 画像アップロード
    local up_rc=0
    bash "$HOOK_DIR/upload-images.sh" "$file" || up_rc=$?

    case "$up_rc" in
        0)   log_info "  [Upload] OK for: $file" ;;
        10)  log_info "  [Upload] Skip for: $file" ;;
        *)   log_error "  [Upload] FAILED for: $file"; UPLOAD_FAIL_COUNT=$((UPLOAD_FAIL_COUNT+1)) ;;
    esac

    # Step 2: リンク書き換え
    if [ "${REWRITE_MD,,}" = "true" ]; then
        local rw_rc=0
        bash "$HOOK_DIR/rewrite-mdlink.sh" "$file" || rw_rc=$?

        case "$rw_rc" in
            0)
                log_info "  [Rewrite] OK for: $file"
                if [ "${DRY_RUN,,}" = "false" ]; then
                    safe_git_add "$file" || log_error "Failed to re-stage: $file"
                fi
                ;;
            10) log_info "  [Rewrite] Skip for: $file" ;;
            *)  log_error "  [Rewrite] FAILED for: $file" ;;
        esac
    else
        log_info "  [Rewrite] Disabled by setting for: $file"
    fi
    return $EXIT_SUCCESS
}

# --- Main ---
log_info "=== Session Started ==="
[ "${DRY_RUN,,}" = "true" ] && log_warn "!!! DRY RUN MODE: No changes will be made !!!"

staged_files="$(get_staged_markdowns)"
if [ -z "$staged_files" ]; then
    log_info "No markdown files staged. Skipping."
    exit $EXIT_SUCCESS
fi

while IFS= read -r file; do
    [ -n "$file" ] && process_single_file "$file"
done <<< "$staged_files"

log_info "=== Session Completed ==="

if [ "$UPLOAD_FAIL_COUNT" -gt 0 ]; then
    log_error "Upload failures detected: $UPLOAD_FAIL_COUNT. Aborting commit."
    exit $EXIT_FAILURE
fi

exit $EXIT_SUCCESS