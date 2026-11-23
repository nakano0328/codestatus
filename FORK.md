# このフォークについて

[henriquegpb/codestatus](https://github.com/henriquegpb/codestatus) に、Web 版 ChatGPT の会話を並べる機能を足したものです。
ChatGPT の状態は Chrome 拡張 [chatgpt-unread](https://github.com/nakano0328/chatgpt-unread) の中継プログラムから、hook と同じソケット・同じ形式で届きます。

変更はすべて `chatgpt` ブランチにあります。

## 足したもの

- `AgentProvider.chatGPT`（wire 上は `"provider": "chatgpt"`）と `HostApplication.chrome`
- wire の `title` と `conversation_url`。ChatGPT のときだけ読み、URL は `https://chatgpt.com` / `https://chat.openai.com` のみ受け付ける
- 行の名前は会話タイトル。クリックするとその会話を Chrome で開く
- ChatGPT の行はプロセスを持たないので、再起動時の生存確認・スリープ復帰時の reconnecting・スリープ防止の対象から外す
- 完了通知の見出しを「ChatGPT finished」にする（「in ChatGPT」と重ならないように）

## ビルドとインストール（Xcode なし、Command Line Tools だけで可）

```bash
scripts/test.sh            # テスト。CLT の Swift Testing の場所を指定して swift test を動かす
scripts/install-local.sh   # ビルドして /Applications/CodeStatus.app と入れ替える
```

- 入れ替え前のアプリは `dist/CodeStatus-previous.app` に残る。戻すときはそれを `/Applications` に戻す
- 簡易署名（ad-hoc）なので自動アップデートは動かない。本家を取り込むときは `git fetch upstream && git merge upstream/main` してから `scripts/install-local.sh`
- 署名が変わるため、ターミナルの行を初めてクリックしたときにオートメーションの許可を聞き直される
