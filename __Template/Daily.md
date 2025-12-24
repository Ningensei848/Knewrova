---
title: "<タイトルを設定してください>"
date: {{date:YYYY-MM-DD}}
tags:
  - daily
aliases: ["{{date:YYYY年MM月DD日}}"]
---

  # {{date:YYYY年MM月DD日}} ({{date:dddd}})

  ## ✅ 今日の目標

- [ ] 主要タスク1
	- タスクに対する補足説明
- [ ] 主要タスク2
	- これを行なうために必要なことは何か書き記す

## 📝 メモ

- 今日の気づきやアイデアを書く
- 

## 📅 スケジュール

- 午前：
	- 
- 午後：
	- 

## 🔗 関連リンク

- 

## ✅ 振り返り


- 良かったこと：
	- 
- 改善点：
	- 
<%*
  // 1. Windows Username を取得
  let userId = process.env.USERNAME;
  // 2. 取得できなかった場合、%USERPROFILE% の末尾要素を使う
  if (typeof userId !== "string" || !userId.length) {
    const profile = process.env.USERPROFILE;
    if (typeof profile === "string" && profile.length){
      const leaf = profile.split(/[\\/]/);
      userId = leaf[leaf.length - 1];
    }
  }
  const filename = tp.file.title; // ex. 2026-01-07
  const [year, month, day] = filename.split("-"); // => ["2026","01","07"]
  const newPath = `MyWork/Daily/${year}/${month}/${year}${month}${day}_${userId}`;
  const targetMdPath = `${newPath}.md`;

  // --- 親ディレクトリ作成（段階作成） ---
  const ensureFolder = async (fullPathLikeFile) => {
    const parts = fullPathLikeFile.split("/").slice(0, -1);
    let acc = "";
    for (let i = 0; i < parts.length; i++) {
      acc = i === 0 ? parts[0] : `${acc}/${parts[i]}`;
      const exists = await app.vault.adapter.exists(acc);
      if (!exists) {
        try {
          await app.vault.createFolder(acc);
        } catch (e) {
          const msg = String(e?.message || e).toLowerCase();
          if (!msg.includes("exist")) throw e;
        }
      }
    }
  };
  await ensureFolder(newPath);

  // --- 既存ファイルの厳密確認（フォルダとの混同を避ける） ---
  const abstract = app.vault.getAbstractFileByPath(targetMdPath);
  const mdExists =
    abstract
      ? (abstract.constructor?.name === "TFile")
      : await app.vault.adapter.exists(targetMdPath);

  const currentFile = app.workspace.getActiveFile();
  const currentPath = currentFile?.path ?? ""; // 例: "Untitled.md" 等

  if (mdExists) {
    // 既存あり：移動はしない（衝突回避）
    // 1) 既存ファイルへ切替
    await app.workspace.openLinkText(targetMdPath, '', false);

    // 2) 遅延削除（自分自身を即削除しない）
    //    切替が完了するように少し後で削除する
    setTimeout(async () => {
      try {
        const stillExists = currentPath && app.vault.getAbstractFileByPath(currentPath);
        if (stillExists) {
          await app.vault.trash(stillExists, true);
        }
      } catch (e) {
        console.debug('Delayed trash error:', e);
      }
    }, 0);

    new Notice(`既存ファイルがあるため、新規作成分を削除しました: ${newPath}`);
    // テンプレート処理をここで終了（以降のパースを止める）
    return;
  }

  // --- 既存なし：移動（拡張子なしのまま）
  try {
    await tp.file.move(newPath);
    new Notice(`新規ファイルを作成しました: ${newPath}`);
  } catch (e) {
    const msg = String(e?.message || e).toLowerCase();
    if (msg.includes("destination file already exists")) {
      // 想定外の並行作成競合。既存優先で遅延削除にフォールバック
      await app.workspace.openLinkText(targetMdPath, '', false);
      setTimeout(async () => {
        try {
          const stillExists = currentPath && app.vault.getAbstractFileByPath(currentPath);
          if (stillExists) {
            await app.vault.trash(stillExists, true);
          }
        } catch (err) {
          console.debug('Delayed trash on conflict error:', err);
        }
      }, 0);
      new Notice(`競合により新規作成分を削除しました（既存優先）: ${newPath}`);
      return;
    }
    new Notice(`移動時にエラーが発生しました: ${String(e)}`);
    throw e;
  }
%>
