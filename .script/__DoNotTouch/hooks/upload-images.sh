#!/usr/bin/env bash
# upload-images.sh
# 責務: Markdown内の画像(wikiリンク/相対パス)のローカル実体を共有フォルダへコピーする

set -eu
HOOK_DIR="$(dirname "$0")"
source "$HOOK_DIR/common.sh"

ROOT="$(resolve_root)"
load_env "$ROOT/.env"
USER_ID="$(resolve_user_id)"

# --- 画像パス絶対化（Vault直下 __Attachment/ とサブディレクトリ YYYY/MM/ 対応） ---
resolve_abs_image_path() {
    local md_file="$1"     # 相対: ROOT基準
    local img_path="$2"    # Markdown記載の画像パス

    if [[ "$img_path" =~ ^[A-Za-z]:/ ]] || [[ "$img_path" =~ ^/ ]] || [[ "$img_path" =~ ^file:// ]]; then
        echo "$img_path"; return 0
    fi

    local abs=""
    local md_dir; md_dir="$(dirname "$md_file")"

    if [[ "$img_path" == __Attachment/* ]]; then
        abs="$ROOT/$img_path"
    elif [ -f "$ROOT/$md_dir/$img_path" ]; then
        abs="$ROOT/$md_dir/$img_path"
    else
        # __Attachment 以下のサブディレクトリ (YYYY/MM 等) から検索
        local base_name="$(basename "$img_path")"
        local found
        found="$(find "$ROOT/__Attachment" -type f -name "$base_name" 2>/dev/null | head -n 1 || true)"
        if [ -n "$found" ]; then
            abs="$found"
        else
            abs="$ROOT/$md_dir/$img_path"
        fi
    fi

    normalize_path "$abs"
}

copy_one() {
    local src_rel="$1"
    local md_file="$2"

    if [ -z "${UPLOAD_ROOT:-}" ]; then
        log_error "UPLOAD_ROOT is not set."; return 1
    fi

    local upload_root; upload_root="$(normalize_path "$UPLOAD_ROOT")"
    local src_abs; src_abs="$(resolve_abs_image_path "$md_file" "$src_rel")"

    if [ ! -f "$src_abs" ]; then
        log_info "  [Upload] Skip: local file missing -> $src_rel"
        return 10
    fi

    # __Attachment/ 以下の階層(YYYY/MM等)を維持する
    local dest_rel
    local attachment_dir="$ROOT/__Attachment/"
    # パス比較のために正規化しておく
    local norm_src_abs; norm_src_abs="$(normalize_path "$src_abs")"
    local norm_attach_dir; norm_attach_dir="$(normalize_path "$attachment_dir")"

    if [[ "$norm_src_abs" == "$norm_attach_dir"* ]]; then
        dest_rel="${norm_src_abs#$norm_attach_dir}"
    else
        dest_rel="$(basename "$src_rel")"
    fi

    local dest_path="$upload_root/$USER_ID/$dest_rel"
    local dest_dir; dest_dir="$(dirname "$dest_path")"

    if [ -f "$dest_path" ]; then
        log_info "  [Upload] Skip: already exists -> $dest_path"
        # 既に存在する場合もリンク置換用にマップへ記録
        echo "${src_rel}|${dest_path}" >> "$ROOT/.git/upload_links_map.tmp"
        return 10
    fi

    if [ ! -d "$dest_dir" ]; then
        if [ "${DRY_RUN:-false}" = "true" ]; then
            log_info "[Upload] DRY-RUN: mkdir -p \"$dest_dir\""
        else
            mkdir -p "$dest_dir" || { log_error "[Upload] Failed to create directory: \"$dest_dir\""; return 1; }
        fi
    fi

    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[Upload] DRY-RUN: cp \"$src_abs\" \"$dest_path\""
        echo "${src_rel}|${dest_path}" >> "$ROOT/.git/upload_links_map.tmp"
        return 0
    else
        if cp -f "$src_abs" "$dest_path"; then
            log_info "[Upload] Copied: \"$src_abs\" -> \"$dest_path\""
            rm -f "$src_abs" || log_warn "[Upload] Failed to delete local file: \"$src_abs\""
            # リンク置換用に元のファイル名とアップロード先パスの対応を記録
            echo "${src_rel}|${dest_path}" >> "$ROOT/.git/upload_links_map.tmp"
            return 0
        else
            log_error "[Upload] Copy failed: \"$src_abs\" -> \"$dest_path\""; return 1
        fi
    fi
}

main() {
    local md_file="$1"
    local md_abs="$ROOT/$md_file"
    
    [ ! -f "$md_abs" ] && log_error "[Upload] Markdown not found: $md_abs" && return 1

    # 画像リンクの抽出
    local images=()
    while read -r img; do
        if [ -n "$img" ]; then
            # エイリアスやサイズ指定 (| 以降) を除去
            img="${img%%|*}"
            images+=("$img")
        fi
    done < <(grep -oE '!\[\[[^]]+\]\]' "$md_abs" | sed -E 's/^!\[\[//; s/\]\]$//'; grep -oE '!\[[^]]*\]\((<[^>]+>|[^)]+)\)' "$md_abs" | sed -E 's/^!\[[^]]*\]\(<?([^)>]+)>?\)$/\1/')

    # ユニーク化
    readarray -t unique_images < <(printf "%s\n" "${images[@]}" | sort -u)

    local OK=0 SKIP=0 FAIL=0
    for img in "${unique_images[@]}"; do
        [ -z "$img" ] && continue
        img="${img#<}"; img="${img%>}"
        
        if [[ "$img" =~ ^file:// ]]; then
            SKIP=$((SKIP+1))
            continue
        fi

        local rc=0
        copy_one "$img" "$md_file" || rc=$?
        case "$rc" in
            0)  OK=$((OK+1)) ;;
            10) SKIP=$((SKIP+1)) ;;
            *)  FAIL=$((FAIL+1)) ;;
        esac
    done

    [ "$FAIL" -gt 0 ] && return 1
    [ "$OK" -gt 0 ] && return 0
    return 10
}

main "$@"
