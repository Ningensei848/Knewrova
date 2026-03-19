#!/usr/bin/env bash
# commit-submodules.sh
# 親専用：管轄のサブモジュールをコミットし、親でgitlinkをstageする（Pushは行わない）

set -eu
HOOK_DIR="$(dirname "$0")"
source "$HOOK_DIR/common.sh"

GIT_EXE="${1:-git}"
ROOT="$(resolve_root)"
cd "$ROOT"

unset GIT_DIR GIT_WORK_TREE GIT_EXEC_PATH GIT_INDEX_FILE
load_env "$ROOT/.env"
USER_ID="$(resolve_user_id)"

SUBMODULE_BRANCH="main"
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

# --- 1. 変更検知とコミット ---
commit_pids=()
while read -r p; do
    [ -z "$p" ] && continue
    [ ! -e "$p/.git" ] && continue

    (
        g() { "$GIT_EXE" -C "$p" -c core.hooksPath= "$@"; }
        
        if g status --porcelain | grep -q .; then
            current_branch="$(g rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
            if [ "$current_branch" != "$SUBMODULE_BRANCH" ]; then
                if ! g checkout "$SUBMODULE_BRANCH" >/dev/null 2>&1; then
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
    
    if [ "${#commit_pids[@]}" -ge "$SUBMODULE_JOBS" ]; then
        for pid in "${commit_pids[@]}"; do wait "$pid" || true; done
        commit_pids=()
    fi
done <<< "$managed"

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

rm -rf "$tmpdir"
exit 0
