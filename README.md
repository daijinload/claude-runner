# claude-runner

`claude` CLI をタスク単位で駆動するランナー群のモノレポ。

## バリアント

| ディレクトリ | 概要 |
|---|---|
| [`process/`](./process/) | タスク 1 件ごとに `claude -p` を**別プロセス**として起動する Bash 版。長セッションの `compact` を回避するため毎タスクをまっさら状態で実行する。`plan` → `run-all` 型の対話／並列実行 |
| [`support/`](./support/) | claude を `plan` でだけ自動起動する軽量版。実装・レビューは**別窓で claude を立ち上げて貼り付ける**運用。並列・fan-out は claude 側に任せる |

## ライセンス

MIT — [LICENSE](./LICENSE) 参照
