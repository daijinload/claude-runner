# claude-runner

`claude` CLI をタスク単位で駆動するランナー群のモノレポ。

## バリアント

| ディレクトリ | 概要 |
|---|---|
| [`process-runner/`](./process-runner/) | タスク 1 件ごとに `claude -p` を**別プロセス**として起動する Bash 版。長セッションの `compact` を回避するため毎タスクをまっさら状態で実行する。`plan` → `run-all` 型の対話／並列実行 |

将来的に同じ `plan` → `run-all` インタフェースで実装が異なる版（例: 単一 CC セッション内で sub-agent を fan-out する版）を並べる想定。

## ライセンス

MIT — [LICENSE](./LICENSE) 参照
