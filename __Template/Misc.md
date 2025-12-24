---
title: "<% tp.file.title %>"
date: <% tp.date.now("YYYY-MM-DD") %>
tags:
  - Misc
aliases:
  - <% tp.date.now("YYYY年MM月DD日") %>
---

# <% tp.file.title %>

## これは何？
<!-- 簡単な説明。まだ分からなければ「未定義」と書く -->

## どこで使う？
<!-- 現場での利用場面や関連業務 -->

## 関連キーワード

<!--
  - [[関連語1]]
  - [[関連語2]]
-->

---

### メモ

-

<%*
// --- 処理: `Untitled.md` ないし `無題のファイル.md` という名前はリネームする ---
const isUntitled = (name) => {
  const patterns = [
    "untitled",        // 英語
    "無題のファイル",   // 日本語
    "無題",            // 短縮版
  ];
  return patterns.some((p) => name.startsWith(p));
}

const filename = tp.file.title.toLowerCase(); // 新規作成 or 空リンクのクリック
if (!isUntitled(filename)){
  // pass
  // 空リンクのクリックで作成したファイルにはリネームしない
} else {
  const timestamp = tp.date.now("YYYYMMDD_HHmmss");
  // 1. Windows Username を取得
  let userId = process.env.USERNAME;
  // 2. 取得できなかった場合、%USERPROFILE% の末尾要素を使う
  if (typeof userId !== "string" || !userId.length) {
    if (typeof process.env.USERPROFILE === "string"){
	  const leaf = process.env.USERPROFILE.split(/[\\/]/);
		userId = leaf[leaf.length - 1];
    }
  } 	
  // 3. それでもダメなら fallback
  if (!userId) {
	userId = "unknown";
  }
  // 4. ファイル名をリネーム
  await tp.file.rename(`${timestamp}_${userId}`);
}
%>