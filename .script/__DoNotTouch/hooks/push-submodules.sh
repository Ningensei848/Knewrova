#!/usr/bin/env bash
# push-submodules.sh
# 親の pre-push 時に、管轄サブモジュールを origin に一括 push する

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

log_info "Pushing managed submodules for $USER_ID..."

push_errors=0

# 対象が数個前提のため、シンプルな直列処理で確実に行う
while read -r p; do
    [ -z "$p" ] && continue
    [ ! -e "$p/.git" ] && continue

    safe_p="$(echo "$p" | sed 's|/|_|g')"
    err_log="$ROOT/.git/push_err_$safe_p.log"

    # Git push は差分がなければ "Everything up-to-date" で即座に終了するため、事前の差分チェックは不要
    if ! "$GIT_EXE" -C "$p" push origin "$SUBMODULE_BRANCH" >/dev/null 2>"$err_log"; then
        log_error "Submodule push failed [$p]:"
        cat "$err_log" >&2
        push_errors=$((push_errors + 1))
    fi
    rm -f "$err_log" 2>/dev/null || true

done <<< "$managed"

if [ "$push_errors" -gt 0 ]; then
    log_error "$push_errors submodule push(es) failed. Parent push continues."
else
    log_info "Submodule pushes completed successfully."
fi

exit 0
