#!/usr/bin/env bash
# check-push-policy.sh

set -eu
source "$(dirname "$0")/common.sh"

REMOTE_NAME="$1"
REMOTE_URL="$2"

log_info "Checking push policy for remote: $REMOTE_URL"

USER_ID="$(resolve_user_id)"
if [ -z "$USER_ID" ] || [ "$USER_ID" = "Unknown" ]; then
    log_error "USER_ID could not be resolved."
    exit 1
fi

ROOT="$(resolve_root)"
load_env "$ROOT/.env"

# 1. UNCパスのチェック (\\server\share 等への直接push禁止)
if [[ "$REMOTE_URL" == \\\\* ]] || [[ "$REMOTE_URL" == //* ]]; then
    log_error "Pushing to UNC paths is prohibited. Please use mapped drives (e.g., R:)."
    exit 1
fi

norm_url="$(normalize_path "$REMOTE_URL")"

# 2. 許可リストの構築
ALLOWED_LIST=()
[ -n "${TEAM_REPO:-}" ] && ALLOWED_LIST+=("$(normalize_path "$TEAM_REPO")")
ALLOWED_LIST+=("R:/UsersVault/${USER_ID}.git")
ALLOWED_LIST+=("R:/Submodule/Shared/User/${USER_ID}.git")
ALLOWED_LIST+=("R:/Submodule/Shared/Project/${USER_ID}.git")

# 3. 許可判定 (前方一致・大文字小文字区別なし)
is_allowed=0
matched_prefix=""
for allowed in "${ALLOWED_LIST[@]}"; do
    norm_allowed="$(normalize_path "$allowed")"
    if [[ "${norm_url,,}" == "${norm_allowed,,}"* ]]; then
        is_allowed=1
        matched_prefix="$norm_allowed"
        break
    fi
done

if [ "$is_allowed" -eq 0 ]; then
    log_error "Pushing to unauthorized remote URL is prohibited."
    log_error "Normalized RemoteUrl: $norm_url"
    log_info "Allowed list:"
    for a in "${ALLOWED_LIST[@]}"; do log_info "  - $a"; done
    exit 1
fi

# 4. リポジトリ所有者の特定 (mainへのpush制限用)
repo_owner_id=""
leaf="${norm_url##*/}"
if [[ "$leaf" =~ ^([^/\\]+)\.git$ ]]; then
    repo_owner_id="${BASH_REMATCH[1]}"
elif [[ "${matched_prefix,,}" =~ /([^/]+)\.git$ ]]; then
    repo_owner_id="${BASH_REMATCH[1]}"
fi

# 5. STDINからの更新情報の検証
has_main_push=0
updates=()
while read -r local_ref local_sha remote_ref remote_sha; do
    [ -z "$local_ref" ] && continue
    updates+=("$local_ref $local_sha $remote_ref $remote_sha")
    [ "$remote_ref" = "refs/heads/main" ] && has_main_push=1
done

if [ "$has_main_push" -eq 1 ]; then
    if [ -z "$repo_owner_id" ]; then
        log_error "Could not determine repository owner. Pushing to 'main' is prohibited."
        exit 1
    fi
    if [ "$repo_owner_id" != "$USER_ID" ]; then
        log_error "Pushing to 'main' is only allowed for the repository owner."
        log_error "Repository Owner: $repo_owner_id, You: $USER_ID"
        exit 1
    fi
fi

log_info "Push policy check passed."
# 後続のスクリプトで STDIN を再利用できないため、一時ファイルに保存
printf "%s\n" "${updates[@]}" > "$ROOT/.git/pre-push-updates.tmp"
exit 0
