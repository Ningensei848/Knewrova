#!/usr/bin/env bash
# collision-check-and-lock.sh

set -eu
source "$(dirname "$0")/common.sh"

REMOTE_NAME="$1"
REMOTE_URL="$2"

ROOT="$(resolve_root)"
load_env "$ROOT/.env"

TTL="${LOCK_TTL_SECONDS:-300}"
RETRY_MAX="${LOCK_RETRY_MAX:-15}"
LOCK_BASE_SUBDIR="${LOCK_BASE_SUBDIR:-locks}"

ENABLE_GLOBAL_LOCK="${ENABLE_GLOBAL_LOCK:-true}"
ENABLE_PER_REF_LOCK="${ENABLE_PER_REF_LOCK:-true}"

remote_path="$(normalize_path "$REMOTE_URL")"
lock_base="$remote_path/$LOCK_BASE_SUBDIR"
refs_lock_dir="$lock_base/refs"

mkdir -p "$lock_base" 2>/dev/null || true
mkdir -p "$refs_lock_dir" 2>/dev/null || true

updates_file="$ROOT/.git/pre-push-updates.tmp"
[ ! -f "$updates_file" ] && exit 0

# --- Fetch for fast-forward check ---
log_info "Fetching latest from '$REMOTE_NAME' for integrity check..."
if ! git fetch --prune "$REMOTE_NAME" >/dev/null 2>&1; then
    log_error "Fetch failed. Ensure remote '$REMOTE_NAME' is reachable."
    exit 1
fi

fast_forward_ok() {
    local remote_sha="$1"
    local local_sha="$2"
    [ "$remote_sha" = "0000000000000000000000000000000000000000" ] && return 0
    git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null
}

get_lock_age() {
    local lock_path="$1"
    [ ! -d "$lock_path" ] && return 1
    local mtime
    mtime="$(stat -c %Y "$lock_path" 2>/dev/null || date -r "$lock_path" +%s 2>/dev/null)"
    [ -z "$mtime" ] && return 1
    local now; now="$(date +%s)"
    echo "$((now - mtime))"
}

mk_lock() {
    local lock_path="$1"
    local ttl="$2"
    local age
    age="$(get_lock_age "$lock_path" || echo "")"
    
    if [ -n "$age" ]; then
        if [ "$age" -lt "$ttl" ]; then
            return 1 # ロック中かつ新鮮
        fi
        # TTL経過のため強制削除
        rm -rf "$lock_path" 2>/dev/null || true
    fi

    if mkdir "$lock_path" 2>/dev/null; then
        # --- Windows/Git Bash 互換の安全な変数解決 (set -u 対策) ---
        local user
        user="$(resolve_user_id)"
        
        local host="${COMPUTERNAME:-}"
        [ -z "$host" ] && host="${HOSTNAME:-}"
        [ -z "$host" ] && host="Unknown"
        
        local current_pid="$$"
        local now; now="$(date +%s)"
        
        echo "{\"user\":\"$user\",\"host\":\"$host\",\"pid\":\"$current_pid\",\"epoch\":$now}" > "$lock_path/meta.json"
        return 0
    fi
    return 1
}

acquire_with_retry() {
    local lock_path="$1"
    local retry_max="$2"
    local ttl="$3"
    local backoff=1
    
    for ((i=0; i<retry_max; i++)); do
        mk_lock "$lock_path" "$ttl" && return 0
        log_warn "Lock busy '$lock_path' - retry $((i+1))/$retry_max (sleep ${backoff}s)"
        sleep "$backoff"
        backoff=$((backoff * 2))
        [ "$backoff" -gt 30 ] && backoff=30
    done
    return 1
}

# --- Policy Check ---
while read -r local_ref local_sha remote_ref remote_sha; do
    if [[ "$remote_ref" == refs/tags/* ]]; then
        if [ "$remote_sha" != "0000000000000000000000000000000000000000" ]; then
            log_error "Immutable tags: moving or deleting '$remote_ref' is prohibited."
            exit 1
        fi
    fi
    if ! fast_forward_ok "$remote_sha" "$local_sha"; then
        log_error "Fast-forward required for '$remote_ref'. Fetch and rebase/merge first."
        exit 1
    fi
done < "$updates_file"

# --- Lock Acquisition ---
acquired_locks=()

if [[ "${ENABLE_GLOBAL_LOCK,,}" == "true" || "$ENABLE_GLOBAL_LOCK" == "1" ]]; then
    global_lock="$lock_base/global.lock"
    if ! acquire_with_retry "$global_lock" "$RETRY_MAX" "$TTL"; then
        log_error "Repository busy (global lock). Try again later."
        exit 1
    fi
    acquired_locks+=("$global_lock")
fi

if [[ "${ENABLE_PER_REF_LOCK,,}" == "true" || "$ENABLE_PER_REF_LOCK" == "1" ]]; then
    while read -r local_ref local_sha remote_ref remote_sha; do
        safe_name="$(echo "$remote_ref" | sed 's|/|__|g')"
        ref_lock="$refs_lock_dir/$safe_name.lock"
        if ! acquire_with_retry "$ref_lock" "$RETRY_MAX" "$TTL"; then
            log_error "Ref busy '$remote_ref'. Try again later."
            exit 1
        fi
        acquired_locks+=("$ref_lock")
    done < "$updates_file"
fi

rm -f "$updates_file" 2>/dev/null

# --- Lock Releaser (バックグラウンドで Push 終了を監視して解除) ---
if [ ${#acquired_locks[@]} -gt 0 ]; then
    # 親プロセス (git push) の PID を取得
    push_pid=$PPID
    
    # バックグラウンドプロセスとして監視と解除を登録
    (
        # MSYS2/Git Bash 環境でも動作するポーリング監視
        while kill -0 "$push_pid" 2>/dev/null; do
            sleep 1
        done
        
        # 親プロセス(push)が終了したら取得したロックを削除
        for lck in "${acquired_locks[@]}"; do
            rm -rf "$lck" 2>/dev/null || true
        done
    ) </dev/null >/dev/null 2>&1 & disown
fi

log_info "Locks acquired. Proceeding with push."
exit 0
