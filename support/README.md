# claude-runner — support variant

claude を `plan` でだけ自動起動し、実装・レビューは **別窓で claude を立ち上げて貼り付ける** 軽量版。`process/` 版のように並列プロセスを管理しないため、シェルスクリプトとしては最小機能。

## 設計の前提

- 重い fan-out（並列・多観点レビュー）は claude 側に任せる（Workflow / sub-agent 等）
- スクリプトは workdir のセットアップと貼り付けメッセージ生成だけ担当
- 1 タスク = 1 work.md + 1 review.md。実装結果は work.md 末尾、レビュー結果は review-result.md

## 前提

- bash 3.2 以上（macOS 標準でも動く）
- [`claude`](https://docs.anthropic.com/claude/docs/claude-code) CLI が PATH にある

## インストール

```bash
install -m 0755 claude-runner-support.sh ~/.local/bin/
# または
cp claude-runner-support.sh ~/src/scripts/ && chmod +x ~/src/scripts/claude-runner-support.sh
```

## クイックスタート

```bash
cd ~/myproject

# 対話 claude を起動して壁打ち。終わると work.md + review.md が出力される。
# 終了後、貼り付け用メッセージが 2 つ stdout に表示される。
claude-runner-support.sh plan myfeature

# 別窓で claude を起動して「Work」メッセージを貼って実装
# 別窓で claude を起動して「Review」メッセージを貼ってレビュー

# 状況確認 + 貼り付けメッセージ再表示
claude-runner-support.sh show

# やり直し（review-result.md / logs / work.md の Result 削除）
claude-runner-support.sh reset
```

## サブコマンド

| コマンド | 動作 |
|---|---|
| `plan [name]` | 対話 claude を起動して壁打ち。`work.md` と `review.md` を workdir に保存。終了時に貼り付け用メッセージを 2 つ stdout に出す。`name` は workdir 識別子（任意） |
| `show` | workdir の状態（ファイル有無・行数・Result 有無）と貼り付け用メッセージを再表示 |
| `reset` | `review-result.md` / `logs/` / `work.md` の `## Result` 以降を削除。`work.md` / `review.md` は plan の成果物なので維持 |

## 環境変数

| 変数 | 用途 |
|---|---|
| `MODEL` | claude モデル上書き（例: `sonnet`, `haiku`） |
| `EFFORT` | effort 上書き（`low`/`medium`/`high`/`xhigh`/`max`） |
| `WORKDIR` | workdir 直接指定（symlink バイパス） |
| `LINK_DIR` | symlink 配置先（既定 `~/src/scripts/link`） |
| `CLAUDE_BIN` | claude バイナリパス（既定 `claude`） |
| `REVIEW_SPEC` | plan の壁打ちで参照するレビュー観点テンプレ（既定: スクリプトと同じディレクトリの `claude-runner-support-review.md`） |

未指定なら claude が `~/.claude/settings.json` の既定値を使う。

## レビュー観点テンプレ

`claude-runner-support-review.md` は plan の壁打ちで claude が参照する観点テンプレ。process 版と違って **1 セッションで全観点を見る** 前提なので、観点を H3 で並べる構造にしている。plan で claude がここから対象差分に合うものを選んで `review.md` に転記する。

## ファイル配置

実行時に生成されるもの:

```
/tmp/runner-<ts>[-<slug>]/   # workdir（プロジェクト外に隔離）
├── work.md                  # plan 出力。実装内容 + 末尾に ## Result（Work 担当 claude が追記）
├── review.md                # plan 出力。レビュー観点・出力先指示
├── review-result.md         # Review 担当 claude の出力
├── logs/                    # 将来用（現状未使用）
└── .project                 # プロジェクトの絶対パス

~/src/scripts/link/<sanitized-cwd> → workdir   # cwd ベース symlink
```

`<sanitized-cwd>` は cwd の `/` を `_` に置換したもの。cwd ごとに異なるので複数プロジェクト併用で衝突しない。

## process 版との違い

| | process 版 | support 版 |
|---|---|---|
| plan 出力 | DESIGN.md + tasks/todo/NNN-*.md (N 個) | work.md + review.md (2 個) |
| 実装実行 | `run-all` がタスク数ぶん `claude -p` 並列起動 | 別窓 claude にメッセージを貼り付け |
| レビュー実行 | 観点数ぶん `claude -p` 並列起動、各観点 1 ファイル出力 | 別窓 claude にメッセージを貼り付け、`review-result.md` 1 本に集約 |
| シェルの責務 | プロセス管理 + 進捗追跡 + ログ収集 | workdir セットアップ + 貼り付けメッセージ生成のみ |
| 並列度 | スクリプト側で制御 | claude 側で制御（Workflow / sub-agent） |
| cold start | 観点数ぶん発生 | plan の 1 回のみ（Work/Review は user の claude セッションで共有） |
