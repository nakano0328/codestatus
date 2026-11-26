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

## Claude デスクトップアプリのセッション

デスクトップアプリの Code タブも `~/.claude/settings.json` の hook を読むので、イベント自体は届きます。ずれていたのは次の点で、`ClaudeDesktop` と `DesktopSessionReader` で補っています。

- アプリは、開いたセッションのプロセスを自分の判断で止める（メモリ不足、終了、再起動）。止まってもセッションは続いていて、次に開くと `--resume` で別プロセスとして再開する。本家はプロセス終了をセッション終了として扱うので、見ていないうちに終わった行が消えていた
  - プロセス終了と `SessionEnd` は「一時停止」として扱い、行は free のまま残す。実行中に止まった場合も free にするが、「finished」の通知は出さない
  - 一時停止中の行は、ターンが「見ていないあいだに」終わったものだけ残す。終わった瞬間にあなたがそのセッションを見ていたか（下の「見ているセッションの通知だけ止める」と同じ判定）を CodeStatus が覚えておき（`unseenSince`）、そのあとアプリでそのセッションに切り替えたら（`claude-code-sessions/…/local_*.json` の `lastFocusedAt`）、アーカイブしたら、消したら外す。読めないときは残す
  - アプリの `lastTurnEdgeAt > lastFocusedAt` だけで判断しないのは、`lastFocusedAt` が「切り替えた時刻」でしかないため。開いたまま終わるのを見ていたセッションまで未読になり、実機では 10 月のものを含む 10 件がそう見えていた
- 新しいセッション用に `~/.claude/spares/` で予備のプロセスを先に起動している。その時点で `SessionStart` が届くので、予備のあいだは一覧に出さない
- 行の鍵は、hook が送る `CLAUDE_CODE_HOST_SESSION_ID`（`local_…`）。予備から本番、再開、`/clear` でエージェント側のセッション ID が変わっても 1 行のまま
- `TERM_PROGRAM` がないので、`CLAUDE_CODE_ENTRYPOINT=claude-desktop` で見分ける。右端は「Claude」、クリックで `claude://code/continue?session=local_…` を開く（アプリの Dock メニューと同じリンク）

## クラウドのセッション（claude.ai/code）

クラウドのセッションは Anthropic 側のマシンで動くので、hook はこの Mac に届きません。代わりに、デスクトップアプリの中の Web アプリが IndexedDB に保存している React Query のキャッシュから、セッション一覧（`sessions_api_list_sessions`）だけを読みます（`CloudSessionReader`）。外部サービスも認証情報も使いません。

- 場所は `~/Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.blob/1/*/*`。保存のたびに新しいファイルになるので、一番新しいものを読む
- 形式は Blink の値ラッパー → Snappy 圧縮 → V8 のシリアライズ形式。`ChromiumValueDecoding` に必要な分だけ実装した。範囲外読み・深すぎる入れ子・巨大な長さはすべてエラーにして、クラッシュしない
- 状態は、アプリのサイドバーと同じ項目から決める: `worker_status` / `session_status` が `running`、`session_status` が `pending`（作った直後）、または `status_bucket` が `working` なら busy、`blocked` か `need_input` なら入力待ち、それ以外は free
- 実機で確かめたこと: デスクトップアプリを裏に回したまま（前面は Chrome）クラウドのセッションを動かすと、実行中のあいだアプリは数秒おきに一覧を取り直し、完了から約 9 秒で CodeStatus が通知した
- 一覧に出すのは、作業中か未読（`unread`）のものだけ。読み終わったものや、アーカイブしたものは出さない
- 数秒で終わるターンは、キャッシュを 2 回読むあいだに始まって終わり、実行中の状態が一度も見えないことがある。そこで、前回読んだときは既読だった（または存在しなかった）セッションが、今回「終わっていて未読」なら、そのあいだにターンが見られずに終わったとして、実行中を見たときと同じ通知を出す。起動直後の 1 回目の読み取りと、デスクトップアプリを閉じていたあとの 1 回目は比べる相手がないので通知しない（昔の未読がまとめて鳴らないように）
- 右端は「Cloud」、クリックで `claude://code/session_…` をデスクトップアプリで開く（アプリがなければ claude.ai）
- デスクトップアプリが起動していないときは、キャッシュが更新されないので、クラウドの行はすべて外す。読めないときは前の状態のまま
- タイトルはメモリにだけ持ち、`sessions.json` には保存しない。クラウドの行自体も保存せず、再起動後は最初の巡回でキャッシュから作り直す
- アプリの非公開の形式なので、アプリの更新で読めなくなることがある。その場合はクラウドの行が出なくなるだけで、他には影響しない

