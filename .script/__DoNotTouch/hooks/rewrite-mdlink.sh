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

generate_new_link() {
    local filename="$1"
    local basename_val; basename_val=$(basename "$filename")
    local alt_text="${basename_val%.*}"

    local clean_root; clean_root="$(normalize_path "$UPLOAD_ROOT")"
    local new_url="file:///${clean_root}/${USER_ID}/${filename}"
    
    echo "![${alt_text}](<${new_url}>)"
}

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

    local new_link; new_link=$(generate_new_link "$filename")
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
