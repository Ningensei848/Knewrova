#!/usr/bin/env bash
# common.sh: Gitフック用の共通関数群

# --- ログ出力 ---
log_info()  { printf "[%s][INFO] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
log_warn()  { printf "[%s][WARN] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { printf "[%s][ERROR] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# --- パス正規化 (Windows -> Unix形式) ---
# 例: R:\Upload -> R:/Upload, //server/share -> //server/share
normalize_path() {
    local p="$1"
    p="${p//\\//}"            # バックスラッシュをスラッシュに置換
    p="${p//\/\///}"          # 連続するスラッシュを1つに (UNCパスを壊さない程度に)
    p="${p#file://}"          # file:// プレフィックスを削除
    p="${p#localhost/}"
    p="$(echo "$p" | sed -E 's|^[a-zA-Z]:|/&|' | sed -E 's|^/([a-zA-Z]):|\U\1:|')" # R: -> R:
    p="${p%/}"                # 末尾のスラッシュを削除
    echo "$p"
}

# --- .env の安全な読み込み ---
load_env() {
    local env_path="$1"
    [ ! -f "$env_path" ] && return 0
    
    while IFS= read -r line || [ -n "$line" ]; do
        # CRLF (\r) と BOMの除去、前後の空白除去
        line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^\xEF\xBB\xBF//' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        
        # 空行とコメントをスキップ
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # KEY=VALUE形式のパース
        if [[ "$line" == *"="* ]]; then
            local key="${line%%=*}"
            local value="${line#*=}"
            
            key="$(echo "$key" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            # 保護キーの上書き禁止
            [[ "$key" == "GIT_EXE" || "$key" == "GIT_CMD" ]] && continue
            
            # 値のクォートおよびインラインコメントの除去
            value="$(echo "$value" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value#\"}"; value="${value%\"}"
            elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
                value="${value#\'}"; value="${value%\'}"
            else
                value="$(echo "$value" | sed -E 's/[[:space:]]+#.*$//')"
            fi
            
            # 環境変数へのエクスポート (evalを使わず安全に)
            export "$key"="$value"
        fi
    done < "$env_path"
}

# --- ユーザーIDの解決 ---
resolve_user_id() {
    local uid="${USER_ID:-}"
    if [ -n "$uid" ] && printf '%s' "$uid" | grep -Eq '^[A-Za-z0-9_.]+$'; then
        echo "$uid"; return 0
    fi
    local p="${USERPROFILE:-}"
    p="${p//\\//}"
    local leaf="${p##*/}"
    if [ -n "$leaf" ]; then
        echo "$leaf"; return 0
    fi
    local id_un
    if id_un="$(id -un 2>/dev/null)"; then
        echo "$id_un"; return 0
    fi
    echo "Unknown"
}

# --- Gitリポジトリルートの取得 ---
resolve_root() {
    local super top
    super="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    echo "${super:-$top}"
}
