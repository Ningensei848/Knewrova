#!/usr/bin/env bash
# commit-submodules.sh
# 親専用：管轄のサブモジュールをAdd+Commitし、親でgitlinkをstageする

set -eu
HOOK_DIR="$(dirname "$0")"
source "$HOOK_DIR/common.sh"

GIT_EXE="${1:-git}"
ROOT="$(resolve_root)"
cd "$ROOT"

# .envの読み込み (GIT_DIR等の環境変数汚染をリセットした上で実行)
unset GIT_DIR GIT_WORK_TREE GIT_EXEC_PATH
load_env "$ROOT/.env"
USER_ID="$(resolve_user_id)"

SUBMODULE_BRANCH="main"
SUBMODULE_JOBS="${GIT_SUBMODULE_JOBS:-4}"

[ ! -f ".gitmodules" ] && exit 0

CACHE_DIR="$ROOT/.cache"
CACHE_FILE="$CACHE_DIR/managed_submodules.${USER_ID}.list"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

GM_MTIME="$(stat -c %Y ".gitmodules" 2>/dev/null || date -r ".gitmodules" +%s 2>/dev/null || echo 0)"
lc_uid="${USER_ID,,}"

# キャッシュ判定とサブモジュール抽出
managed=""
if [ -f "$CACHE_FILE" ] && [ "$(awk -F= '/^# *mtime=/{print $2}' "$CACHE_FILE" 2>/dev/null | tail -n1)" = "$GM_MTIME" ]; then
    managed="$(awk 'NF && $0 !~ /^#/{print $0}' "$CACHE_FILE")"
else
    # url または path に USER_ID を含むサブモジュールを抽出
    readarray -t keys < <("$GIT_EXE" config -f .gitmodules --get-regexp '^submodule\..*\.(path|url)' 2>/dev/null | awk -v uid="$lc_uid" 'BEGIN{IGNORECASE=1} tolower($2) ~ uid {sub("submodule\\.","",$1); sub("\\.(path|url)","",$1); print $1}' | sort -u)
    
    local_managed=()
    for key in "${keys[@]}"; do
        path="$("$GIT_EXE" config -f .gitmodules --get "submodule.$key.path" 2>/dev/null || echo "$key")"
        [ -n "$path" ] && local_managed+=("$path")
    done
    managed="$(printf '%s\n' "${local_managed[@]:-}")"

    echo "# mtime=$GM_MTIME ts=$(date '+%Y-%m-%dT%H:%M:%S')" > "$CACHE_FILE"
    echo "$managed" >> "$CACHE_FILE"
fi

[ -z "$managed" ] && exit 0

log_info "Managed Submodules for $USER_ID:"
while read -r p; do [ -n "$p" ] && log_info "  - $p"; done <<< "$managed"

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t commit-submodules)"
success_list="$tmpdir/committed.list"
error_list="$tmpdir/commit_errors.list"
touch "$success_list" "$error_list"

commit_pids=()
while read -r p; do
    [ -z "$p" ] && continue
    [ ! -e "$p/.git" ] && continue

    git_dir_abs="$("$GIT_EXE" -C "$p" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
    [ -z "$git_dir_abs" ] && continue

    (
        g() {
            GIT_DIR="$git_dir_abs" GIT_COMMON_DIR="$git_dir_abs" GIT_WORK_TREE="$p" GIT_INDEX_FILE="$git_dir_abs/index" "$GIT_EXE" -c core.hooksPath= "$@"
        }
        
        changes="$(g status --porcelain | wc -l | tr -d ' ')"
        [ "$changes" -eq 0 ] && exit 0

        g add -A
        msg="pre-commit: update $p ($(date '+%Y-%m-%d %H:%M'))"
        
        if g commit -m "$msg" --no-verify >/dev/null 2>&1; then
            echo "$p" >> "$success_list"
        else
            echo "$p" >> "$error_list"
            exit 1
        fi
    ) &
    commit_pids+=($!)
done <<< "$managed"

for pid in "${commit_pids[@]}"; do wait "$pid" || true; done

failed_commits="$(cat "$error_list" 2>/dev/null || true)"
committed_paths="$(cat "$success_list" 2>/dev/null || true)"
rm -rf "$tmpdir"

if [ -n "$failed_commits" ]; then
    log_error "One or more submodule commits failed:"
    while read -r f; do [ -n "$f" ] && log_error "  - $f"; done <<< "$failed_commits"
    exit 1
fi

[ -z "$committed_paths" ] && exit 0

# 親でgitlinkをステージ
while read -r p; do
    [ -n "$p" ] && "$GIT_EXE" add -- "$p"
done <<< "$committed_paths"

# プッシュ処理 (バックグラウンドで並列実行)
push_pids=()
while read -r p; do
    [ -z "$p" ] && continue
    git_dir_abs="$("$GIT_EXE" -C "$p" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
    GIT_DIR="$git_dir_abs" GIT_COMMON_DIR="$git_dir_abs" GIT_WORK_TREE="$p" "$GIT_EXE" push origin "$SUBMODULE_BRANCH" >/dev/null 2>&1 &
    push_pids+=($!)
done <<< "$committed_paths"

push_errors=0
for pid in "${push_pids[@]}"; do
    wait "$pid" || push_errors=$((push_errors + 1))
done

[ "$push_errors" -gt 0 ] && log_error "$push_errors push(es) failed. Parent commit continues."
exit 0