## 再起動・スリープ復帰のあとの確かめ直し

本家は、再起動やスリープ復帰のあと、すべての行を reconnecting にして次の hook を待つ。待機中のセッションは hook を送らないので、何時間でも reconnecting のままになっていた（本家では再起動時の復元が効いていなかったので、表に出ていなかった）。

Claude Code は、動いているプロセスごとに `~/.claude/sessions/<pid>.json` を書いていて（`claude agents --json` が読むもの）、そこに今の状態（`busy` / `waiting` / `idle` / `shell`）がある。reconnecting の Claude Code の行は、10 秒ごとの巡回でこれを読んで状態を戻す（`ClaudeSessionFile`）。通知は出さない。ファイルが読めないとき（Codex を含む）は、これまでどおり次の hook を待つ。

同じファイルで、プロセスの検出でしか見つかっていないデスクトップのセッション（CodeStatus が止まっているあいだに始まり、そのあと何も起きていないもの）も、ちゃんとした行にする。そうしないと「報告していないエージェント」に数えられて、設定が壊れているように見えていた。ターミナルのセッションは、どのターミナルかがファイルからわからないので、これまでどおり次の hook を待つ。

## 見ているセッションの通知だけ止める

本家は「セッションのアプリが前面にあれば、そのセッションの通知は出さない」。デスクトップアプリは 1 つのウィンドウで全セッションを扱うので、そのままだと 1 つを読んでいるあいだ、ほかのセッションの通知まで止まっていた。

- デスクトップアプリのログ（`~/Library/Logs/Claude/main.log`）の末尾から、最後の `LocalSessions.setFocusedSession: sessionId=…` を読み、今開いているセッションを知る（`local_…` / `session_…` / `null`）
- アプリが前面にあり、そのセッションをメインウィンドウで開いているか、別ウィンドウで開いている（`~/Library/Application Support/Claude/session-popouts.json`）ときだけ通知を止める。クラウドのセッションも同じ
- ログで判断できないときは、デスクトップのセッションは本家どおり「アプリが前面なら止める」、クラウドのセッションは止めない
- ログを読むのは、通知を出すかどうか決めるとき、しかもアプリが前面のときだけ

ついでに直した本家側の不具合:

- 再起動時の復元が `SessionRegistry.update` 経由で、既にある行しか置き換えないため何も戻っていなかった。`restore` を足した
- プロセス検出と hook が同じプロセスに 2 行持つと、終了が片方にしか届かず、もう片方が 10 秒ごとに「reaping」され続けていた。終了はそのプロセスの全行に届ける

## ビルドとインストール（Xcode なし、Command Line Tools だけで可）

```bash
scripts/test.sh            # テスト。CLT の Swift Testing の場所を指定して swift test を動かす
scripts/install-local.sh   # ビルドして /Applications/CodeStatus.app と入れ替える
```

- 入れ替え前のアプリは `dist/CodeStatus-previous.app` に残る。戻すときはそれを `/Applications` に戻す
- 簡易署名（ad-hoc）なので自動アップデートは動かない。本家を取り込むときは `git fetch upstream && git merge upstream/main` してから `scripts/install-local.sh`
- 署名が変わるため、ターミナルの行を初めてクリックしたときにオートメーションの許可を聞き直される
