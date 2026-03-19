#!/usr/bin/env bash
# rewrite-mdlink.sh
# 責務: Markdown内のWikiLink(![[...]])を、共有フォルダを指す標準リンク(![alt](<file://...>))に置換する。

set -eu
HOOK_DIR="$(dirname "$0")"
source "$HOOK_DIR/common.sh"

ROOT="$(resolve_root)"
load_env "$ROOT/.env"

USER_ID="$(resolve_user_id)"
UPLOAD_ROOT="${UPLOAD_ROOT:-R:\\Upload}"
IMAGE_EXTS="${IMAGE_EXTS:-.png,.jpg,.jpeg,.gif,.bmp,.tif,.tiff,.webp}"
DRY_RUN="${DRY_RUN:-false}"

process_link_rewrite() {
    local match_str="$1"
    local target_file="$2"

    local content="${match_str#!\[\[}"
    content="${content%\]\]}"
    local filename="${content%%|*}"

    local file_ext=".${filename##*.}"
    if [[ ",$IMAGE_EXTS," != *",${file_ext,,},"* ]]; then
        return 0
    fi

    # upload-images.sh が記録したマッピングファイルを参照して新しいパスを取得
    local dest_path=""
    local map_file="$ROOT/.git/upload_links_map.tmp"
    if [ -f "$map_file" ]; then
        # awk を使ってファイル名 (filename) が完全一致するレコードのパスを取得する
        dest_path="$(awk -F'|' -v key="$filename" '$1==key {print $2; exit}' "$map_file")"
    fi

    local new_url=""
    if [ -n "$dest_path" ]; then
        # アップロード先の階層 (YYYY/MM 等) が反映された絶対パス
        new_url="file:///${dest_path}"
    else
        # マップに存在しない場合のフォールバック（旧仕様との互換性）
        local clean_root; clean_root="$(normalize_path "$UPLOAD_ROOT")"
        new_url="file:///${clean_root}/${USER_ID}/$(basename "$filename")"
    fi
    
    local basename_val; basename_val=$(basename "$filename")
    local alt_text="${basename_val%.*}"
    local new_link="![${alt_text}](<${new_url}>)"
    
    local search_pattern; search_pattern=$(echo "$match_str" | sed 's/\[/\\[/g; s/\]/\\]/g; s/|/\\|/g')

    if [ "${DRY_RUN,,}" = "true" ]; then
        log_info "(DRY-RUN) Would replace: $match_str -> $new_link"
    else
        sed -i "s|$search_pattern|$new_link|g" "$target_file"
        log_info "Replaced: $match_str -> $new_link"
    fi
}

main() {
    local target_file="$1"
    [ ! -f "$target_file" ] && exit 1

    while read -r match; do
        [ -n "$match" ] && process_link_rewrite "$match" "$target_file"
    done < <(grep -o '!\[\[[^]]*\]\]' "$target_file" | sort -u)

    exit 0
}

main "$@"
