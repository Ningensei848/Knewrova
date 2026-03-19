#!/usr/bin/env bash
# commit-submodules.sh
# 親専用：管轄のサブモジュールをAdd+Commitし、親でgitlinkをstageする

set -eu
HOOK_DIR="$(dirname "$0")"
source "$HOOK_DIR/common.sh"

GIT_EXE="${1:-git}"
ROOT="$(resolve_root)"
cd "$ROOT"

# 環境変数汚染をリセット（GIT_INDEX_FILE が残っているとサブモジュール操作が親のインデックスに影響する）
unset GIT_DIR GIT_WORK_TREE GIT_EXEC_PATH GIT_INDEX_FILE
load_env "$ROOT/.env"
USER_ID="$(resolve_user_id)"

SUBMODULE_BRANCH="main"
# 同時実行数の制御 (多すぎるとWindowsでプロセス起動待ちによるI/O渋滞が起きるため 8 程度が最適)
SUBMODULE_JOBS="${GIT_SUBMODULE_JOBS:-8}"

[ ! -f ".gitmodules" ] && exit 0

CACHE_DIR="$ROOT/.cache"
CACHE_FILE="$CACHE_DIR/managed_submodules.${USER_ID}.list"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

GM_MTIME="$(stat -c %Y ".gitmodules" 2>/dev/null || date -r ".gitmodules" +%s 2>/dev/null || echo 0)"
lc_uid="${USER_ID,,}"

managed=""
if [ -f "$CACHE_FILE" ] && [ "$(awk -F= '/^# *mtime=/{print $2}' "$CACHE_FILE" 2>/dev/null | tail -n1)" = "$GM_MTIME" ]; then
    managed="$(awk 'NF && $0 !~ /^#/{print $0}' "$CACHE_FILE")"
else
    # O(1) パース: git config を1回だけ呼び出し、awkで一括抽出 (100サブモジュール時の起動オーバーヘッド削減)
    local_managed=()
    eval "$("$GIT_EXE" config -f .gitmodules -l 2>/dev/null | awk -v uid="$lc_uid" -F= '
        BEGIN { IGNORECASE=1 }
        /^submodule\..*\.(path|url)/ {
            split($1, a, ".");
            name = a[2];
            prop = a[3];
            val = $2;
            data[name][prop] = val;
        }
        END {
            for (name in data) {
                path = data[name]["path"] ? data[name]["path"] : name;
                url = data[name]["url"];
                if (tolower(url) ~ uid || tolower(path) ~ uid) {
                    print "local_managed+=(\"" path "\")";
                }
            }
        }
    ')"
    
    if [ ${#local_managed[@]} -gt 0 ]; then
        managed="$(printf '%s\n' "${local_managed[@]}")"
    fi

    echo "# mtime=$GM_MTIME ts=$(date '+%Y-%m-%dT%H:%M:%S')" > "$CACHE_FILE"
    [ -n "$managed" ] && echo "$managed" >> "$CACHE_FILE"
fi

[ -z "$managed" ] && exit 0

log_info "Managed Submodules for $USER_ID:"
while read -r p; do [ -n "$p" ] && log_info "  - $p"; done <<< "$managed"

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t commit-submodules)"
success_list="$tmpdir/committed.list"
error_list="$tmpdir/commit_errors.list"
touch "$success_list" "$error_list"

# --- 1. 変更検知とコミット (ジョブ数を制限したバッチ並列処理) ---
commit_pids=()
while read -r p; do
    [ -z "$p" ] && continue
    [ ! -e "$p/.git" ] && continue

    (
        g() {
            # GIT_DIR等をunsetしたため、シンプルに -C オプションのみで動作する
            "$GIT_EXE" -C "$p" -c core.hooksPath= "$@"
        }
        
        # 変更チェック (grep -q . で短絡評価。1件でも変更があれば即座に true)
        if g status --porcelain | grep -q .; then
            # 常に $SUBMODULE_BRANCH (main) でコミットするためのブランチ切り替え
            current_branch="$(g rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
            if [ "$current_branch" != "$SUBMODULE_BRANCH" ]; then
                if ! g checkout "$SUBMODULE_BRANCH" >/dev/null 2>&1; then
                    # そのままの切り替えに失敗した場合（未追跡ファイルや変更の衝突、ブランチ未作成時）
                    g stash push -u -q -m "pre-commit auto-stash" >/dev/null 2>&1 || true
                    g checkout "$SUBMODULE_BRANCH" >/dev/null 2>&1 || g checkout -b "$SUBMODULE_BRANCH" >/dev/null 2>&1
                    g stash pop -q >/dev/null 2>&1 || true
                fi
            fi

            g add -A
            msg="pre-commit: update $p ($(date '+%Y-%m-%d %H:%M'))"
            
            if g commit -m "$msg" --no-verify >/dev/null 2>&1; then
                echo "$p" >> "$success_list"
            else
                echo "$p" >> "$error_list"
                exit 1
            fi
        fi
    ) &
    commit_pids+=($!)
    
    # 並列数が設定値に達したら、すべて待機してから次へ進む (安全なバッチ処理)
    if [ "${#commit_pids[@]}" -ge "$SUBMODULE_JOBS" ]; then
        for pid in "${commit_pids[@]}"; do wait "$pid" || true; done
        commit_pids=()
    fi
done <<< "$managed"

# 残りのプロセスを待機
for pid in "${commit_pids[@]}"; do wait "$pid" || true; done

failed_commits="$(cat "$error_list" 2>/dev/null || true)"
committed_paths="$(cat "$success_list" 2>/dev/null || true)"

if [ -n "$failed_commits" ]; then
    log_error "One or more submodule commits failed:"
    while read -r f; do [ -n "$f" ] && log_error "  - $f"; done <<< "$failed_commits"
    rm -rf "$tmpdir"
    exit 1
fi

[ -z "$committed_paths" ] && rm -rf "$tmpdir" && exit 0


# --- 2. 親で gitlink をステージ ---
while read -r p; do
    [ -n "$p" ] && "$GIT_EXE" add -- "$p"
done <<< "$committed_paths"


# --- 3. プッシュ処理 (同じくジョブ数を制限したバッチ並列処理) ---
push_pids=()
push_errors=0
while read -r p; do
    [ -z "$p" ] && continue

    "$GIT_EXE" -C "$p" push origin "$SUBMODULE_BRANCH" >/dev/null 2>&1 &
    push_pids+=($!)
    
    # 並列数が設定値に達したら待機
    if [ "${#push_pids[@]}" -ge "$SUBMODULE_JOBS" ]; then
        for pid in "${push_pids[@]}"; do wait "$pid" || push_errors=$((push_errors + 1)); done
        push_pids=()
    fi
done <<< "$committed_paths"

# 残りのプロセスを待機
for pid in "${push_pids[@]}"; do wait "$pid" || push_errors=$((push_errors + 1)); done

rm -rf "$tmpdir"

[ "$push_errors" -gt 0 ] && log_error "$push_errors push(es) failed. Parent commit continues."
exit 0
